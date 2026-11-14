import Foundation
import CoreBluetooth

/// Owns the `CBCentralManager` and turns CoreBluetooth callbacks into
/// `AsyncStream` and `async` APIs. `CBPeripheral` never leaves this module.
///
/// One connection is active at a time. CoreBluetooth state lives on a private
/// serial queue; the class is `@unchecked Sendable` because every access to that
/// state happens on that queue.
public final class BLECentralManager: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.moduble.central", qos: .userInitiated)
    private let logStore: CommunicationLogStore?

    /// Upper bound for a connection attempt before the peripheral answers.
    private static let connectionTimeout: TimeInterval = 15

    // MARK: - Queue-confined state

    private var central: CBCentralManager?
    private var profile: GATTProfile?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var discovered: [UUID: DiscoveredDevice] = [:]

    private var scanContinuation: AsyncThrowingStream<[DiscoveredDevice], Error>.Continuation?
    private var powerWaiters: [CheckedContinuation<Void, Error>] = []
    private var pendingConnection: (connection: BLEConnection, continuation: CheckedContinuation<BLEConnection, Error>)?
    private var activeConnection: BLEConnection?
    private var activePeripheral: CBPeripheral?
    private var stateObservers: [UUID: AsyncStream<BluetoothState>.Continuation] = [:]

    private let bluetoothStateLock = NSLock()
    private var bluetoothStateStorage: BluetoothState = .unknown

    public init(logStore: CommunicationLogStore? = nil) {
        self.logStore = logStore
        super.init()
    }

    // MARK: - Bluetooth state

    /// Latest known Bluetooth state, readable from any thread.
    public var bluetoothState: BluetoothState {
        bluetoothStateLock.withLock { bluetoothStateStorage }
    }

    /// Broadcasts every Bluetooth state change, starting with the current value.
    ///
    /// Creating a central manager alerts the user when Bluetooth is off, so this
    /// is also what activates the SDK without starting a scan.
    public func observeBluetoothState() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            let id = UUID()
            queue.async { [self] in
                activateLocked()
                stateObservers[id] = continuation
                continuation.yield(bluetoothState)
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.stateObservers[id] = nil }
                }
            }
        }
    }

    // MARK: - Scanning

    /// Starts scanning for peripherals advertising `profile.serviceUUID`.
    ///
    /// The stream yields the full, sorted device list on every discovery, so the
    /// consumer can just replace its table. Finishing the stream (or calling
    /// `stopScan`) stops the scan.
    public func scan(
        profile: GATTProfile,
        allowDuplicates: Bool = true
    ) async throws -> AsyncThrowingStream<[DiscoveredDevice], Error> {
        try await ensurePoweredOn()

        return await withCheckedContinuation { (continuation: CheckedContinuation<AsyncThrowingStream<[DiscoveredDevice], Error>, Never>) in
            queue.async { [self] in
                // Finish any previous scan before the new continuation exists.
                stopScanLocked()

                self.profile = profile
                self.peripherals.removeAll()
                self.discovered.removeAll()

                let stream = AsyncThrowingStream<[DiscoveredDevice], Error> { streamContinuation in
                    // Called synchronously, still on `queue`.
                    self.scanContinuation = streamContinuation
                    streamContinuation.onTermination = { [weak self] _ in
                        guard let self else { return }
                        self.queue.async { self.stopScanLocked() }
                    }
                }

                self.startScanLocked(profile: profile, allowDuplicates: allowDuplicates)
                continuation.resume(returning: stream)
            }
        }
    }

    public func stopScan() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                stopScanLocked()
                continuation.resume()
            }
        }
    }

    // MARK: - Connecting

    /// Connects, discovers the GATT profile and subscribes to TX.
    ///
    /// The returned connection is ready to write. Throws if the peripheral is
    /// unknown (scan expired), if a connection already exists, or if setup fails.
    public func connect(_ device: DiscoveredDevice, profile: GATTProfile) async throws -> BLEConnection {
        try await ensurePoweredOn()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<BLEConnection, Error>) in
            queue.async { [self] in
                guard activeConnection == nil, pendingConnection == nil else {
                    continuation.resume(throwing: BLEError.connectionFailed("Another connection is already active"))
                    return
                }
                guard let peripheral = peripherals[device.id] else {
                    continuation.resume(throwing: BLEError.peripheralNotFound)
                    return
                }
                guard device.isConnectable != false else {
                    continuation.resume(throwing: BLEError.peripheralNotConnectable)
                    return
                }

                self.profile = profile
                stopScanLocked()

                let connection = BLEConnection(
                    peripheral: peripheral,
                    device: device,
                    profile: profile,
                    queue: queue,
                    logStore: logStore
                ) { [weak self] id in
                    guard let self else { return }
                    // Already on `queue`; defer so `close()` can still resume.
                    self.queue.async { self.handleConnectionClosed(id) }
                }

                pendingConnection = (connection, continuation)
                activePeripheral = peripheral

                // If the system already holds a link (reconnect, or a previous
                // session that was not torn down), `connect` never calls back.
                if peripheral.state == .connected {
                    pendingConnection = nil
                    activeConnection = connection
                    logStore?.log(.info, .ble, "Link already up · \(device.displayName)")
                    startSetup(connection, continuation)
                    return
                }

                logStore?.log(.info, .ble, "Connecting to \(device.displayName)")
                logStore?.log(.debug, .ble, "Peripheral state before connect: \(Self.describe(peripheral.state))")
                central?.connect(peripheral, options: nil)

                // CoreBluetooth sometimes never calls back at all (peripheral
                // vanished mid-connect). Never leave the caller suspended.
                let connectionID = connection.id
                queue.asyncAfter(deadline: .now() + Self.connectionTimeout) { [weak self] in
                    guard let self,
                          let pending = self.pendingConnection,
                          pending.connection.id == connectionID else { return }
                    self.pendingConnection = nil
                    pending.continuation.resume(throwing: BLEError.connectionTimedOut)
                    self.logStore?.log(.error, .ble, "Peripheral did not accept the connection within \(Int(Self.connectionTimeout)) s")
                    self.cancelConnectionLocked()
                }
            }
        }
    }

    /// Runs discovery + subscription and resolves the caller's continuation.
    ///
    /// Must be called on `queue` with `pendingConnection` already cleared, so the
    /// connect timeout can never double-resume.
    private func startSetup(
        _ connection: BLEConnection,
        _ continuation: CheckedContinuation<BLEConnection, Error>
    ) {
        Task { [self] in
            do {
                try await connection.prepare()
                continuation.resume(returning: connection)
            } catch {
                continuation.resume(throwing: error)
                queue.async { self.cancelConnectionLocked() }
            }
        }
    }

    /// Abandons an in-flight connection attempt. Safe to call at any time.
    public func cancelPendingConnection() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                if let pending = pendingConnection {
                    pendingConnection = nil
                    pending.continuation.resume(throwing: BLEError.cancelled)
                    logStore?.log(.info, .ble, "Connection attempt cancelled")
                    cancelConnectionLocked()
                }
                continuation.resume()
            }
        }
    }

    /// Blocks until the central manager exists and is powered on.
    private func ensurePoweredOn() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                activateLocked()
                powerWaiters.append(continuation)
                resolvePowerWaitersLocked()
            }
        }
    }

    @discardableResult
    private func activateLocked() -> CBCentralManager {
        if let central {
            return central
        }
        let manager = CBCentralManager(
            delegate: self,
            queue: queue,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        central = manager
        return manager
    }

    /// Must run on `queue`.
    private func setBluetoothStateLocked(_ state: CBManagerState) {
        let mapped = Self.bluetoothState(for: state)
        bluetoothStateLock.withLock { bluetoothStateStorage = mapped }
        for observer in stateObservers.values {
            observer.yield(mapped)
        }
    }

    // MARK: - Locked helpers (must run on `queue`)

    private func startScanLocked(profile: GATTProfile, allowDuplicates: Bool) {
        guard let central, central.state == .poweredOn else { return }
        central.scanForPeripherals(
            withServices: [CBUUID(string: profile.serviceUUID)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
        logStore?.log(.debug, .ble, "Scan started for \(profile.serviceUUID)")
    }

    private func stopScanLocked() {
        central?.stopScan()
        scanContinuation?.finish()
        scanContinuation = nil
    }

    private func resolvePowerWaitersLocked() {
        guard let state = central?.state, state != .unknown, state != .resetting else { return }
        let waiters = powerWaiters
        powerWaiters.removeAll()

        for waiter in waiters {
            if state == .poweredOn {
                waiter.resume()
            } else {
                waiter.resume(throwing: Self.error(for: state))
            }
        }
    }

    private func handleConnectionClosed(_ id: UUID) {
        guard let active = activeConnection, active.id == id else { return }
        cancelConnectionLocked()
    }

    private func cancelConnectionLocked() {
        activeConnection = nil
        if let peripheral = activePeripheral {
            activePeripheral = nil
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    private func failPendingConnection(_ error: BLEError) {
        let pending = pendingConnection
        pendingConnection = nil
        pending?.continuation.resume(throwing: error)
    }

    static func bluetoothState(for state: CBManagerState) -> BluetoothState {
        switch state {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .resetting: return .resetting
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    static func error(for state: CBManagerState) -> BLEError {
        switch state {
        case .poweredOff: return .bluetoothOff
        case .unauthorized: return .bluetoothUnauthorized
        case .unsupported: return .bluetoothUnsupported
        case .resetting, .unknown: return .bluetoothResetting
        case .poweredOn: return .notReady
        @unknown default: return .bluetoothUnsupported
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLECentralManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        setBluetoothStateLocked(central.state)
        resolvePowerWaitersLocked()

        if central.state != .poweredOn {
            stopScanLocked()
            failPendingConnection(Self.error(for: central.state))
            if let active = activeConnection {
                activeConnection = nil
                active.handleDisconnection(error: nil)
            }
        }
        logStore?.log(.info, .ble, "Central state: \(Self.describe(central.state))")
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        var device = discovered[peripheral.identifier] ?? DiscoveredDevice(id: peripheral.identifier)

        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey as String] as? String
        device.name = advertisedName ?? device.name ?? peripheral.name
        device.rssi = RSSI.intValue
        device.lastSeen = Date()

        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey as String] as? [CBUUID] {
            for uuid in serviceUUIDs where !device.advertisedServiceUUIDs.contains(uuid.uuidString) {
                device.advertisedServiceUUIDs.append(uuid.uuidString)
            }
        }

        if let connectable = advertisementData[CBAdvertisementDataIsConnectable as String] as? NSNumber {
            device.isConnectable = connectable.boolValue
        }

        discovered[peripheral.identifier] = device
        peripherals[peripheral.identifier] = peripheral

        let snapshot = discovered.values.sorted { $0.displayName < $1.displayName }
        scanContinuation?.yield(snapshot)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let pending = pendingConnection, pending.connection.peripheral === peripheral else {
            return
        }
        pendingConnection = nil
        activeConnection = pending.connection
        logStore?.log(.info, .ble, "Connected at ATT level · \(peripheral.name ?? peripheral.identifier.uuidString)")
        startSetup(pending.connection, pending.continuation)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let reason = error?.localizedDescription ?? "Unknown error"
        logStore?.log(.error, .ble, "Connection failed: \(reason)")
        activePeripheral = nil
        failPendingConnection(.connectionFailed(reason))
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        if let error {
            let nsError = error as NSError
            logStore?.log(
                .error,
                .ble,
                "Disconnected: \(error.localizedDescription) [\(nsError.domain):\(nsError.code)]"
            )
        } else {
            logStore?.log(.info, .ble, "Disconnected by peripheral")
        }

        guard let active = activeConnection, active.peripheral === peripheral else { return }
        activeConnection = nil
        activePeripheral = nil
        // `close()` already marked the connection closed, so this is a no-op for
        // user-initiated disconnects.
        active.handleDisconnection(error: error)
    }

    private static func describe(_ state: CBPeripheralState) -> String {
        switch state {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }

    private static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
}
