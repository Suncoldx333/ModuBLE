import Foundation

public struct MockConfiguration: Sendable {
    /// Advertised MTU payload. 182 bytes is a realistic BLE 4.2 / iOS value and
    /// still forces multi-chunk traffic for anything larger.
    public var maximumWritePayloadLength: Int
    /// Runs a background emitter once `START` is received. Tests disable it and
    /// call `MockBLELink.emitTelemetryNow()` instead.
    public var autoTelemetry: Bool
    public var telemetryTick: Duration
    public var faults: FaultConfiguration

    public init(
        maximumWritePayloadLength: Int = 182,
        autoTelemetry: Bool = true,
        telemetryTick: Duration = .milliseconds(50),
        faults: FaultConfiguration = FaultConfiguration()
    ) {
        self.maximumWritePayloadLength = max(1, maximumWritePayloadLength)
        self.autoTelemetry = autoTelemetry
        self.telemetryTick = telemetryTick
        self.faults = faults
    }
}

/// A transport that discovers and "connects to" virtual devices.
///
/// It exists so the iOS demo, the tests and CI can run the full encrypted
/// pipeline with no hardware and no radio. The device catalogue uses stable
/// UUIDs, so a reconnect after an app restart still resolves.
public final class MockDeviceTransport: DeviceTransport, @unchecked Sendable {
    public let kind: TransportKind = .mock

    private let profile: GATTProfile
    private let keys: MockKeys
    private let logStore: CommunicationLogStore?
    private let devices: [DiscoveredDevice]

    private let lock = NSLock()
    private var defaultFaults: FaultConfiguration
    private var scanContinuation: AsyncThrowingStream<[DiscoveredDevice], Error>.Continuation?
    private var currentLink: MockBLELink?
    /// Guards the window between the "already active" check and the link being
    /// published, which contains an `await stopScan()`.
    private var isConnecting = false

    public init(
        profile: GATTProfile = .referencePeripheral,
        keys: MockKeys = MockKeys(),
        configuration: MockConfiguration = MockConfiguration(),
        logStore: CommunicationLogStore? = nil
    ) {
        self.profile = profile
        self.keys = keys
        self.logStore = logStore
        self.devices = Self.makeCatalogue(serviceUUID: profile.serviceUUID)
        self.maximumWritePayloadLength = configuration.maximumWritePayloadLength
        self.autoTelemetry = configuration.autoTelemetry
        self.telemetryTick = configuration.telemetryTick
        self.defaultFaults = configuration.faults
    }

    private let maximumWritePayloadLength: Int
    private let autoTelemetry: Bool
    private let telemetryTick: Duration

    // MARK: - DeviceTransport

    public func observeBluetoothState() -> AsyncStream<BluetoothState> {
        // The mock always has a working radio, so a single value is the whole
        // truth. Finishing avoids leaving a consumer suspended forever.
        AsyncStream { continuation in
            continuation.yield(.poweredOn)
            continuation.finish()
        }
    }

    public func scan(
        profile: GATTProfile
    ) async throws -> AsyncThrowingStream<[DiscoveredDevice], Error> {
        await stopScan()

        let (stream, continuation) = AsyncThrowingStream<[DiscoveredDevice], Error>.makeStream()
        lock.withLock { scanContinuation = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.scanContinuation = nil }
        }
        continuation.yield(devices)
        logStore?.log(.debug, .ble, "Mock scan started for \(profile.serviceUUID)")
        return stream
    }

    public func stopScan() async {
        let continuation: AsyncThrowingStream<[DiscoveredDevice], Error>.Continuation? = lock.withLock {
            let existing = scanContinuation
            scanContinuation = nil
            return existing
        }
        continuation?.finish()
    }

    public func connect(
        _ device: DiscoveredDevice,
        profile: GATTProfile
    ) async throws -> any DeviceLink {
        // `stopScan()` below suspends, so check and claim the slot in one
        // critical section. Otherwise two concurrent calls both pass the guard
        // and the second overwrites `currentLink`.
        let admitted = lock.withLock { () -> Bool in
            if let existing = currentLink, !existing.isClosed { return false }
            guard !isConnecting else { return false }
            isConnecting = true
            return true
        }
        guard admitted else {
            throw BLEError.connectionFailed("Another connection is already active")
        }
        defer { lock.withLock { isConnecting = false } }

        guard let known = devices.first(where: { $0.id == device.id }) else {
            throw BLEError.peripheralNotFound
        }

        await stopScan()

        let faults = lock.withLock { defaultFaults }
        let injector = FaultInjector(configuration: faults)
        let link = MockBLELink(
            device: known,
            peripheral: MockPeripheral(keys: keys),
            injector: injector,
            maximumWritePayloadLength: maximumWritePayloadLength,
            autoTelemetry: autoTelemetry,
            telemetryTick: telemetryTick,
            logStore: logStore
        )

        lock.withLock {
            currentLink = link
        }
        logStore?.log(.info, .ble, "Mock connected · \(known.displayName)")
        return link
    }

    public func cancelPendingConnection() async {
        // Connecting is instantaneous; there is nothing to cancel.
    }

    // MARK: - Demo controls

    public var activeLink: MockBLELink? {
        lock.withLock { currentLink }
    }

    /// Applies a new fault configuration to the live link **and** remembers it
    /// for the next connection, so the settings survive a reconnect.
    public func applyFaultConfiguration(_ faults: FaultConfiguration) {
        let link = lock.withLock { () -> MockBLELink? in
            defaultFaults = faults
            return currentLink
        }
        link?.injector.configuration = faults
    }

    // MARK: - Catalogue

    private static func makeCatalogue(serviceUUID: String) -> [DiscoveredDevice] {
        [
            DiscoveredDevice(
                id: UUID(uuidString: "5A0C0000-0000-4000-8000-000000000001")!,
                name: "Mock Motion Sensor",
                rssi: -48,
                advertisedServiceUUIDs: [serviceUUID.uppercased()],
                isConnectable: true
            ),
            DiscoveredDevice(
                id: UUID(uuidString: "5A0C0000-0000-4000-8000-000000000002")!,
                name: "Mock Environment Sensor",
                rssi: -67,
                advertisedServiceUUIDs: [serviceUUID.uppercased()],
                isConnectable: true
            )
        ]
    }
}
