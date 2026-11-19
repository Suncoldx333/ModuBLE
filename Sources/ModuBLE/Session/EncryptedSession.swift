import Foundation

/// Request/response session over a `BLELink`, with every payload sealed by a
/// `CryptoProvider`.
///
/// Responsibilities:
/// - encrypt the request, wrap it in a `Packet`, and write it through the link;
/// - reassemble inbound bytes into packets, match the response by sequence,
///   verify and decrypt it; a late or duplicate response is logged and dropped
///   instead of resolving the request that is currently in flight. The pending
///   slot is committed only after decryption, so timeout and close stay
///   effective while a response is being verified;
/// - decrypt unsolicited `event` frames and publish them on `events`;
/// - bound every request with a timeout so a silent peripheral cannot hang a
///   caller.
///
/// One request is in flight at a time. That is deliberate: BLE writes are
/// serialized anyway, and a single pending continuation keeps the matching
/// logic impossible to get wrong. Concurrent callers get `SessionError.busy`.
public final class EncryptedSession: @unchecked Sendable {
    private struct Pending {
        /// Monotonic identity, allocated with the sequence reservation. It
        /// survives sequence wrap-around, so a response can only ever resolve
        /// the request it belongs to.
        let id: UInt64
        let sequence: UInt32
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let link: any BLELink
    private let cryptoLock = NSLock()
    private var crypto: any CryptoProvider
    private let timeout: Duration
    private let logStore: CommunicationLogStore?
    private let codec = PacketCodec()
    private let inbound: AsyncStream<Data>

    /// Decrypted unsolicited events, in arrival order.
    ///
    /// **Single consumer**, same rule as `BLELink.inbound`: `AsyncStream` shares
    /// one buffer between iterators. `DeviceSession` is the intended reader.
    ///
    /// The stream finishes when the session closes or the link ends. Events that
    /// fail authentication never reach it; they are logged and dropped so one
    /// corrupt frame cannot tear down the session.
    public let events: AsyncStream<SessionEvent>
    private let eventContinuation: AsyncStream<SessionEvent>.Continuation

    private let lock = NSLock()
    private var pending: Pending?
    /// Sequence taken by a caller that has not installed its continuation yet.
    /// Visible to other callers under the same lock, which closes the window
    /// where two concurrent `request()` calls both observe `pending == nil`.
    private var reservedSequence: UInt32?
    private var reservedRequestID: UInt64?
    private var nextRequestID: UInt64 = 0
    private var nextSequence: UInt32 = 1
    private var started = false
    private var closed = false
    private var receiveTask: Task<Void, Never>?

    public init(
        link: any BLELink,
        crypto: any CryptoProvider,
        timeout: Duration = .seconds(5),
        logStore: CommunicationLogStore? = nil
    ) {
        self.link = link
        self.crypto = crypto
        self.timeout = timeout
        self.logStore = logStore
        self.inbound = link.inbound

        let (events, continuation) = AsyncStream<SessionEvent>.makeStream()
        self.events = events
        self.eventContinuation = continuation

        precondition(timeout > .zero, "A session needs a positive timeout")
    }

    public var algorithm: CryptoAlgorithm {
        cryptoLock.withLock { crypto.algorithm }
    }

    /// Largest plaintext accepted by `request(_:)` with the current provider.
    public var maxPlaintextLength: Int {
        cryptoLock.withLock { crypto.maxPlaintextLength }
    }

    /// Starts the receive loop without sending a request.
    ///
    /// `request(_:)` starts it implicitly. Call this when the peripheral may
    /// push events before the first request (telemetry, status), otherwise those
    /// frames would sit unread in `inbound`.
    public func start() {
        startIfNeeded()
    }

    /// Swaps the provider without restarting the receive loop.
    ///
    /// The sealed envelope identifies its own format (GCM `0x01`, CBC `0x02`), so
    /// the peer can follow the switch. Switching while a request is still in
    /// flight makes that response fail authentication — let it finish first.
    public func updateCrypto(_ provider: any CryptoProvider) {
        cryptoLock.withLock { crypto = provider }
        logStore?.log(.info, .crypto, "Crypto switched to \(provider.algorithm.displayName)")
    }

    // MARK: - Public API

    /// Sends `payload` sealed, and returns the decrypted response payload.
    public func request(_ payload: Data) async throws -> Data {
        startIfNeeded()

        let provider = cryptoLock.withLock { crypto }
        guard payload.count <= provider.maxPlaintextLength else {
            throw SessionError.payloadTooLarge(max: provider.maxPlaintextLength)
        }

        let sealed: Data
        do {
            sealed = try provider.encrypt(payload)
        } catch let error as CryptoError {
            throw SessionError.crypto(error)
        }

        let (requestID, sequence) = try reserveSequence()
        let frame: Data
        do {
            frame = try codec.encode(Packet(kind: .request, sequence: sequence, payload: sealed))
        } catch let error as PacketError {
            releaseReservation(requestID)
            throw SessionError.framing(error)
        }

        logStore?.log(
            .debug,
            .session,
            "Request #\(sequence) sealed · \(payload.count) → \(sealed.count) B"
        )

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.timeout)
                guard !Task.isCancelled else { return }
                self.logStore?.log(.warning, .session, "Request #\(sequence) timed out")
                self.finish(.failure(SessionError.timedOut), onlyIf: requestID)
            }

            // Promote the reservation to a real pending slot atomically. Two
            // callers can no longer overwrite each other, and if the session
            // closed in between the caller is resumed instead of leaking.
            let admitted = lock.withLock { () -> Bool in
                guard !closed,
                      reservedSequence == sequence,
                      reservedRequestID == requestID else { return false }
                reservedSequence = nil
                reservedRequestID = nil
                pending = Pending(
                    id: requestID,
                    sequence: sequence,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                return true
            }
            guard admitted else {
                timeoutTask.cancel()
                continuation.resume(throwing: SessionError.closed)
                return
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.link.write(frame)
                } catch let error as BLEError {
                    self.finish(.failure(SessionError.transport(error)), onlyIf: requestID)
                } catch {
                    self.finish(.failure(SessionError.closed), onlyIf: requestID)
                }
            }
        }
    }

    /// Stops the receive loop and releases any waiting caller.
    public func close() async {
        let alreadyClosed = lock.withLock { () -> Bool in
            let wasClosed = closed
            closed = true
            reservedSequence = nil
            reservedRequestID = nil
            return wasClosed
        }
        guard !alreadyClosed else { return }

        finish(.failure(SessionError.closed))
        eventContinuation.finish()
        let task = lock.withLock { () -> Task<Void, Never>? in
            let task = receiveTask
            receiveTask = nil
            return task
        }
        task?.cancel()
        await link.close()
        logStore?.log(.info, .session, "Session closed")
    }

    // MARK: - Receive loop

    private func startIfNeeded() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !started, !closed else { return false }
            started = true
            return true
        }
        guard shouldStart else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
        lock.withLock { receiveTask = task }
    }

    private func receiveLoop() async {
        var decoder = PacketDecoder()

        for await chunk in inbound {
            let packets: [Packet]
            do {
                packets = try decoder.append(chunk)
            } catch let error as PacketError {
                logStore?.log(.error, .session, "Framing error: \(error)")
                decoder.reset()
                continue
            } catch {
                decoder.reset()
                continue
            }

            for packet in packets {
                handle(packet)
            }
        }

        // The link ended: nothing else can arrive.
        lock.withLock {
            closed = true
            reservedSequence = nil
            reservedRequestID = nil
        }
        finish(.failure(SessionError.closed))
        eventContinuation.finish()
        logStore?.log(.info, .session, "Inbound stream finished")
    }

    private func handle(_ packet: Packet) {
        switch packet.kind {
        case .response:
            guard let snapshot = lock.withLock({ pending }) else {
                logStore?.log(.warning, .session, "Response #\(packet.sequence) with no pending request")
                return
            }
            guard snapshot.sequence == packet.sequence else {
                // Late or duplicate response, e.g. for a request that already
                // timed out. It must never resolve or fail the request that is
                // currently in flight: that caller is still waiting for its own
                // answer, and the peer may deliver it in time.
                logStore?.log(
                    .warning,
                    .session,
                    "Dropped stale response #\(packet.sequence) while #\(snapshot.sequence) is pending"
                )
                return
            }

            // Keep the request pending while the payload is decrypted: timeout
            // and close stay authoritative until the result is committed. The
            // commit below is the single atomic point that decides whether this
            // response still belongs to a waiting caller.
            let provider = cryptoLock.withLock { crypto }
            let result: Result<Data, Error>
            do {
                let plaintext = try provider.decrypt(packet.payload)
                logStore?.log(
                    .debug,
                    .receive,
                    "Decrypted response #\(packet.sequence) · \(plaintext.count) B",
                    payload: plaintext
                )
                result = .success(plaintext)
            } catch let error as CryptoError {
                result = .failure(SessionError.crypto(error))
            } catch {
                result = .failure(SessionError.crypto(.malformedEnvelope))
            }

            finish(result, onlyIf: snapshot.id)

        case .event:
            let provider = cryptoLock.withLock { crypto }
            do {
                let plaintext = try provider.decrypt(packet.payload)
                logStore?.log(
                    .debug,
                    .receive,
                    "Decrypted event #\(packet.sequence) · \(plaintext.count) B",
                    payload: plaintext
                )
                eventContinuation.yield(
                    SessionEvent(sequence: packet.sequence, payload: plaintext)
                )
            } catch let error as CryptoError {
                // A bad event is a bad event, not a reason to close the session.
                logStore?.log(
                    .error,
                    .session,
                    "Event #\(packet.sequence) rejected: \(error)"
                )
            } catch {
                logStore?.log(
                    .error,
                    .session,
                    "Event #\(packet.sequence) rejected: malformed envelope"
                )
            }

        case .request, .raw:
            logStore?.log(
                .warning,
                .session,
                "Unexpected \(packet.kind) frame from peripheral"
            )
        }
    }

    // MARK: - Pending request bookkeeping

    private enum Reservation {
        case reserved(id: UInt64, sequence: UInt32)
        case busy
        case closed
    }

    private func reserveSequence() throws -> (id: UInt64, sequence: UInt32) {
        let reservation = lock.withLock { () -> Reservation in
            if closed { return .closed }
            guard pending == nil, reservedSequence == nil else { return .busy }
            let sequence = nextSequence
            nextSequence = sequence == .max ? 1 : sequence + 1
            nextRequestID &+= 1
            let id = nextRequestID
            reservedSequence = sequence
            reservedRequestID = id
            return .reserved(id: id, sequence: sequence)
        }

        switch reservation {
        case .reserved(let id, let sequence):
            return (id, sequence)
        case .busy:
            throw SessionError.busy
        case .closed:
            throw SessionError.closed
        }
    }

    /// Gives a reserved sequence back after a local failure (framing), so the
    /// session does not stay permanently `busy`.
    private func releaseReservation(_ requestID: UInt64) {
        lock.withLock {
            if reservedRequestID == requestID {
                reservedSequence = nil
                reservedRequestID = nil
            }
        }
    }

    /// Removes `pending` only if it still belongs to `id`, then resumes it.
    ///
    /// This is the single atomic commit point: the response path, timeout,
    /// close and write-failure all race through it, and whichever acquires the
    /// lock first wins. A response that finishes decrypting after its request
    /// already timed out or closed simply finds no matching slot and is dropped.
    private func finish(_ result: Result<Data, Error>, onlyIf requestID: UInt64? = nil) {
        let resolved: Pending? = lock.withLock {
            guard let current = pending else { return nil }
            if let requestID, current.id != requestID {
                return nil
            }
            pending = nil
            return current
        }

        guard let resolved else { return }
        resolved.timeoutTask.cancel()
        resolved.continuation.resume(with: result)
    }

    deinit {
        let resolved: Pending? = lock.withLock {
            let current = pending
            pending = nil
            return current
        }
        resolved?.timeoutTask.cancel()
        resolved?.continuation.resume(throwing: SessionError.closed)
        eventContinuation.finish()
    }
}
