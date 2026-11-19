import XCTest
@testable import ModuBLE

final class DemoPeripheralBehaviorTests: XCTestCase {
    func testStartStartsTelemetry() {
        let (reply, command) = DemoPeripheralBehavior.handle(Data("START".utf8))
        XCTAssertEqual(reply, Data("START_ACK".utf8))
        XCTAssertEqual(command, .startTelemetry)
    }

    func testStopStopsTelemetry() {
        let (reply, command) = DemoPeripheralBehavior.handle(Data("STOP".utf8))
        XCTAssertEqual(reply, Data("STOP_ACK".utf8))
        XCTAssertEqual(command, .stopTelemetry)
    }

    func testPing() {
        let (reply, command) = DemoPeripheralBehavior.handle(Data("PING".utf8))
        XCTAssertEqual(reply, Data("PONG".utf8))
        XCTAssertEqual(command, .ping)
    }

    func testRateCommandIsAcceptedInsideTheRange() {
        let (reply, command) = DemoPeripheralBehavior.handle(Data("SET_RATE:2.5".utf8))
        XCTAssertEqual(reply, Data("RATE:2.5".utf8))
        XCTAssertEqual(command, .setTelemetryRate(2.5))
    }

    func testRateCommandRejectsOutOfRangeValues() {
        for text in ["SET_RATE:0", "SET_RATE:99", "SET_RATE:abc", "SET_RATE:"] {
            let (reply, command) = DemoPeripheralBehavior.handle(Data(text.utf8))
            XCTAssertEqual(reply, Data("RATE_ERROR".utf8), text)
            XCTAssertEqual(command, .echo, text)
        }
    }

    func testUnknownTextIsEchoed() {
        let (reply, command) = DemoPeripheralBehavior.handle(Data("HELLO".utf8))
        XCTAssertEqual(reply, Data("HELLO".utf8))
        XCTAssertEqual(command, .echo)
    }

    /// Binary payloads must survive the UTF-8 round trip attempt untouched.
    func testBinaryPayloadIsEchoedVerbatim() {
        let payload = Data([0x00, 0xFF, 0x80, 0x01])
        let (reply, command) = DemoPeripheralBehavior.handle(payload)
        XCTAssertEqual(reply, payload)
        XCTAssertEqual(command, .echo)
    }

    func testRateFormattingIsCompact() {
        XCTAssertEqual(DemoPeripheralBehavior.format(2), "2")
        XCTAssertEqual(DemoPeripheralBehavior.format(0.5), "0.5")
    }
}
