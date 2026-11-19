import Foundation

/// A peripheral seen during a scan.
public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    /// Stable system identifier (`CBPeripheral.identifier`), not a MAC address.
    public let id: UUID
    public var name: String?
    public var rssi: Int
    public var advertisedServiceUUIDs: [String]
    /// From `CBAdvertisementDataIsConnectable`. `false` means no central can
    /// establish a link; `nil` means the advertisement did not report it.
    public var isConnectable: Bool?
    public var lastSeen: Date

    public init(
        id: UUID,
        name: String? = nil,
        rssi: Int = 0,
        advertisedServiceUUIDs: [String] = [],
        isConnectable: Bool? = nil,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.advertisedServiceUUIDs = advertisedServiceUUIDs
        self.isConnectable = isConnectable
        self.lastSeen = lastSeen
    }

    public var displayName: String {
        name ?? id.uuidString
    }
}

public enum ConnectionState: Equatable, Sendable {    case disconnected
    case connecting
    case discovering
    case ready
    case failed(String)

    public var isBusy: Bool {
        self == .connecting || self == .discovering
    }

    public var label: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .discovering: return "Discovering services"
        case .ready: return "Ready"
        case .failed(let reason): return "Failed: \(reason)"
        }
    }
}

public enum BLEError: Error, Equatable, Sendable {
    case bluetoothOff
    case bluetoothUnauthorized
    case bluetoothUnsupported
    case bluetoothResetting
    case peripheralNotFound
    /// The advertisement says `isConnectable = false`; a link cannot be created.
    case peripheralNotConnectable
    case connectionFailed(String)
    case serviceNotFound(String)
    case characteristicNotFound(String)
    case notConnected
    case notReady
    case emptyPayload
    case writeFailed(String)
    case writeInProgress
    case notifySubscriptionFailed(String)
    case connectionLost(String?)
    /// The peripheral never accepted the connection attempt.
    case connectionTimedOut
    /// The link was up but service discovery or TX subscription never finished.
    case discoveryTimedOut
    case cancelled
}

/// Platform-neutral mirror of `CBManagerState`, so the demo can render
/// Bluetooth problems without importing CoreBluetooth.
public enum BluetoothState: Equatable, Sendable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    public var isReady: Bool {
        self == .poweredOn
    }

    /// User-facing explanation, or `nil` when everything is fine.
    public var problemDescription: String? {
        switch self {
        case .poweredOn, .unknown, .resetting:
            return nil
        case .unsupported:
            return "This device does not support Bluetooth Low Energy."
        case .unauthorized:
            return "Bluetooth permission was denied. Enable it in Settings."
        case .poweredOff:
            return "Bluetooth is off. Turn it on to scan for devices."
        }
    }
}
