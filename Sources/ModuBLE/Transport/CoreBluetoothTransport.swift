import Foundation

/// Adapts `BLECentralManager` to `DeviceTransport`.
///
/// This type exists only so the SDK can expose one transport-agnostic API:
/// `BLECentralManager.connect` returns the concrete `BLEConnection`, and Swift
/// does not allow a protocol witness to narrow a `any DeviceLink` return type.
/// Every method forwards without adding logic, so the verified CoreBluetooth
/// behaviour is unchanged.
public final class CoreBluetoothTransport: DeviceTransport {
    public let kind: TransportKind = .coreBluetooth

    private let central: BLECentralManager

    public init(logStore: CommunicationLogStore? = nil) {
        self.central = BLECentralManager(logStore: logStore)
    }

    /// Latest known state, readable without starting a scan.
    public var bluetoothState: BluetoothState {
        central.bluetoothState
    }

    public func observeBluetoothState() -> AsyncStream<BluetoothState> {
        central.observeBluetoothState()
    }

    public func scan(
        profile: GATTProfile
    ) async throws -> AsyncThrowingStream<[DiscoveredDevice], Error> {
        try await central.scan(profile: profile)
    }

    public func stopScan() async {
        await central.stopScan()
    }

    public func connect(
        _ device: DiscoveredDevice,
        profile: GATTProfile
    ) async throws -> any DeviceLink {
        try await central.connect(device, profile: profile)
    }

    public func cancelPendingConnection() async {
        await central.cancelPendingConnection()
    }
}
