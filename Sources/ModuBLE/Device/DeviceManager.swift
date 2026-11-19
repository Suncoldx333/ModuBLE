import Foundation

/// Where the manager is in the connection lifecycle.
///
/// `connecting` covers the whole transport handshake, including the window
/// where the actor is suspended and a second `connect()` could otherwise slip
/// in. `disconnecting` covers teardown, during which new attempts are refused
/// so a cancellation cannot land on a fresh attempt.
public enum ConnectionPhase: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case disconnecting
}

/// SDK entry point: picks a transport, scans, connects, and owns at most one
/// `DeviceSession`.
///
/// An actor because transport selection, scan lifetime and the current session
/// are shared mutable state. The reconnect policy deliberately stays out: that is
/// an app decision, and the demo implements it in `ConnectionCoordinator`.
public actor DeviceManager {
    /// One in-flight `connect()`. The id is monotonic and never reused, so a
    /// late link can never be mistaken for the current attempt.
    private struct Attempt {
        let id: UInt64
        let transport: any DeviceTransport
    }

    private var transport: any DeviceTransport
    private let profile: GATTProfile
    private let timeout: Duration
    private let logStore: CommunicationLogStore?
    private let makeCrypto: @Sendable () throws -> any CryptoProvider

    private var session: DeviceSession?
    private var sessionWatcher: Task<Void, Never>?

    private var attempt: Attempt?
    private var nextAttemptID: UInt64 = 0
    /// Non-zero while disconnect/switch teardown is suspended. New connects are
    /// rejected so a transport-level cancellation cannot hit a fresh attempt.
    private var cleanupDepth = 0

    public init(
        transport: any DeviceTransport,
        profile: GATTProfile = .referencePeripheral,
        timeout: Duration = .seconds(5),
        logStore: CommunicationLogStore? = nil,
        crypto: @escaping @Sendable () throws -> any CryptoProvider
    ) {
        self.transport = transport
        self.profile = profile
        self.timeout = timeout
        self.logStore = logStore
        self.makeCrypto = crypto
    }

    // MARK: - Introspection

    public var transportKind: TransportKind { transport.kind }
    public var currentSession: DeviceSession? { session }

    /// The lifecycle phase, including the `connecting` window that
    /// `currentSession == nil` alone cannot express.
    public var phase: ConnectionPhase {
        if session != nil { return .connected }
        if attempt != nil { return .connecting }
        if cleanupDepth > 0 { return .disconnecting }
        return .idle
    }

    public var isConnecting: Bool { attempt != nil }

    // MARK: - Scanning

    public func observeBluetoothState() -> AsyncStream<BluetoothState> {
        transport.observeBluetoothState()
    }

    public func scan() async throws -> AsyncThrowingStream<[DiscoveredDevice], Error> {
        try await transport.scan(profile: profile)
    }

    public func stopScan() async {
        await transport.stopScan()
    }

    /// Abandons an in-flight connection attempt.
    ///
    /// Invalidates the attempt before asking the transport to cancel, so a link
    /// that still arrives afterwards is closed instead of being mounted as the
    /// current session. Safe when nothing is in flight.
    public func cancelPendingConnection() async {
        guard let inflight = attempt else { return }
        attempt = nil
        cleanupDepth += 1
        await inflight.transport.cancelPendingConnection()
        cleanupDepth -= 1
        logStore?.log(.info, .ble, "Pending connection cancelled")
    }

    // MARK: - Connection

    /// Connects and returns a ready session.
    ///
    /// Only one session and one attempt are allowed at a time. The actor is
    /// reentrant across `transport.connect`, so the attempt id is re-validated
    /// after every suspension: a `disconnect()`, `switchTransport()` or
    /// `cancelPendingConnection()` that ran meanwhile wins, and the late link is
    /// closed instead of being attached. If the crypto factory fails, the link
    /// is closed before the error is rethrown, so a half-open connection is
    /// never left behind.
    public func connect(_ device: DiscoveredDevice) async throws -> DeviceSession {
        guard session == nil else {
            throw BLEError.connectionFailed("Another connection is already active")
        }
        guard attempt == nil, cleanupDepth == 0 else {
            throw BLEError.connectionFailed("A connection attempt is already in progress")
        }

        nextAttemptID &+= 1
        let current = Attempt(id: nextAttemptID, transport: transport)
        attempt = current

        let link: any DeviceLink
        do {
            link = try await current.transport.connect(device, profile: profile)
        } catch {
            let wasCurrent = attempt?.id == current.id
            if wasCurrent {
                attempt = nil
            }
            // Superseded by disconnect/switch/cancel, or cancelled by the caller.
            if !wasCurrent || Task.isCancelled {
                throw BLEError.cancelled
            }
            throw error
        }

        // Re-validate after the actor hop. A mismatching or missing attempt, a
        // closed session or a cancelled task all make this link orphaned.
        guard attempt?.id == current.id, !Task.isCancelled, session == nil else {
            if attempt?.id == current.id {
                attempt = nil
            }
            await link.close()
            throw BLEError.cancelled
        }
        attempt = nil

        do {
            let crypto = try makeCrypto()
            let newSession = DeviceSession(
                link: link,
                crypto: crypto,
                timeout: timeout,
                logStore: logStore
            )
            session = newSession
            watch(newSession)
            logStore?.log(.info, .session, "Session ready · \(device.displayName)")
            return newSession
        } catch {
            await link.close()
            throw error
        }
    }

    /// Closes the current session and cancels any in-flight attempt.
    /// Safe to call repeatedly.
    public func disconnect() async {
        let current = session
        let inflight = attempt
        attempt = nil
        session = nil
        sessionWatcher?.cancel()
        sessionWatcher = nil

        guard current != nil || inflight != nil else { return }

        cleanupDepth += 1
        await current?.close()
        if let inflight {
            await inflight.transport.cancelPendingConnection()
        }
        cleanupDepth -= 1
    }

    /// Swaps transports, closing the current session and invalidating any
    /// in-flight attempt on the old transport first.
    public func switchTransport(_ newTransport: any DeviceTransport) async {
        let current = session
        let inflight = attempt
        attempt = nil
        session = nil
        sessionWatcher?.cancel()
        sessionWatcher = nil

        cleanupDepth += 1
        await current?.close()
        if let inflight {
            await inflight.transport.cancelPendingConnection()
        }
        transport = newTransport
        cleanupDepth -= 1
        logStore?.log(.info, .ble, "Transport switched to \(newTransport.kind.label)")
    }

    // MARK: - Private

    /// Clears `session` when the link dies, so a later `connect` is not
    /// permanently rejected after an unexpected disconnect.
    private func watch(_ session: DeviceSession) {
        sessionWatcher?.cancel()
        sessionWatcher = Task { [weak self] in
            for await state in session.observeState() {
                guard case .closed = state else { continue }
                await self?.clearIfCurrent(session)
                return
            }
        }
    }

    private func clearIfCurrent(_ candidate: DeviceSession) {
        guard session === candidate else { return }
        session = nil
        sessionWatcher = nil
        logStore?.log(.info, .session, "Session released after close")
    }
}
