import Foundation

public enum CryptoAlgorithm: String, CaseIterable, Sendable {
    case aes128GCM
    case aes128CBCHMAC

    public var displayName: String {
        switch self {
        case .aes128GCM: return "AES-128-GCM"
        case .aes128CBCHMAC: return "AES-128-CBC + HMAC-SHA256"
        }
    }

    /// Compact label for pickers and segmented controls.
    public var shortName: String {
        switch self {
        case .aes128GCM: return "AES-GCM"
        case .aes128CBCHMAC: return "AES-CBC"
        }
    }
}

/// Turns plaintext into a self-describing sealed envelope and back.
///
/// The returned bytes already contain everything needed to decrypt them except
/// the key: envelope version, nonce/IV, ciphertext and authentication tag.
/// Callers must not prepend or slice these bytes.
///
/// The two implementations deliberately use **different envelope layouts**
/// (`Version | Nonce | Ciphertext | Tag` for GCM,
/// `Version | IV | Ciphertext | HMAC` for CBC) and must never be mixed.
public protocol CryptoProvider: Sendable {
    var algorithm: CryptoAlgorithm { get }
    func encrypt(_ plaintext: Data) throws -> Data
    func decrypt(_ ciphertext: Data) throws -> Data
    /// Largest plaintext that still fits in one packet payload after sealing.
    var maxPlaintextLength: Int { get }
}

extension CryptoProvider {
    /// Derived from the documented envelope layouts, so a provider that keeps
    /// the standard framing needs no extra code and one that does not can
    /// override it.
    public var maxPlaintextLength: Int {
        let capacity = PacketCodec.maxPayloadLength
        switch algorithm {
        case .aes128GCM:
            return capacity - (1 + AESGCMProvider.nonceLength + AESGCMProvider.tagLength)
        case .aes128CBCHMAC:
            // PKCS#7 always adds 1…16 bytes, so the padded ciphertext must fit
            // in a whole number of blocks below the capacity.
            let usable = capacity - (1 + AESCBCProvider.ivLength + AESCBCProvider.tagLength)
            return usable / CBCPrimitive.blockSize * CBCPrimitive.blockSize - 1
        }
    }
}

public enum CryptoError: Error, Equatable, Sendable {
    case invalidKeyLength(Int)
    /// The envelope is shorter than its fixed-size prefix.
    case malformedEnvelope
    case unsupportedEnvelopeVersion(UInt8)
    /// Authentication failed. The plaintext was *not* returned.
    case authenticationFailed
    /// CBC padding was malformed after a successful MAC check.
    case invalidPadding
    case cipherFailure(status: Int32)
}
