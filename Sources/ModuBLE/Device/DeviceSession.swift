import Foundation

/// One decoded notification from the device.
///
/// The raw payload is always kept: when `telemetry` is `nil` the event is not a
/// telemetry sample, and the app may still want to log or display it. Decoding
/// failures never close the session.
public struct DeviceEvent: Equatable, Sendable {
    public let sequence: UInt32
    public let receivedAt: Date
    public let payload: Data
    public let telemetry: Telemetry?

    public init(sequence: UInt32, receivedAt: Date, payload: Data, telemetry: Telemetry?) {
        self.sequence = sequence
        self.receivedAt = receivedAt
        self.payload = payload
        self.telemetry = telemetry
    }
}

/// Lifecycle of one device conversation.
public enum DeviceSessionState: Equatable, Sendable {
    case ready
    case closed(reason: String?)

    public var isReady: Bool { self == .ready }

    public var label: String {
        switch self {
        case .ready: return "Ready"
        case .closed(let reason): return reason.map { "Closed: \($0)" } ?? "Closed"
        }
    }
}

/// A connected device, with encryption, request/response and a semantic event
/// stream layered on top of a `DeviceLink`.
///
/// Ownership:
/// - the session starts the receive loop immediately, so events arrive even when
///   no request is in flight;
/// - it parses telemetry for the caller but keeps the raw payload;
/// - it observes the link and closes itself when the link dies;
/// - `close()` is idempotent. Callers should still call it explicitly, because
///   a class cannot perform async teardown in `deinit`.
public final class DeviceSession: @unchecked Sendable {
    public let device: DiscoveredDevice

    /// Decoded events, in arrival order. **Single consumer.**
    public let events: AsyncStream<DeviceEvent>

    private let link: any DeviceLink
    private let encrypted: EncryptedSession
    private let logStore: CommunicationLogStore?
    private let eventContinuation: AsyncStream<DeviceEvent>.Continuation

    private let lock = NSLock()
    private var currentState: DeviceSessionState = .ready
    private var stateObservers: [UUID: AsyncStream<DeviceSessionState>.Continuation] = [:]
    private var closed = false
    private var tasks: [Task<Void, Never>] = []

    public init(
        link: any DeviceLink,
        crypto: any CryptoProvider,
        timeout: Duration = .seconds(5),
        logStore: CommunicationLogStore? = nil
    ) {
        self.device = link.device
        self.link = link
        self.logStore = logStore
        self.encrypted = EncryptedSession(
            link: link,
            crypto: crypto,
            timeout: timeout,
            logStore: logStore
        )

        let (stream, continuation) = AsyncStream<DeviceEvent>.makeStream()
        self.events = stream
        self.eventContinuation = continuation

        encrypted.start()
        startObservers()
    }

    // MARK: - State

    public var state: DeviceSessionState { lock.withLock { currentState } }
    public var isClosed: Bool { lock.withLock { closed } }

    public func observeState() -> AsyncStream<DeviceSessionState> {
        AsyncStream { continuation in
            let id = UUID()
            let initial = lock.withLock { () -> DeviceSessionState in
                if !closed { stateObservers[id] = continuation }
                return currentState
            }
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.stateObservers[id] = nil }
            }
        }
    }

    // MARK: - Communication

    public func request(_ payload: Data) async throws -> Data {
        guard !isClosed else { throw SessionError.closed }
        do {
            return try await encrypted.request(payload)
        } catch let error as SessionError {
            if case .closed = error {
                await close(reason: "Connection closed")
            }
            throw error
        }
    }

    /// Raw write, used by the diagnostics screen. Never mixes with `request`:
    /// the caller chooses one mode at a time.
    public func write(_ data: Data, mode: GATTProfile.WriteMode? = nil) async throws {
        guard !isClosed else { throw BLEError.notReady }
        try await link.write(data, mode: mode)
    }

    public func updateCrypto(_ provider: any CryptoProvider) {
        encrypted.updateCrypto(provider)
    }

    public var algorithm: CryptoAlgorithm { encrypted.algorithm }
    public var maxPlaintextLength: Int { encrypted.maxPlaintextLength }

    public var maximumWritePayloadLength: Int { link.maximumWritePayloadLength }
    public var maximumWritePayloadLengthWithoutResponse: Int {
        link.maximumWritePayloadLengthWithoutResponse
    }

    /// Real ATT MTU, derived from the write-command payload limit.
    public var attMTU: Int { maximumWritePayloadLengthWithoutResponse + 3 }

    // MARK: - Lifecycle

    public func close() async {
        await close(reason: nil)
    }

    private func close(reason: String?) async {
        let observers: [AsyncStream<DeviceSessionState>.Continuation]? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            currentState = .closed(reason: reason)
            return Array(stateObservers.values)
        }
        guard let observers else { return }

        eventContinuation.finish()
        for observer in observers {
            observer.yield(.closed(reason: reason))
        }

        // Closing the link wakes the state observer, so cancel tasks afterwards.
        await encrypted.close()
        tasks.forEach { $0.cancel() }
        logStore?.log(
            .info,
            .session,
            reason.map { "Device session closed · \($0)" } ?? "Device session closed"
        )
    }

    private func startObservers() {
        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await event in self.encrypted.events {
                let telemetry: Telemetry?
                do {
                    telemetry = try TelemetryCodec.decode(event.payload)
                } catch {
                    telemetry = nil
                    self.logStore?.log(
                        .debug,
                        .session,
                        "Event #\(event.sequence) is not telemetry: \(error)"
                    )
                }
                self.eventContinuation.yield(
                    DeviceEvent(
                        sequence: event.sequence,
                        receivedAt: event.receivedAt,
                        payload: event.payload,
                        telemetry: telemetry
                    )
                )
            }
        })

        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await state in self.link.observeState() {
                switch state {
                case .failed(let reason):
                    await self.close(reason: reason)
                    return
                case .disconnected:
                    await self.close(reason: nil)
                    return
                case .connecting, .discovering, .ready:
                    continue
                }
            }
        })
    }

    deinit {
        tasks.forEach { $0.cancel() }
        eventContinuation.finish()
    }
}
