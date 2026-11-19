import Foundation

/// Where a discovered device came from.
///
/// The UI uses this to label devices and to decide which controls make sense:
/// fault injection only applies to `.mock`, and real-link timing only exists on
/// `.coreBluetooth`.
public enum TransportKind: String, Sendable, CaseIterable, Equatable {
    case coreBluetooth
    case mock

    public var label: String {
        switch self {
        case .coreBluetooth: return "CoreBluetooth"
        case .mock: return "Mock"
        }
    }
}

/// A live link to one device.
///
/// `BLELink` is deliberately minimal: bytes in, bytes out. A device session also
/// needs to know *which* device it is talking to, when the link dies, and how
/// much fits in one write — so those live here rather than leaking CoreBluetooth
/// types into the session layer.
///
/// `BLEConnection` already provides every member, so it conforms with an empty
/// extension. A mock link implements the same shape without CoreBluetooth.
public protocol DeviceLink: BLELink {
    var device: DiscoveredDevice { get }

    /// Phase changes, starting with the current value. Use this — not `inbound`
    /// — to notice a disconnect while no request is in flight.
    func observeState() -> AsyncStream<ConnectionState>

    /// Largest payload per write request, as negotiated.
    var maximumWritePayloadLength: Int { get }
    /// Largest payload per write command; `ATT MTU = this + 3`.
    var maximumWritePayloadLengthWithoutResponse: Int { get }

    /// Writes using an explicit write mode. Transports without write modes use
    /// the default implementation and ignore `mode`.
    func write(_ data: Data, mode: GATTProfile.WriteMode?) async throws
}

extension DeviceLink {
    public func write(_ data: Data, mode: GATTProfile.WriteMode?) async throws {
        try await write(data)
    }
}

/// Discovers and connects to devices, and produces a `DeviceLink`.
///
/// The protocol intentionally mirrors the existing `BLECentralManager` API so the
/// CoreBluetooth adapter is pure forwarding and cannot change verified behaviour.
public protocol DeviceTransport: Sendable {
    var kind: TransportKind { get }

    func observeBluetoothState() -> AsyncStream<BluetoothState>

    /// Yields the full, sorted device list on every discovery. Finishing the
    /// stream stops the scan.
    func scan(profile: GATTProfile) async throws -> AsyncThrowingStream<[DiscoveredDevice], Error>

    func stopScan() async

    func connect(_ device: DiscoveredDevice, profile: GATTProfile) async throws -> any DeviceLink

    func cancelPendingConnection() async
}

// `BLEConnection` already satisfies `DeviceLink`: it is a `BLELink`, and it
// exposes `device`, `observeState()`, both MTU properties and the mode-aware
// write. Keeping the conformance empty means the verified BLE path is untouched.
extension BLEConnection: DeviceLink {}
