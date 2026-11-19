import Foundation

public enum SessionError: Error, Equatable, Sendable {
    /// Another request is still waiting for its response.
    case busy
    /// No response arrived before the timeout.
    case timedOut
    /// The plaintext is larger than the selected cipher can seal into one frame.
    case payloadTooLarge(max: Int)
    /// The session or the underlying link was closed.
    case closed
    /// A response arrived for a different sequence number.
    ///
    /// Kept for source compatibility. Stale responses are now dropped and
    /// logged instead of failing the request that is currently in flight, so
    /// this case is no longer produced by `EncryptedSession`.
    case unexpectedResponse(expected: UInt32, received: UInt32)
    case crypto(CryptoError)
    case framing(PacketError)
    case transport(BLEError)
}
