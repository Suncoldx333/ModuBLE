import Foundation

/// The GATT shape the SDK expects from a ModuBLE peripheral.
///
/// UUIDs are configuration, never hard-coded inside the transport, so the same
/// SDK can talk to a different device layout without a code change.
public struct GATTProfile: Equatable, Sendable {
    public enum WriteMode: String, Equatable, Sendable {
        /// Write request; the peripheral acknowledges at the ATT layer.
        case withResponse
        /// Write command; faster, but no per-write acknowledgement.
        case withoutResponse
        /// Use `withResponse` when the characteristic supports it.
        case automatic
    }

    public let serviceUUID: String
    /// Characteristic the central writes to (RX from the peripheral's view).
    public let rxCharacteristicUUID: String
    /// Characteristic the peripheral notifies on (TX from the peripheral's view).
    public let txCharacteristicUUID: String
    public let writeMode: WriteMode

    public init(
        serviceUUID: String,
        rxCharacteristicUUID: String,
        txCharacteristicUUID: String,
        writeMode: WriteMode = .automatic
    ) {
        self.serviceUUID = serviceUUID.uppercased()
        self.rxCharacteristicUUID = rxCharacteristicUUID.uppercased()
        self.txCharacteristicUUID = txCharacteristicUUID.uppercased()
        self.writeMode = writeMode
    }
}

extension GATTProfile {
    /// Layout exposed by the reference Mac peripheral app in `Demo/`.
    ///
    /// RX accepts both write types; TX is notify-only. This is a real, verified
    /// definition — see `Documentation/Peripheral-GATT.md`.
    public static let referencePeripheral = GATTProfile(
        serviceUUID: "5A0C8B3E-7D2F-4A6B-9C1D-3E5F7A9B1C2D",
        rxCharacteristicUUID: "9F8E7D6C-5B4A-3F2E-8D7C-6B5A4F3E2D1C",
        txCharacteristicUUID: "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D",
        writeMode: .withResponse
    )
}
