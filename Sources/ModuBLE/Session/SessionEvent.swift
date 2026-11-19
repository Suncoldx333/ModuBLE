import Foundation

/// An unsolicited, already decrypted frame pushed by the peripheral.
///
/// The session decrypts and authenticates every event before it reaches this
/// type, so `payload` is trusted plaintext — but it is still application data:
/// the link layer knows nothing about its structure.
///
/// `sequence` belongs to the peripheral's own counter and is **independent** of
/// the request sequence. It advances across requests, so do not expect it to
/// match anything the central sent.
public struct SessionEvent: Equatable, Sendable {
    public let sequence: UInt32
    public let payload: Data
    public let receivedAt: Date

    public init(sequence: UInt32, payload: Data, receivedAt: Date = Date()) {
        self.sequence = sequence
        self.payload = payload
        self.receivedAt = receivedAt
    }
}
