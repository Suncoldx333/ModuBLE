import XCTest
@testable import ModuBLE

final class AESGCMProviderTests: XCTestCase {
    private let key128 = Data((0..<16).map(UInt8.init))
    private let key128Other = Data((100..<116).map(UInt8.init))

    func testRoundTrip() throws {
        let provider = try AESGCMProvider(key: key128)
        let plaintext = Data("START".utf8)

        let envelope = try provider.encrypt(plaintext)
        XCTAssertEqual(try provider.decrypt(envelope), plaintext)
    }

    func testRoundTripEmptyPlaintext() throws {
        let provider = try AESGCMProvider(key: key128)
        let envelope = try provider.encrypt(Data())
        XCTAssertEqual(try provider.decrypt(envelope), Data())
    }

    func testEnvelopeLayout() throws {
        let nonce = Data(repeating: 0xAB, count: AESGCMProvider.nonceLength)
        let provider = try AESGCMProvider(key: key128, nonceGenerator: FixedNonceGenerator(nonce))
        let plaintext = Data("START".utf8)

        let envelope = try provider.encrypt(plaintext)

        XCTAssertEqual(envelope[envelope.startIndex], AESGCMProvider.envelopeVersion)
        XCTAssertEqual(
            Data(envelope.dropFirst().prefix(AESGCMProvider.nonceLength)),
            nonce
        )
        // version + nonce + ciphertext (== plaintext length for GCM) + tag
        XCTAssertEqual(
            envelope.count,
            1 + AESGCMProvider.nonceLength + plaintext.count + AESGCMProvider.tagLength
        )
    }

    func testNonceIsFreshForEveryEncryption() throws {
        let provider = try AESGCMProvider(key: key128)
        let first = try provider.encrypt(Data("same".utf8))
        let second = try provider.encrypt(Data("same".utf8))

        let firstNonce = first.dropFirst().prefix(AESGCMProvider.nonceLength)
        let secondNonce = second.dropFirst().prefix(AESGCMProvider.nonceLength)

        XCTAssertNotEqual(Data(firstNonce), Data(secondNonce))
        XCTAssertNotEqual(first, second)
    }

    func testWrongKeyIsRejected() throws {
        let sender = try AESGCMProvider(key: key128)
        let receiver = try AESGCMProvider(key: key128Other)
        let envelope = try sender.encrypt(Data("START".utf8))

        XCTAssertThrowsError(try receiver.decrypt(envelope)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testTamperedCiphertextIsRejected() throws {
        let provider = try AESGCMProvider(key: key128)
        var envelope = try provider.encrypt(Data("START".utf8))

        let ciphertextIndex = 1 + AESGCMProvider.nonceLength
        envelope[ciphertextIndex] ^= 0x01

        XCTAssertThrowsError(try provider.decrypt(envelope)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testTamperedTagIsRejected() throws {
        let provider = try AESGCMProvider(key: key128)
        var envelope = try provider.encrypt(Data("START".utf8))

        envelope[envelope.index(before: envelope.endIndex)] ^= 0x01

        XCTAssertThrowsError(try provider.decrypt(envelope)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testTamperedNonceIsRejected() throws {
        let provider = try AESGCMProvider(key: key128)
        var envelope = try provider.encrypt(Data("START".utf8))

        envelope[1] ^= 0x01

        XCTAssertThrowsError(try provider.decrypt(envelope)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testTruncatedEnvelopeIsRejected() throws {
        let provider = try AESGCMProvider(key: key128)
        let envelope = try provider.encrypt(Data("START".utf8))

        let tooShort = Data(envelope.prefix(AESGCMProvider.nonceLength))
        XCTAssertThrowsError(try provider.decrypt(tooShort)) { error in
            XCTAssertEqual(error as? CryptoError, .malformedEnvelope)
        }
    }

    func testUnknownEnvelopeVersionIsRejected() throws {
        let provider = try AESGCMProvider(key: key128)
        var envelope = try provider.encrypt(Data("START".utf8))
        envelope[0] = 0x7F

        XCTAssertThrowsError(try provider.decrypt(envelope)) { error in
            XCTAssertEqual(error as? CryptoError, .unsupportedEnvelopeVersion(0x7F))
        }
    }

    func testInvalidKeyLengthIsRejected() {
        XCTAssertThrowsError(try AESGCMProvider(key: Data(repeating: 0, count: 15))) { error in
            XCTAssertEqual(error as? CryptoError, .invalidKeyLength(15))
        }
    }

    func testAlgorithmLabel() throws {
        let provider = try AESGCMProvider(key: key128)
        XCTAssertEqual(provider.algorithm, .aes128GCM)
        XCTAssertEqual(provider.algorithm.displayName, "AES-128-GCM")
    }
}

/// Returns a fixed nonce so envelope assertions can be exact.
struct FixedNonceGenerator: NonceGenerator {
    private let bytes: Data

    init(_ bytes: Data) {
        self.bytes = bytes
    }

    func makeNonce(count: Int) throws -> Data {
        guard bytes.count == count else {
            throw CryptoError.malformedEnvelope
        }
        return bytes
    }
}
