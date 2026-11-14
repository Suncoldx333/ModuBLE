import Foundation
import CommonCrypto

/// Raw AES-CBC block encryption without padding.
///
/// CryptoKit does not expose CBC, so the system CommonCrypto implementation is
/// used. Padding is handled by `PKCS7` so that the block primitive stays
/// byte-exact and can be checked against published test vectors.
enum CBCPrimitive {
    static let blockSize = Int(kCCBlockSizeAES128)

    static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(CCOperation(kCCEncrypt), input: plaintext, key: key, iv: iv)
    }

    static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(CCOperation(kCCDecrypt), input: ciphertext, key: key, iv: iv)
    }

    private static func crypt(
        _ operation: CCOperation,
        input: Data,
        key: Data,
        iv: Data
    ) throws -> Data {
        guard input.count % blockSize == 0 else {
            throw CryptoError.malformedEnvelope
        }
        guard iv.count == blockSize else {
            throw CryptoError.malformedEnvelope
        }

        var output = Data(count: input.count + blockSize)
        var moved = 0

        let status = output.withUnsafeMutableBytes { outputBuffer -> CCCryptorStatus in
            input.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            0,
                            keyBuffer.baseAddress,
                            key.count,
                            ivBuffer.baseAddress,
                            inputBuffer.baseAddress,
                            input.count,
                            outputBuffer.baseAddress,
                            outputBuffer.count,
                            &moved
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else {
            throw CryptoError.cipherFailure(status: status)
        }
        output.removeSubrange(moved..<output.count)
        return output
    }
}

/// PKCS#7 padding used by the CBC provider.
///
/// The padding is verified only *after* the HMAC check, so a malformed padding
/// can never be used as an oracle.
enum PKCS7 {
    static func pad(_ data: Data, blockSize: Int = CBCPrimitive.blockSize) -> Data {
        let remainder = data.count % blockSize
        let padLength = blockSize - remainder
        var padded = data
        padded.append(contentsOf: repeatElement(UInt8(padLength), count: padLength))
        return padded
    }

    static func unpad(_ data: Data, blockSize: Int = CBCPrimitive.blockSize) throws -> Data {
        guard !data.isEmpty, data.count % blockSize == 0 else {
            throw CryptoError.invalidPadding
        }
        let padLength = Int(data[data.index(before: data.endIndex)])
        guard padLength >= 1, padLength <= blockSize, padLength <= data.count else {
            throw CryptoError.invalidPadding
        }
        let boundary = data.index(data.endIndex, offsetBy: -padLength)
        guard data[boundary...].allSatisfy({ $0 == UInt8(padLength) }) else {
            throw CryptoError.invalidPadding
        }
        return Data(data[data.startIndex..<boundary])
    }
}
