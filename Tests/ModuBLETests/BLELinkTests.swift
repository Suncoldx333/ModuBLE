import XCTest
@testable import ModuBLE

/// In-memory `BLELink` used to prove the transport abstraction and to drive
/// future `Session` tests without hardware.
final class FakeBLELink: BLELink, @unchecked Sendable {
    let inbound: AsyncStream<Data>

    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var writtenPayloadsStorage: [Data] = []
    private var onWriteHandler: (@Sendable (Data) -> Void)?
    private var closed = false

    init() {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.inbound = stream
        self.inboundContinuation = continuation
    }

    var writtenPayloads: [Data] {
        lock.withLock { writtenPayloadsStorage }
    }

    /// Invoked synchronously after each write, so a responder can reply from the
    /// same call. Used to build virtual peripherals in tests.
    var onWrite: (@Sendable (Data) -> Void)? {
        get { lock.withLock { onWriteHandler } }
        set { lock.withLock { onWriteHandler = newValue } }
    }

    var isClosed: Bool {
        lock.withLock { closed }
    }

    func write(_ data: Data) async throws {
        let handler: (@Sendable (Data) -> Void)? = lock.withLock {
            writtenPayloadsStorage.append(data)
            return onWriteHandler
        }
        handler?(data)
    }

    func close() async {
        lock.withLock { closed = true }
        inboundContinuation.finish()
    }

    /// Simulates a notification arriving from the peripheral.
    func emit(_ data: Data) {
        inboundContinuation.yield(data)
    }
}

final class BLELinkTests: XCTestCase {
    func testWriteForwardsBytesVerbatim() async throws {
        let link = FakeBLELink()
        try await link.write(Data([0x01, 0x02, 0x03]))
        try await link.write(Data([0x04]))
        XCTAssertEqual(link.writtenPayloads, [Data([0x01, 0x02, 0x03]), Data([0x04])])
    }

    func testCloseFinishesInboundStream() async {
        let link = FakeBLELink()
        await link.close()

        var received = 0
        for await _ in link.inbound {
            received += 1
        }
        XCTAssertEqual(received, 0)
        XCTAssertTrue(link.isClosed)
    }

    /// Frame → link → notifications split at an arbitrary boundary → decoder.
    func testRequestResponseRoundTripAcrossFragmentedNotifications() async throws {
        let link = FakeBLELink()
        let codec = PacketCodec()

        let request = Packet(kind: .request, sequence: 1, payload: Data("START".utf8))
        try await link.write(try codec.encode(request))
        XCTAssertEqual(link.writtenPayloads.count, 1)
        XCTAssertEqual(link.writtenPayloads.first, try codec.encode(request))

        let response = try codec.encode(
            Packet(kind: .response, sequence: 1, payload: Data("START_ACK".utf8))
        )
        let split = response.count / 2
        link.emit(response.prefix(split))
        link.emit(response.suffix(from: split))

        var decoder = PacketDecoder()
        var decoded: [Packet] = []
        for await chunk in link.inbound {
            decoded.append(contentsOf: try decoder.append(chunk))
            if !decoded.isEmpty { break }
        }

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.kind, .response)
        XCTAssertEqual(decoded.first?.sequence, 1)
        XCTAssertEqual(decoded.first?.payload, Data("START_ACK".utf8))
    }

    /// Plain-text status notifications from the reference peripheral must not
    /// stop the decoder from finding real frames.
    func testDecoderIgnoresReferencePeripheralStatusText() throws {
        var decoder = PacketDecoder()
        XCTAssertTrue(try decoder.append(Data("READY".utf8)).isEmpty)
        XCTAssertTrue(try decoder.append(Data("RX #1: 5 bytes".utf8)).isEmpty)

        let codec = PacketCodec()
        let frame = try codec.encode(Packet(kind: .response, sequence: 3, payload: Data("OK".utf8)))
        let decoded = try decoder.append(frame)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.sequence, 3)
    }
}
