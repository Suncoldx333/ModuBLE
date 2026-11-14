import Foundation
import CryptoKit

/// AES-128-CBC with HMAC-SHA256, using Encrypt-then-MAC.
///
/// Envelope layout:
///
/// ```text
/// Version (1) | IV (16) | Ciphertext (n) | HMAC-SHA256 (32)
/// ```
///
/// The version byte is `0x02`, distinct from GCM's `0x01`, so a receiver can
/// tell the two formats apart from the first byte instead of guessing by length.
///
/// The HMAC covers `Version | IV | Ciphertext`, so a modified IV, ciphertext or
/// version is rejected **before** any decryption happens. CBC provides no
/// integrity on its own; that is exactly why the MAC exists.
///
/// The caller supplies one 256-bit master key; the AES key and the HMAC key are
/// derived from it with HKDF-SHA256 so that the same key material is never used
/// for two different primitives.
public struct AESCBCProvider: CryptoProvider {
    public static let envelopeVersion: UInt8 = 0x02
    public static let ivLength = 16
    public static let tagLength = 32
    public static let masterKeyLength = 32

    public let algorithm: CryptoAlgorithm = .aes128CBCHMAC

    private let encryptionKey: Data
    private let macKey: SymmetricKey
    private let ivGenerator: any NonceGenerator

    public init(key: Data, ivGenerator: any NonceGenerator = SystemNonceGenerator()) throws {
        guard key.count == Self.masterKeyLength else {
            throw CryptoError.invalidKeyLength(key.count)
        }

        let material = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key),
            salt: Data("ModuBLE".utf8),
            info: Data("\(CryptoAlgorithm.aes128CBCHMAC.rawValue)/v1".utf8),
            outputByteCount: 16 + 32
        )
        let bytes = material.withUnsafeBytes { Data($0) }

        self.encryptionKey = Data(bytes.prefix(16))
        self.macKey = SymmetricKey(data: bytes.suffix(32))
        self.ivGenerator = ivGenerator
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        let iv = try ivGenerator.makeNonce(count: Self.ivLength)
        guard iv.count == Self.ivLength else {
            throw CryptoError.malformedEnvelope
        }

        let padded = PKCS7.pad(plaintext)
        let ciphertext = try CBCPrimitive.encrypt(padded, key: encryptionKey, iv: iv)

        var signed = Data(capacity: 1 + Self.ivLength + ciphertext.count)
        signed.append(Self.envelopeVersion)
        signed.append(iv)
        signed.append(ciphertext)

        let mac = HMAC<SHA256>.authenticationCode(for: signed, using: macKey)
        signed.append(contentsOf: mac)
        return signed
    }

    public func decrypt(_ envelope: Data) throws -> Data {
        let bytes = [UInt8](envelope)
        let prefixLength = 1 + Self.ivLength
        guard let version = bytes.first else {
            throw CryptoError.malformedEnvelope
        }
        guard version == Self.envelopeVersion else {
            throw CryptoError.unsupportedEnvelopeVersion(version)
        }
        guard bytes.count >= prefixLength + CBCPrimitive.blockSize + Self.tagLength else {
            throw CryptoError.malformedEnvelope
        }

        let signedEnd = bytes.count - Self.tagLength
        let signed = Data(bytes[0..<signedEnd])
        let mac = Data(bytes[signedEnd...])

        // Encrypt-then-MAC: verify first, decrypt only on success.
        guard HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: signed, using: macKey) else {
            throw CryptoError.authenticationFailed
        }

        let iv = Data(bytes[1..<prefixLength])
        let ciphertext = Data(bytes[prefixLength..<signedEnd])
        guard !ciphertext.isEmpty, ciphertext.count % CBCPrimitive.blockSize == 0 else {
            throw CryptoError.malformedEnvelope
        }

        let padded = try CBCPrimitive.decrypt(ciphertext, key: encryptionKey, iv: iv)
        return try PKCS7.unpad(padded)
    }
}
