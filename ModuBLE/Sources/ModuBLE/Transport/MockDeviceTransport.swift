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
    private let configuration: MockConfiguration
    private let logStore: CommunicationLogStore?
    private let devices: [DiscoveredDevice]

    private let lock = NSLock()
    private var scanContinuation: AsyncThrowingStream<[DiscoveredDevice], Error>.Continuation?
    private var currentLink: MockBLELink?
    private var currentInjector: FaultInjector?

    public init(
        profile: GATTProfile = .referencePeripheral,
        keys: MockKeys = MockKeys(),
        configuration: MockConfiguration = MockConfiguration(),
        logStore: CommunicationLogStore? = nil
    ) {
        self.profile = profile
        self.keys = keys
        self.configuration = configuration
        self.logStore = logStore
        self.devices = Self.makeCatalogue(serviceUUID: profile.serviceUUID)
    }

    // MARK: - DeviceTransport

    public func observeBluetoothState() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            continuation.yield(.poweredOn)
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
        if let existing = activeLink, !existing.isClosed {
            throw BLEError.connectionFailed("Another connection is already active")
        }
        guard let known = devices.first(where: { $0.id == device.id }) else {
            throw BLEError.peripheralNotFound
        }

        await stopScan()

        let injector = FaultInjector(configuration: configuration.faults)
        let link = MockBLELink(
            device: known,
            peripheral: MockPeripheral(keys: keys),
            injector: injector,
            maximumWritePayloadLength: configuration.maximumWritePayloadLength,
            autoTelemetry: configuration.autoTelemetry,
            telemetryTick: configuration.telemetryTick,
            logStore: logStore
        )

        lock.withLock {
            currentLink = link
            currentInjector = injector
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

    /// Applies a new fault configuration to the live link. No-op when nothing is
    /// connected; the next connection picks up `configuration.faults`.
    public func applyFaultConfiguration(_ faults: FaultConfiguration) {
        lock.withLock { currentInjector }?.configuration = faults
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
