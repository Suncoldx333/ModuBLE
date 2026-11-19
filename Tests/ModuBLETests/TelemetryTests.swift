import XCTest
@testable import ModuBLE

final class TelemetryTests: XCTestCase {
    func testRoundTripKeepsEveryField() throws {
        let original = Telemetry(
            yaw: 12.34,
            pitch: -56.78,
            roll: 179.99,
            battery: 42,
            isCharging: true,
            uptimeMilliseconds: 123_456
        )
        let data = try TelemetryCodec.encode(original)
        XCTAssertEqual(data.count, TelemetryCodec.payloadLength)
        XCTAssertEqual(try TelemetryCodec.decode(data), original)
    }

    func testHeaderAndCentidegreeLayout() throws {
        let data = try TelemetryCodec.encode(
            Telemetry(yaw: 1.0, pitch: 0, roll: 0, battery: 7, uptimeMilliseconds: 0)
        )
        XCTAssertEqual(Array(data.prefix(2)), [TelemetryCodec.version, TelemetryCodec.kind])
        // 1.00° → 100 centidegrees → 0x0064, big-endian.
        XCTAssertEqual(Array(data[2..<4]), [0x00, 0x64])
        XCTAssertEqual(data[8], 7)
        XCTAssertEqual(data[9], 0)
    }

    func testNegativeAnglesKeepTheirSign() throws {
        let original = Telemetry(yaw: -12.34, pitch: -0.01, roll: -179.99)
        let decoded = try TelemetryCodec.decode(TelemetryCodec.encode(original))
        XCTAssertEqual(decoded.yaw, -12.34)
        XCTAssertEqual(decoded.pitch, -0.01)
        XCTAssertEqual(decoded.roll, -179.99)
    }

    func testAnglesUseTheWholeInt16Range() throws {
        XCTAssertNoThrow(try TelemetryCodec.encode(Telemetry(yaw: 327.67)))
        XCTAssertNoThrow(try TelemetryCodec.encode(Telemetry(yaw: -327.68)))
        XCTAssertThrowsError(try TelemetryCodec.encode(Telemetry(yaw: 327.68))) { error in
            XCTAssertEqual(error as? TelemetryError, .angleOutOfRange(327.68))
        }
        XCTAssertThrowsError(try TelemetryCodec.encode(Telemetry(pitch: .nan))) { error in
            guard let telemetryError = error as? TelemetryError,
                  case .angleOutOfRange = telemetryError else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testBatteryRange() throws {
        XCTAssertNoThrow(try TelemetryCodec.encode(Telemetry(battery: 0)))
        XCTAssertNoThrow(try TelemetryCodec.encode(Telemetry(battery: 100)))
        XCTAssertThrowsError(try TelemetryCodec.encode(Telemetry(battery: 101))) { error in
            XCTAssertEqual(error as? TelemetryError, .batteryOutOfRange(101))
        }
        XCTAssertThrowsError(try TelemetryCodec.encode(Telemetry(battery: -1))) { error in
            XCTAssertEqual(error as? TelemetryError, .batteryOutOfRange(-1))
        }
    }

    func testUptimeRange() throws {
        XCTAssertNoThrow(try TelemetryCodec.encode(Telemetry(uptimeMilliseconds: Int(UInt32.max))))
        XCTAssertThrowsError(try TelemetryCodec.encode(Telemetry(uptimeMilliseconds: Int(UInt32.max) + 1)))
        XCTAssertThrowsError(try TelemetryCodec.encode(Telemetry(uptimeMilliseconds: -1)))
    }

    func testTruncatedPayloadIsRejected() {
        XCTAssertThrowsError(
            try TelemetryCodec.decode(Data(repeating: 0, count: TelemetryCodec.payloadLength - 1))
        ) { error in
            XCTAssertEqual(
                error as? TelemetryError,
                .truncated(expected: TelemetryCodec.payloadLength, actual: TelemetryCodec.payloadLength - 1)
            )
        }
    }

    func testWrongVersionAndKindAreRejected() throws {
        var data = try TelemetryCodec.encode(Telemetry())
        data[0] = 0x09
        XCTAssertThrowsError(try TelemetryCodec.decode(data)) { error in
            XCTAssertEqual(error as? TelemetryError, .unsupportedVersion(0x09))
        }

        data = try TelemetryCodec.encode(Telemetry())
        data[1] = 0x7F
        XCTAssertThrowsError(try TelemetryCodec.decode(data)) { error in
            XCTAssertEqual(error as? TelemetryError, .unknownKind(0x7F))
        }
    }

    /// A future version may append fields; older readers must not choke on them.
    func testTrailingBytesAreIgnored() throws {
        var data = try TelemetryCodec.encode(Telemetry(battery: 55))
        data.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertEqual(try TelemetryCodec.decode(data).battery, 55)
    }

    // MARK: - Generator

    func testGeneratorIsDeterministic() {
        var a = TelemetryGenerator()
        var b = TelemetryGenerator()

        let first = a.next(advancingBy: .milliseconds(500))
        let second = b.next(advancingBy: .milliseconds(500))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.uptimeMilliseconds, 500)
        XCTAssertLessThanOrEqual(abs(first.yaw), 45)
        XCTAssertLessThanOrEqual(abs(first.pitch), 20)
        XCTAssertLessThanOrEqual(abs(first.roll), 25)
    }

    func testGeneratorValuesSurviveTheWireFormat() throws {
        var generator = TelemetryGenerator()
        for _ in 0..<50 {
            let sample = generator.next(advancingBy: .milliseconds(250))
            let decoded = try TelemetryCodec.decode(TelemetryCodec.encode(sample))
            XCTAssertEqual(decoded, sample)
        }
    }
}
