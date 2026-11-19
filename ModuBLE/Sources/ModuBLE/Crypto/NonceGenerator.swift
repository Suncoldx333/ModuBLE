import Foundation

/// Source of nonces and IVs. Injectable so tests can make output deterministic.
public protocol NonceGenerator: Sendable {
    func makeNonce(count: Int) throws -> Data
}

/// Cryptographically secure random bytes from the system CSPRNG.
public struct SystemNonceGenerator: NonceGenerator {
    public init() {}

    public func makeNonce(count: Int) throws -> Data {
        precondition(count > 0, "Nonce length must be positive")
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8.random(in: .min ... .max, using: &generator))
        }
        return Data(bytes)
    }
}
