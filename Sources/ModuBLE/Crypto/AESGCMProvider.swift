import Foundation
import CryptoKit

/// AES-128-GCM with a `Version | Nonce | Ciphertext | AuthTag` envelope.
///
/// GCM is the default choice: it authenticates the whole message, so a
/// modification anywhere in the envelope makes decryption fail instead of
/// returning attacker-chosen plaintext.
///
/// The nonce is random per message. With a 96-bit random nonce and a fixed key,
/// the probability of a repeat stays negligible for demo-scale traffic. A
/// production deployment that encrypts millions of messages under one key must
/// switch to a counter-based nonce instead.
public struct AESGCMProvider: CryptoProvider {
    public static let envelopeVersion: UInt8 = 0x01
    public static let nonceLength = 12
    public static let tagLength = 16
    public static let keyLength = 16

    public let algorithm: CryptoAlgorithm = .aes128GCM

    private let key: SymmetricKey
    private let nonceGenerator: any NonceGenerator

    public init(key: Data, nonceGenerator: any NonceGenerator = SystemNonceGenerator()) throws {
        guard key.count == Self.keyLength else {
            throw CryptoError.invalidKeyLength(key.count)
        }
        self.key = SymmetricKey(data: key)
        self.nonceGenerator = nonceGenerator
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        let nonceBytes = try nonceGenerator.makeNonce(count: Self.nonceLength)
        guard nonceBytes.count == Self.nonceLength else {
            throw CryptoError.malformedEnvelope
        }

        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)

        var envelope = Data(capacity: 1 + Self.nonceLength + sealed.ciphertext.count + Self.tagLength)
        envelope.append(Self.envelopeVersion)
        envelope.append(nonceBytes)
        envelope.append(sealed.ciphertext)
        envelope.append(sealed.tag)
        return envelope
    }

    public func decrypt(_ envelope: Data) throws -> Data {
        let bytes = [UInt8](envelope)
        let overhead = 1 + Self.nonceLength + Self.tagLength
        guard let version = bytes.first else {
            throw CryptoError.malformedEnvelope
        }
        guard version == Self.envelopeVersion else {
            throw CryptoError.unsupportedEnvelopeVersion(version)
        }
        guard bytes.count >= overhead else {
            throw CryptoError.malformedEnvelope
        }

        let nonceStart = 1
        let nonceEnd = nonceStart + Self.nonceLength
        let tagStart = bytes.count - Self.tagLength

        let nonce = try AES.GCM.Nonce(data: Data(bytes[nonceStart..<nonceEnd]))
        let ciphertext = Data(bytes[nonceEnd..<tagStart])
        let tag = Data(bytes[tagStart...])

        do {
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw CryptoError.authenticationFailed
        }
    }
}
