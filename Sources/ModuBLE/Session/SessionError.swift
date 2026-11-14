import Foundation

public enum SessionError: Error, Equatable, Sendable {
    /// Another request is still waiting for its response.
    case busy
    /// No response arrived before the timeout.
    case timedOut
    /// The session or the underlying link was closed.
    case closed
    /// A response arrived for a different sequence number.
    case unexpectedResponse(expected: UInt32, received: UInt32)
    case crypto(CryptoError)
    case framing(PacketError)
    case transport(BLEError)
}
