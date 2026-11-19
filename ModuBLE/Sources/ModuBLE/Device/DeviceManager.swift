import Foundation

/// SDK entry point: picks a transport, scans, connects, and owns at most one
/// `DeviceSession`.
///
/// An actor because transport selection, scan lifetime and the current session
/// are shared mutable state. The reconnect policy deliberately stays out: that is
/// an app decision, and the demo implements it in `ConnectionCoordinator`.
public actor DeviceManager {
    private var transport: any DeviceTransport
    private let profile: GATTProfile
    private let timeout: Duration
    private let logStore: CommunicationLogStore?
    private let makeCrypto: @Sendable () throws -> any CryptoProvider

    private var session: DeviceSession?
    private var sessionWatcher: Task<Void, Never>?

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

    // MARK: - Connection

    /// Connects and returns a ready session.
    ///
    /// Only one session is allowed at a time. If the crypto factory fails, the
    /// link is closed before the error is rethrown, so a half-open connection is
    /// never left behind.
    public func connect(_ device: DiscoveredDevice) async throws -> DeviceSession {
        guard session == nil else {
            throw BLEError.connectionFailed("Another connection is already active")
        }

        let link = try await transport.connect(device, profile: profile)

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

    /// Closes the current session, if any. Safe to call repeatedly.
    public func disconnect() async {
        let current = session
        session = nil
        sessionWatcher?.cancel()
        sessionWatcher = nil
        await current?.close()
    }

    /// Swaps transports, closing the current session first.
    public func switchTransport(_ newTransport: any DeviceTransport) async {
        await disconnect()
        transport = newTransport
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
