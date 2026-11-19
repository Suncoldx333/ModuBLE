import Foundation

/// An application-layer frame exchanged over a GATT write / notification.
///
/// Wire layout (10-byte header, big-endian integers):
///
/// ```text
/// Magic "MB" (2) | Version (1) | Kind (1) | Sequence (4) | Payload Length (2) | Payload (n)
/// ```
///
/// The frame intentionally carries **no CRC**. BLE protects the link with its own
/// CRC, and encrypted payloads get their integrity from an AEAD tag (GCM) or an
/// HMAC (CBC). A CRC here would add bytes without adding security.
///
/// `sequence` lets a responder correlate an answer with its request. It is a
/// plain 32-bit counter, not a security token.
public struct Packet: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        /// A request that expects a `response`.
        case request = 0x01
        /// An answer to an earlier `request`, carrying the same sequence.
        case response = 0x02
        /// An unsolicited event pushed by the peripheral.
        case event = 0x03
        /// Opaque application bytes (plaintext demo traffic, debugging).
        case raw = 0x7F
    }

    public static let version: UInt8 = 0x01
    /// "MB" — magic bytes that start every frame.
    public static let magic: [UInt8] = [0x4D, 0x42]
    /// Size of the fixed header preceding the payload.
    public static let headerLength = 10

    public let kind: Kind
    public let sequence: UInt32
    public let payload: Data

    public init(kind: Kind, sequence: UInt32, payload: Data = Data()) {
        self.kind = kind
        self.sequence = sequence
        self.payload = payload
    }
}
