import XCTest
@testable import ModuBLE

final class AESCBCProviderTests: XCTestCase {
    private let masterKey = Data((0..<32).map(UInt8.init))
    private let masterKeyOther = Data((200..<232).map(UInt8.init))

    // MARK: - Round trip

    func testRoundTripForBlockAlignedAndUnalignedPayloads() throws {
        let provider = try AESCBCProvider(key: masterKey)
        let payloads = [
            Data(),
            Data("S".utf8),
            Data("START".utf8),
            Data(repeating: 0x41, count: 16),
            Data(repeating: 0x42, count: 31),
            Data(repeating: 0x43, count: 256)
        ]

        for plaintext in payloads {
            let envelope = try provider.encrypt(plaintext)
            XCTAssertEqual(try provider.decrypt(envelope), plaintext, "payload of \(plaintext.count) bytes")
        }
    }

    func testEnvelopeLayout() throws {
        let iv = Data(repeating: 0x11, count: AESCBCProvider.ivLength)
        let provider = try AESCBCProvider(key: masterKey, ivGenerator: FixedNonceGenerator(iv))
        let plaintext = Data("START".utf8)

        let envelope = try provider.encrypt(plaintext)

        XCTAssertEqual(envelope[envelope.startIndex], AESCBCProvider.envelopeVersion)
        XCTAssertEqual(Data(envelope.dropFirst().prefix(AESCBCProvider.ivLength)), iv)
        // PKCS#7 always adds 1...16 bytes, so ciphertext is the next block boundary.
        let expectedCiphertextLength = (plaintext.count / 16 + 1) * 16
        XCTAssertEqual(
            envelope.count,
            1 + AESCBCProvider.ivLength + expectedCiphertextLength + AESCBCProvider.tagLength
        )
    }

    func testIvIsFreshForEveryEncryption() throws {
        let provider = try AESCBCProvider(key: masterKey)
        let first = try provider.encrypt(Data("same".utf8))
        let second = try provider.encrypt(Data("same".utf8))

        XCTAssertNotEqual(
            Data(first.dropFirst().prefix(AESCBCProvider.ivLength)),
            Data(second.dropFirst().prefix(AESCBCProvider.ivLength))
        )
    }

    // MARK: - Encrypt-then-MAC

    func testTamperedCiphertextFailsBeforeDecryption() throws {
        let provider = try AESCBCProvider(key: masterKey)
        var envelope = try provider.encrypt(Data("START".utf8))
        let ciphertextStart = 1 + AESCBCProvider.ivLength
        envelope[ciphertextStart] ^= 0x01

        XCTAssertThrowsError(try provider.decrypt(envelope)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testTamperedIvFailsBeforeDecryption() throws {
        let provider = try AESCBCProvider(key: masterKey)
        var envelope = try provider.encrypt(Data("START".utf8))
        envelope[1] ^= 0x01

        XCTAssertThrowsError(try provider.decrypt(envelope)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testTamperedMacIsRejected() throws {
        let provider = try AESCBCProvider(key: masterKey)
        var envelope = try provider.encrypt(Data("START".utf8))
        envelope[envelope.index(before: envelope.endIndex)] ^= 0x01

        XCTAssertThrowsError(try provider.decrypt(envelope)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testTamperedVersionIsRejected() throws {
        let provider = try AESCBCProvider(key: masterKey)
        var envelope = try provider.encrypt(Data("START".utf8))
        envelope[0] = 0x03

        // Version is validated first, before the MAC check.
        XCTAssertThrowsError(try provider.decrypt(envelope)) { error in
            XCTAssertEqual(error as? CryptoError, .unsupportedEnvelopeVersion(0x03))
        }
    }

    /// A GCM envelope must not silently decrypt as CBC, or vice versa.
    func testGCMEnvelopeIsRejectedByCBCProvider() throws {
        let gcm = try AESGCMProvider(key: DemoTestKey.aes128GCM)
        let cbc = try AESCBCProvider(key: DemoTestKey.aes128CBCHMAC)
        let envelope = try gcm.encrypt(Data("START".utf8))

        XCTAssertThrowsError(try cbc.decrypt(envelope)) { error in
            XCTAssertEqual(error as? CryptoError, .unsupportedEnvelopeVersion(AESGCMProvider.envelopeVersion))
        }
    }

    func testWrongKeyIsRejected() throws {
        let sender = try AESCBCProvider(key: masterKey)
        let receiver = try AESCBCProvider(key: masterKeyOther)
        let envelope = try sender.encrypt(Data("START".utf8))

        XCTAssertThrowsError(try receiver.decrypt(envelope)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testTruncatedEnvelopeIsRejected() throws {
        let provider = try AESCBCProvider(key: masterKey)
        let envelope = try provider.encrypt(Data(repeating: 0x41, count: 64))
        let truncated = Data(envelope.prefix(envelope.count - 1))

        XCTAssertThrowsError(try provider.decrypt(truncated)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    func testInvalidKeyLengthIsRejected() {
        XCTAssertThrowsError(try AESCBCProvider(key: Data(repeating: 0, count: 16))) { error in
            XCTAssertEqual(error as? CryptoError, .invalidKeyLength(16))
        }
    }

    func testAlgorithmLabel() throws {
        let provider = try AESCBCProvider(key: masterKey)
        XCTAssertEqual(provider.algorithm, .aes128CBCHMAC)
        XCTAssertEqual(provider.algorithm.displayName, "AES-128-CBC + HMAC-SHA256")
    }

    // MARK: - Primitives against published vectors

    /// NIST SP 800-38A, F.2.1 CBC-AES128.Encrypt, four blocks.
    func testCBCPrimitiveMatchesNISTVector() throws {
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")
        let iv = Data(hex: "000102030405060708090a0b0c0d0e0f")
        let plaintext = Data(hex: """
        6bc1bee22e409f96e93d7e117393172a
        ae2d8a571e03ac9c9eb76fac45af8e51
        30c81c46a35ce411e5fbc1191a0a52ef
        f69f2445df4f9b17ad2b417be66c3710
        """)
        let expected = Data(hex: """
        7649abac8119b246cee98e9b12e9197d
        5086cb9b507219ee95db113a917678b2
        73bed6b8e3c1743b7116e69e22229516
        3ff1caa1681fac09120eca307586e1a7
        """)

        let ciphertext = try CBCPrimitive.encrypt(plaintext, key: key, iv: iv)
        XCTAssertEqual(ciphertext, expected)
        XCTAssertEqual(try CBCPrimitive.decrypt(ciphertext, key: key, iv: iv), plaintext)
    }

    func testCBCPrimitiveRejectsNonBlockAlignedInput() {
        let key = Data(repeating: 0, count: 16)
        let iv = Data(repeating: 0, count: 16)
        XCTAssertThrowsError(try CBCPrimitive.encrypt(Data([0x01]), key: key, iv: iv)) { error in
            XCTAssertEqual(error as? CryptoError, .malformedEnvelope)
        }
    }

    // MARK: - Padding

    func testPKCS7PadsToNextBlock() throws {
        XCTAssertEqual(PKCS7.pad(Data()).count, 16)
        XCTAssertEqual(PKCS7.pad(Data(repeating: 0, count: 15)).count, 16)
        XCTAssertEqual(PKCS7.pad(Data(repeating: 0, count: 16)).count, 32)

        let padded = PKCS7.pad(Data(repeating: 0x41, count: 5))
        XCTAssertEqual(Array(padded.suffix(11)), Array(repeating: UInt8(11), count: 11))
        XCTAssertEqual(try PKCS7.unpad(padded), Data(repeating: 0x41, count: 5))
    }

    func testPKCS7RejectsInvalidPadding() {
        XCTAssertThrowsError(try PKCS7.unpad(Data()))
        XCTAssertThrowsError(try PKCS7.unpad(Data(repeating: 0x00, count: 16)))
        XCTAssertThrowsError(try PKCS7.unpad(Data(repeating: 0x11, count: 16)))
        XCTAssertThrowsError(try PKCS7.unpad(Data([0x41, 0x02, 0x03])))
    }
}

// MARK: - HEX helper

extension Data {
    init(hex: String) {
        let cleaned = hex
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .filter { !$0.isWhitespace }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else {
                self = Data()
                return
            }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
