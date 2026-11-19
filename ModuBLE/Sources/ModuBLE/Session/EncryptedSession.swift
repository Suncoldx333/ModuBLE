import Foundation

/// Request/response session over a `BLELink`, with every payload sealed by a
/// `CryptoProvider`.
///
/// Responsibilities:
/// - encrypt the request, wrap it in a `Packet`, and write it through the link;
/// - reassemble inbound bytes into packets, match the response by sequence,
///   verify and decrypt it;
/// - bound every request with a timeout so a silent peripheral cannot hang a
///   caller.
///
/// One request is in flight at a time. That is deliberate: BLE writes are
/// serialized anyway, and a single pending continuation keeps the matching
/// logic impossible to get wrong. Concurrent callers get `SessionError.busy`.
public final class EncryptedSession: @unchecked Sendable {
    private struct Pending {
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

    private let lock = NSLock()
    private var pending: Pending?
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
        precondition(timeout > .zero, "A session needs a positive timeout")
    }

    public var algorithm: CryptoAlgorithm {
        cryptoLock.withLock { crypto.algorithm }
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

        let sealed: Data
        do {
            sealed = try provider.encrypt(payload)
        } catch let error as CryptoError {
            throw SessionError.crypto(error)
        }

        let sequence = try reserveSequence()
        let frame: Data
        do {
            frame = try codec.encode(Packet(kind: .request, sequence: sequence, payload: sealed))
        } catch let error as PacketError {
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
                self.finish(.failure(SessionError.timedOut), onlyIfSequence: sequence)
            }

            lock.withLock {
                pending = Pending(
                    sequence: sequence,
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.link.write(frame)
                } catch let error as BLEError {
                    self.finish(.failure(SessionError.transport(error)), onlyIfSequence: sequence)
                } catch {
                    self.finish(.failure(SessionError.closed), onlyIfSequence: sequence)
                }
            }
        }
    }

    /// Stops the receive loop and releases any waiting caller.
    public func close() async {
        let alreadyClosed = lock.withLock { () -> Bool in
            let wasClosed = closed
            closed = true
            return wasClosed
        }
        guard !alreadyClosed else { return }

        finish(.failure(SessionError.closed))
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
        lock.withLock { closed = true }
        finish(.failure(SessionError.closed))
        logStore?.log(.info, .session, "Inbound stream finished")
    }

    private func handle(_ packet: Packet) {
        switch packet.kind {
        case .response:
            let current = lock.withLock { pending }
            guard let current else {
                logStore?.log(.warning, .session, "Response #\(packet.sequence) with no pending request")
                return
            }
            guard current.sequence == packet.sequence else {
                finish(
                    .failure(
                        SessionError.unexpectedResponse(
                            expected: current.sequence,
                            received: packet.sequence
                        )
                    )
                )
                return
            }

            let provider = cryptoLock.withLock { crypto }
            do {
                let plaintext = try provider.decrypt(packet.payload)
                logStore?.log(
                    .debug,
                    .receive,
                    "Decrypted response #\(packet.sequence) · \(plaintext.count) B",
                    payload: plaintext
                )
                finish(.success(plaintext))
            } catch let error as CryptoError {
                finish(.failure(SessionError.crypto(error)))
            } catch {
                finish(.failure(SessionError.crypto(.malformedEnvelope)))
            }

        case .event:
            logStore?.log(.debug, .session, "Event #\(packet.sequence) ignored")

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
        case reserved(UInt32)
        case busy
        case closed
    }

    private func reserveSequence() throws -> UInt32 {
        let reservation = lock.withLock { () -> Reservation in
            if closed { return .closed }
            guard pending == nil else { return .busy }
            let sequence = nextSequence
            nextSequence = sequence == .max ? 1 : sequence + 1
            return .reserved(sequence)
        }

        switch reservation {
        case .reserved(let sequence):
            return sequence
        case .busy:
            throw SessionError.busy
        case .closed:
            throw SessionError.closed
        }
    }

    private func finish(_ result: Result<Data, Error>, onlyIfSequence: UInt32? = nil) {
        let resolved: Pending? = lock.withLock {
            guard let current = pending else { return nil }
            if let sequence = onlyIfSequence, current.sequence != sequence {
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
        pending?.timeoutTask.cancel()
        pending?.continuation.resume(throwing: SessionError.closed)
    }
}
