import XCTest
@testable import ModuBLE

/// `PacketCodec.maxPayloadLength` bounds the *sealed envelope*, not the
/// plaintext. These tests pin the derived per-algorithm limit so it cannot drift
/// away from the documented envelope layouts.
final class EncryptedSessionLimitsTests: XCTestCase {
    private let gcmKey = Data((0..<16).map(UInt8.init))
    private let cbcKey = Data((0..<32).map(UInt8.init))

    func testGCMPlaintextLimit() throws {
        let provider = try AESGCMProvider(key: gcmKey)
        XCTAssertEqual(
            provider.maxPlaintextLength,
            PacketCodec.maxPayloadLength - (1 + 12 + 16)
        )
        XCTAssertEqual(provider.maxPlaintextLength, 4067)
    }

    func testCBCPlaintextLimit() throws {
        let provider = try AESCBCProvider(key: cbcKey)
        XCTAssertEqual(provider.maxPlaintextLength, 4031)

        // The documented invariant: sealed envelope never exceeds 4096.
        let plaintext = Data(repeating: 0x11, count: provider.maxPlaintextLength)
        XCTAssertLessThanOrEqual(try provider.encrypt(plaintext).count, PacketCodec.maxPayloadLength)

        let tooLong = Data(repeating: 0x11, count: provider.maxPlaintextLength + 1)
        XCTAssertGreaterThan(try provider.encrypt(tooLong).count, PacketCodec.maxPayloadLength)
    }

    func testRequestAtTheLimitUsesTheWholePayload() async throws {
        let link = FakeBLELink()
        let crypto = try AESGCMProvider(key: gcmKey)
        let session = EncryptedSession(link: link, crypto: crypto, timeout: .milliseconds(500))

        // Reply with a short payload: echoing the request would itself exceed
        // the response limit.
        link.onWrite = { frame in
            guard let packet = try? PacketCodec().decode(frame),
                  let sealed = try? crypto.encrypt(Data("OK".utf8)),
                  let response = try? PacketCodec().encode(
                      Packet(kind: .response, sequence: packet.sequence, payload: sealed)
                  ) else { return }
            link.emit(response)
        }

        let payload = Data(repeating: 0xAB, count: session.maxPlaintextLength)
        let reply = try await session.request(payload)
        XCTAssertEqual(reply, Data("OK".utf8))

        let frame = try XCTUnwrap(link.writtenPayloads.first)
        XCTAssertEqual(frame.count, Packet.headerLength + PacketCodec.maxPayloadLength)
    }

    func testRequestAboveTheLimitIsRejectedBeforeWriting() async throws {
        let link = FakeBLELink()
        let crypto = try AESGCMProvider(key: gcmKey)
        let session = EncryptedSession(link: link, crypto: crypto, timeout: .milliseconds(500))
        let max = session.maxPlaintextLength

        do {
            _ = try await session.request(Data(repeating: 0x01, count: max + 1))
            XCTFail("expected payloadTooLarge")
        } catch let error as SessionError {
            XCTAssertEqual(error, .payloadTooLarge(max: max))
        }

        XCTAssertTrue(link.writtenPayloads.isEmpty)
    }

    /// The limit follows the provider, so switching algorithms mid-session moves
    /// the boundary too.
    func testLimitFollowsAlgorithmSwitch() async throws {
        let link = FakeBLELink()
        let session = EncryptedSession(
            link: link,
            crypto: try AESGCMProvider(key: gcmKey),
            timeout: .milliseconds(500)
        )
        XCTAssertEqual(session.maxPlaintextLength, 4067)

        session.updateCrypto(try AESCBCProvider(key: cbcKey))
        XCTAssertEqual(session.maxPlaintextLength, 4031)
    }
}
