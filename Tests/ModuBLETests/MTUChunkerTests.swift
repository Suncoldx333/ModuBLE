import XCTest
@testable import ModuBLE

final class MTUChunkerTests: XCTestCase {
    func testEmptyPayloadProducesNoChunks() {
        XCTAssertTrue(MTUChunker.chunks(of: Data(), maxLength: 20).isEmpty)
    }

    func testSplitsOnExactBoundary() {
        let chunks = MTUChunker.chunks(of: Data(repeating: 0xAB, count: 100), maxLength: 20)
        XCTAssertEqual(chunks.count, 5)
        XCTAssertTrue(chunks.allSatisfy { $0.count == 20 })
    }

    func testKeepsRemainderInLastChunk() {
        let chunks = MTUChunker.chunks(of: Data(repeating: 0xAB, count: 105), maxLength: 20)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 20, 20, 20, 5])
    }

    func testPayloadSmallerThanMTU() {
        let chunks = MTUChunker.chunks(of: Data([0x01, 0x02, 0x03]), maxLength: 512)
        XCTAssertEqual(chunks, [Data([0x01, 0x02, 0x03])])
    }

    func testSingleByteMTU() {
        let chunks = MTUChunker.chunks(of: Data([0x01, 0x02, 0x03]), maxLength: 1)
        XCTAssertEqual(chunks, [Data([0x01]), Data([0x02]), Data([0x03])])
    }

    func testNonPositiveMaxLengthPassesDataThrough() {
        let data = Data([0x01, 0x02])
        XCTAssertEqual(MTUChunker.chunks(of: data, maxLength: 0), [data])
        XCTAssertEqual(MTUChunker.chunks(of: data, maxLength: -5), [data])
    }

    func testConcatenatingChunksRestoresOriginal() {
        let original = Data((0..<1000).map { UInt8($0 & 0xFF) })
        let chunks = MTUChunker.chunks(of: original, maxLength: 37)
        XCTAssertEqual(chunks.reduce(Data(), +), original)
    }

    /// Data slices keep the parent's indices; the chunker must normalise them.
    func testHandlesDataSliceInput() {
        let original = Data((0..<50).map { UInt8($0) })
        let slice = original.dropFirst(10)
        XCTAssertEqual(slice.startIndex, 10)

        let chunks = MTUChunker.chunks(of: slice, maxLength: 20)
        XCTAssertEqual(chunks.reduce(Data(), +), Data(slice))
        XCTAssertEqual(chunks.map(\.count), [20, 20])
    }
}
