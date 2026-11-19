import XCTest
@testable import ModuBLE

final class FaultInjectorTests: XCTestCase {
    func testSameSeedProducesTheSameSequence() {
        let first = FaultInjector(configuration: FaultConfiguration(dropRate: 0.5), seed: 42)
        let second = FaultInjector(configuration: FaultConfiguration(dropRate: 0.5), seed: 42)

        let a = (0..<32).map { _ in first.shouldDrop() }
        let b = (0..<32).map { _ in second.shouldDrop() }

        XCTAssertEqual(a, b)
        XCTAssertTrue(a.contains(true))
        XCTAssertTrue(a.contains(false))
    }

    func testDifferentSeedsDiverge() {
        let first = FaultInjector(configuration: FaultConfiguration(dropRate: 0.5), seed: 1)
        let second = FaultInjector(configuration: FaultConfiguration(dropRate: 0.5), seed: 2)

        let a = (0..<32).map { _ in first.shouldDrop() }
        let b = (0..<32).map { _ in second.shouldDrop() }

        XCTAssertNotEqual(a, b)
    }

    func testRatesAreClampedToUnitInterval() {
        XCTAssertEqual(FaultConfiguration(dropRate: 2).dropRate, 1)
        XCTAssertEqual(FaultConfiguration(dropRate: -1).dropRate, 0)
        XCTAssertEqual(FaultConfiguration(corruptRate: .infinity).corruptRate, 1)
    }

    func testDisabledFaultsNeverFireAndConsumeNoEntropy() {
        let injector = FaultInjector(configuration: FaultConfiguration())
        XCTAssertFalse((0..<64).allSatisfy { _ in injector.shouldDrop() })
        XCTAssertFalse((0..<64).allSatisfy { _ in injector.shouldCorrupt() })
        XCTAssertFalse((0..<64).allSatisfy { _ in injector.shouldMalform() })
        XCTAssertTrue(injector.configuration.isClean)
    }

    func testCertainFaultsAlwaysFire() {
        XCTAssertTrue((0..<8).allSatisfy { _ in
            FaultInjector(configuration: FaultConfiguration(dropRate: 1)).shouldDrop()
        })
        XCTAssertTrue((0..<8).allSatisfy { _ in
            FaultInjector(configuration: FaultConfiguration(corruptRate: 1)).shouldCorrupt()
        })
    }

    /// Corruption must preserve the frame header and break only the sealed
    /// payload, so the receiver fails at authentication rather than framing.
    func testCorruptionBreaksAuthentication() throws {
        let key = Data(repeating: 0x11, count: 16)
        let crypto = try AESGCMProvider(key: key)
        let frame = try PacketCodec().encode(
            Packet(kind: .response, sequence: 1, payload: try crypto.encrypt(Data("OK".utf8)))
        )

        let damaged = FaultInjector().corrupt(frame)

        var decoder = PacketDecoder()
        let packets = try decoder.append(damaged)
        XCTAssertEqual(packets.count, 1)
        XCTAssertThrowsError(try crypto.decrypt(packets[0].payload)) { error in
            XCTAssertEqual(error as? CryptoError, .authenticationFailed)
        }
    }

    /// A damaged length field must make the decoder drop the frame instead of
    /// producing a bogus packet.
    func testMalformedFrameIsNotDecoded() throws {
        let frame = try PacketCodec().encode(
            Packet(kind: .response, sequence: 1, payload: Data([0x01, 0x02, 0x03]))
        )
        let damaged = FaultInjector().malform(frame)

        var decoder = PacketDecoder()
        XCTAssertTrue(try decoder.append(damaged).isEmpty)
    }

    func testCountersTrackEveryInjection() {
        let injector = FaultInjector()
        injector.recordDrop()
        injector.recordDrop()
        injector.recordCorruption()
        injector.recordMalformed()
        injector.recordDisconnect()

        XCTAssertEqual(
            injector.counters,
            FaultInjector.Counters(dropped: 2, corrupted: 1, malformed: 1, disconnects: 1)
        )

        injector.resetCounters()
        XCTAssertEqual(injector.counters, FaultInjector.Counters())
    }
}
