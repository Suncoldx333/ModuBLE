import XCTest
@testable import ModuBLE

final class PacketCodecTests: XCTestCase {
    private let codec = PacketCodec()

    func testEncodeProducesDocumentedHeader() throws {
        let frame = try codec.encode(Packet(kind: .request, sequence: 0x01020304, payload: Data([0xAA, 0xBB])))

        XCTAssertEqual(Array(frame.prefix(10)), [
            0x4D, 0x42, // magic "MB"
            0x01,       // version
            0x01,       // kind: request
            0x01, 0x02, 0x03, 0x04, // sequence, big-endian
            0x00, 0x02  // payload length, big-endian
        ])
        XCTAssertEqual(Array(frame.suffix(2)), [0xAA, 0xBB])
        XCTAssertEqual(frame.count, Packet.headerLength + 2)
    }

    func testRoundTrip() throws {
        let original = Packet(kind: .response, sequence: 42, payload: Data("START_ACK".utf8))
        let decoded = try codec.decode(try codec.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testEmptyPayloadRoundTrip() throws {
        let original = Packet(kind: .event, sequence: 0, payload: Data())
        let decoded = try codec.decode(try codec.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testDecodeRejectsBadMagic() {
        let frame = try! codec.encode(Packet(kind: .raw, sequence: 1, payload: Data([0x01])))
        var corrupted = frame
        corrupted[0] = 0x00
        XCTAssertThrowsError(try codec.decode(corrupted)) { error in
            XCTAssertEqual(error as? PacketError, .invalidMagic)
        }
    }

    func testDecodeRejectsUnknownVersion() {
        let frame = try! codec.encode(Packet(kind: .raw, sequence: 1, payload: Data([0x01])))
        var corrupted = frame
        corrupted[2] = 0x09
        XCTAssertThrowsError(try codec.decode(corrupted)) { error in
            XCTAssertEqual(error as? PacketError, .unsupportedVersion(0x09))
        }
    }

    func testDecodeRejectsUnknownKind() {
        let frame = try! codec.encode(Packet(kind: .raw, sequence: 1, payload: Data([0x01])))
        var corrupted = frame
        corrupted[3] = 0x55
        XCTAssertThrowsError(try codec.decode(corrupted)) { error in
            XCTAssertEqual(error as? PacketError, .unknownKind(0x55))
        }
    }

    func testDecodeRejectsTruncatedInput() {
        let frame = try! codec.encode(Packet(kind: .raw, sequence: 1, payload: Data([0x01, 0x02])))
        let truncated = frame.prefix(frame.count - 1)
        XCTAssertThrowsError(try codec.decode(Data(truncated)))
    }

    func testEncodeRejectsOversizedPayload() {
        let payload = Data(repeating: 0x00, count: PacketCodec.maxPayloadLength + 1)
        XCTAssertThrowsError(try codec.encode(Packet(kind: .raw, sequence: 1, payload: payload))) { error in
            XCTAssertEqual(error as? PacketError, .payloadTooLarge(PacketCodec.maxPayloadLength + 1))
        }
    }

    // MARK: - Streaming decoder

    func testDecoderReassemblesByteByByte() throws {
        let first = try codec.encode(Packet(kind: .request, sequence: 1, payload: Data("START".utf8)))
        let second = try codec.encode(Packet(kind: .event, sequence: 2, payload: Data()))
        let stream = first + second

        var decoder = PacketDecoder()
        var received: [Packet] = []
        for byte in stream {
            received.append(contentsOf: try decoder.append(Data([byte])))
        }

        XCTAssertEqual(received.map(\.sequence), [1, 2])
        XCTAssertEqual(received.first?.payload, Data("START".utf8))
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testDecoderHandlesMultipleFramesInOneChunk() throws {
        let frames = try (1...3).map {
            try codec.encode(Packet(kind: .raw, sequence: UInt32($0), payload: Data([UInt8($0)])))
        }
        var decoder = PacketDecoder()
        let received = try decoder.append(frames.reduce(Data(), +))
        XCTAssertEqual(received.map(\.sequence), [1, 2, 3])
    }

    func testDecoderResynchronisesAfterGarbage() throws {
        let valid = try codec.encode(Packet(kind: .request, sequence: 7, payload: Data("X".utf8)))
        var noisy = Data([0x00, 0xFF, 0x12, 0x4D]) // ends with half a magic prefix
        noisy.append(valid)

        var decoder = PacketDecoder()
        let received = try decoder.append(noisy)
        XCTAssertEqual(received.map(\.sequence), [7])
    }

    func testDecoderKeepsIncompleteFrameBuffered() throws {
        let frame = try codec.encode(Packet(kind: .response, sequence: 9, payload: Data(repeating: 0x5A, count: 40)))
        var decoder = PacketDecoder()

        let partial = try decoder.append(frame.prefix(20))
        XCTAssertTrue(partial.isEmpty)
        XCTAssertEqual(decoder.bufferedByteCount, 20)

        let rest = try decoder.append(frame.dropFirst(20))
        XCTAssertEqual(rest.map(\.sequence), [9])
    }

    func testDecoderThrowsOnUnsupportedVersionAndClearsBuffer() throws {
        let frame = try codec.encode(Packet(kind: .raw, sequence: 1, payload: Data([0x01])))
        var corrupted = frame
        corrupted[2] = 0x42

        var decoder = PacketDecoder()
        XCTAssertThrowsError(try decoder.append(corrupted)) { error in
            XCTAssertEqual(error as? PacketError, .unsupportedVersion(0x42))
        }
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }
}
