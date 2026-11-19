import Foundation
import Combine
import ModuBLE

/// Holds the crypto choice for the next connection.
///
/// `DeviceManager` asks for a provider from a `@Sendable` closure, which cannot
/// read `@MainActor` view state. A tiny locked box bridges the two.
final class CryptoSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: CryptoAlgorithm = .aes128GCM

    var current: CryptoAlgorithm {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    func makeProvider() throws -> any CryptoProvider {
        switch current {
        case .aes128GCM:
            return try AESGCMProvider(key: DemoTestKey.aes128GCM)
        case .aes128CBCHMAC:
            return try AESCBCProvider(key: DemoTestKey.aes128CBCHMAC)
        }
    }
}

/// App-level owner of transport choice, scanning, connection lifecycle and the
/// reconnect policy.
///
/// Everything here is a *policy* decision. The SDK deliberately stops at
/// `DeviceManager`: backoff, "pause while Bluetooth is off" and the UI state
/// machine belong to the app.
@MainActor
final class DeviceCoordinator: ObservableObject {
    // MARK: - Published state

    @Published private(set) var transportKind: TransportKind = .mock
    @Published private(set) var isBluetoothReady = false
    @Published private(set) var bluetoothProblem: String?

    @Published private(set) var isScanning = false
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var connectedDevice: DiscoveredDevice?
    @Published var lastError: String?

    @Published private(set) var telemetry: Telemetry?
    @Published private(set) var lastTelemetryAt: Date?
    @Published private(set) var eventCount = 0

    @Published var algorithm: CryptoAlgorithm = .aes128GCM
    @Published private(set) var telemetryRate: Double = 1
    @Published private(set) var isTelemetryRequested = false

    @Published private(set) var isReconnecting = false
    @Published private(set) var reconnectAttempt = 0
    @Published private(set) var reconnectNextAttemptAt: Date?
    @Published private(set) var reconnectExhausted = false

    @Published var faultConfiguration = FaultConfiguration()

    /// Diagnostics: raw send, chunk test, paced transfer and the log mirror.
    let diagnostics: DemoModel
    let logStore: CommunicationLogStore

    // MARK: - SDK

    let reconnectDelays: [TimeInterval] = [1, 2, 4, 8, 16, 32]

    private let mockTransport: MockDeviceTransport
    private let bluetoothTransport: CoreBluetoothTransport
    private let cryptoSelection = CryptoSelection()
    private let manager: DeviceManager

    private var session: DeviceSession?
    private var scanTask: Task<Void, Never>?
    private var bluetoothStateTask: Task<Void, Never>?
    private var sessionStateTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    /// Tracks the manual connect task so cancel/disconnect can invalidate a
    /// result that arrives after the user changed their mind.
    private var connectTask: Task<Void, Never>?
    private var connectGeneration = 0

    private var userInitiatedDisconnect = false
    private var hadSuccessfulConnection = false
    private var reconnectTarget: DiscoveredDevice?

    // MARK: - Init

    init() {
        let store = CommunicationLogStore(capacity: 300)
        self.logStore = store
        self.mockTransport = MockDeviceTransport(logStore: store)
        self.bluetoothTransport = CoreBluetoothTransport(logStore: store)
        self.diagnostics = DemoModel(logStore: store)
        self.manager = DeviceManager(
            transport: mockTransport,
            logStore: store,
            crypto: { [cryptoSelection] in try cryptoSelection.makeProvider() }
        )

        startBluetoothObservation()
    }

    // MARK: - Transport

    func selectTransport(_ kind: TransportKind) {
        guard kind != transportKind else { return }

        stopScan()
        cancelReconnection()
        teardownSession()
        transportKind = kind
        devices = []
        lastError = nil
        connectionState = .disconnected

        Task {
            await manager.switchTransport(kind == .mock ? mockTransport : bluetoothTransport)
            restartBluetoothObservation()
            if kind == .mock {
                mockTransport.applyFaultConfiguration(faultConfiguration)
            }
        }
    }

    // MARK: - Bluetooth state

    private func startBluetoothObservation() {
        bluetoothStateTask = Task { [weak self] in
            guard let self else { return }
            let states = await self.manager.observeBluetoothState()
            for await state in states {
                self.isBluetoothReady = state.isReady
                self.bluetoothProblem = state.problemDescription
                if state.isReady {
                    self.lastError = nil
                }
            }
        }
    }

    private func restartBluetoothObservation() {
        bluetoothStateTask?.cancel()
        bluetoothStateTask = nil
        startBluetoothObservation()
    }

    // MARK: - Scanning

    func startScan() {
        guard isBluetoothReady else { return }

        scanTask?.cancel()
        devices = []
        isScanning = true
        lastError = nil

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.manager.scan()
                for try await snapshot in stream {
                    self.devices = snapshot
                }
            } catch {
                self.lastError = DemoModel.describe(error)
            }
            self.isScanning = false
            self.scanTask = nil
        }
    }

    func stopScan() {
        isScanning = false
        scanTask?.cancel()
        scanTask = nil
        Task { await manager.stopScan() }
    }

    // MARK: - Connecting

    func connect(_ device: DiscoveredDevice) {
        guard session == nil else {
            lastError = "Disconnect from the current peripheral first."
            return
        }
        guard connectionState != .connecting else { return }

        cancelReconnection()
        userInitiatedDisconnect = false
        connectionState = .connecting
        lastError = nil

        connectGeneration += 1
        let generation = connectGeneration
        connectTask = Task { [weak self] in
            guard let self else { return }
            do {
                let newSession = try await self.manager.connect(device)
                // The user may have cancelled while the actor hop was in flight.
                guard generation == self.connectGeneration,
                      !Task.isCancelled else {
                    await newSession.close()
                    return
                }
                self.attach(newSession, device: device)
            } catch {
                guard generation == self.connectGeneration else { return }
                let message = DemoModel.describe(error)
                if let ble = error as? BLEError, ble == .cancelled {
                    self.connectionState = .disconnected
                    return
                }
                self.connectionState = .failed(message)
                self.lastError = message
            }
        }
    }

    func cancelConnect() {
        connectGeneration += 1
        connectTask?.cancel()
        connectTask = nil
        connectionState = .disconnected
        Task { await manager.cancelPendingConnection() }
    }

    func disconnect() {
        cancelReconnection()
        hadSuccessfulConnection = false
        teardownSession()
    }

    private func attach(_ session: DeviceSession, device: DiscoveredDevice) {
        self.session = session
        connectedDevice = device
        connectionState = .ready
        hadSuccessfulConnection = true
        userInitiatedDisconnect = false
        lastError = nil
        telemetry = nil
        lastTelemetryAt = nil
        eventCount = 0
        isTelemetryRequested = false

        diagnostics.bind(session)
        applyAlgorithm()
        observe(session)
        startTelemetry()
    }

    private func observe(_ session: DeviceSession) {
        sessionStateTask?.cancel()
        sessionStateTask = Task { [weak self] in
            guard let self else { return }
            for await state in session.observeState() {
                guard case .closed(let reason) = state else { continue }
                self.handleSessionEnded(session, reason: reason)
                return
            }
        }

        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in session.events {
                guard let telemetry = event.telemetry else { continue }
                self.telemetry = telemetry
                self.lastTelemetryAt = event.receivedAt
                self.eventCount += 1
            }
        }
    }

    private func handleSessionEnded(_ ended: DeviceSession, reason: String?) {
        guard session === ended else { return }

        session = nil
        diagnostics.bind(nil)
        sessionStateTask = nil
        eventTask?.cancel()
        eventTask = nil
        commandTask?.cancel()
        commandTask = nil
        telemetry = nil
        isTelemetryRequested = false

        let wasUserInitiated = userInitiatedDisconnect
        userInitiatedDisconnect = false
        let device = connectedDevice
        connectedDevice = nil

        if wasUserInitiated {
            hadSuccessfulConnection = false
            connectionState = .disconnected
            return
        }

        connectionState = .failed(reason ?? "Connection lost")
        lastError = reason ?? "Connection lost"

        if let device, hadSuccessfulConnection {
            startAutoReconnect(for: device)
        }
    }

    private func teardownSession() {
        userInitiatedDisconnect = true
        connectGeneration += 1
        connectTask?.cancel()
        connectTask = nil
        sessionStateTask?.cancel()
        sessionStateTask = nil
        eventTask?.cancel()
        eventTask = nil
        commandTask?.cancel()
        commandTask = nil

        if let session {
            self.session = nil
            Task { await session.close() }
        }
        Task { await manager.disconnect() }

        diagnostics.bind(nil)
        connectedDevice = nil
        telemetry = nil
        lastTelemetryAt = nil
        isTelemetryRequested = false
        connectionState = .disconnected
    }

    // MARK: - Telemetry commands

    func startTelemetry() {
        guard let session, !session.isClosed else { return }
        isTelemetryRequested = true
        send(command: "START")
        if telemetryRate != 1 {
            send(command: "SET_RATE:\(String(format: "%g", telemetryRate))")
        }
    }

    func stopTelemetry() {
        guard let session, !session.isClosed else { return }
        isTelemetryRequested = false
        send(command: "STOP")
    }

    func setTelemetryRate(_ hz: Double) {
        telemetryRate = min(10, max(0.2, hz))
        guard session != nil, isTelemetryRequested else { return }
        send(command: "SET_RATE:\(String(format: "%g", telemetryRate))")
    }

    /// Commands are chained so a rapid Start → rate change cannot collide with
    /// the single in-flight request slot and produce `SessionError.busy`.
    private func send(command: String) {
        let previous = commandTask
        commandTask = Task { [weak self] in
            _ = await previous?.value
            guard !Task.isCancelled, let self, let session = self.session else { return }
            do {
                _ = try await session.request(Data(command.utf8))
            } catch {
                self.lastError = DemoModel.describe(error)
            }
        }
    }

    // MARK: - Algorithm

    func applyAlgorithm() {
        cryptoSelection.current = algorithm
        guard let session else { return }
        do {
            session.updateCrypto(try cryptoSelection.makeProvider())
        } catch {
            lastError = "Could not create the crypto provider."
            return
        }
        // Re-issue the telemetry command so the peripheral answers — and seals
        // its next events — with the new envelope. Without this, events would
        // fail authentication until the next request.
        if isTelemetryRequested {
            send(command: "START")
        }
    }

    // MARK: - Faults

    func applyFaults() {
        guard transportKind == .mock else { return }
        mockTransport.applyFaultConfiguration(faultConfiguration)
    }

    var faultCounters: FaultInjector.Counters {
        mockTransport.activeLink?.injector.counters ?? FaultInjector.Counters()
    }

    func disconnectNow() {
        Task { await manager.disconnect() }
    }

    // MARK: - Reconnect

    private func startAutoReconnect(for device: DiscoveredDevice) {
        reconnectTask?.cancel()
        reconnectTarget = device
        connectedDevice = device
        isReconnecting = true
        reconnectExhausted = false
        reconnectAttempt = 0
        reconnectNextAttemptAt = nil
        connectionState = .disconnected

        logStore.append(
            CommunicationLog(
                level: .info,
                category: .ble,
                message: "Auto-reconnect started · delays 1, 2, 4, 8, 16, 32 s"
            )
        )

        reconnectTask = Task { [weak self] in
            guard let self else { return }

            for (index, delay) in self.reconnectDelays.enumerated() {
                guard !Task.isCancelled else { return }

                // Bluetooth off is not a failed attempt: wait for it to come
                // back instead of burning the whole budget in six seconds.
                while !self.isBluetoothReady {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                }

                self.reconnectAttempt = index + 1
                self.reconnectNextAttemptAt = Date().addingTimeInterval(delay)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self.reconnectNextAttemptAt = nil

                do {
                    // The manager may not have observed the close yet; a
                    // disconnect here is idempotent and avoids a false "busy".
                    await self.manager.disconnect()
                    guard !Task.isCancelled else { return }
                    let newSession = try await self.manager.connect(device)
                    // Cancelled between the manager returning and this point:
                    // close the orphan instead of attaching it after the user
                    // pressed "Stop Reconnecting".
                    guard !Task.isCancelled else {
                        await self.manager.disconnect()
                        self.connectionState = .disconnected
                        return
                    }
                    self.reconnectTask = nil
                    self.reconnectTarget = nil
                    self.isReconnecting = false
                    self.attach(newSession, device: device)
                    return
                } catch {
                    if Task.isCancelled { return }
                    self.lastError = DemoModel.describe(error)
                }
            }

            self.reconnectTask = nil
            self.isReconnecting = false
            self.reconnectAttempt = self.reconnectDelays.count
            self.reconnectExhausted = true
            self.connectionState = .disconnected
            self.lastError = "All automatic reconnect attempts failed."
        }
    }

    func reconnectManually() {
        reconnectExhausted = false
        guard let device = connectedDevice ?? reconnectTarget else { return }
        connect(device)
    }

    func cancelReconnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        reconnectNextAttemptAt = nil
        reconnectExhausted = false
        reconnectTarget = nil
        isReconnecting = false
    }
}
