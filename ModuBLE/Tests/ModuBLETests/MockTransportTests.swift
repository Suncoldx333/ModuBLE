import XCTest
@testable import ModuBLE

/// End-to-end tests over the mock transport. They exercise the real codec,
/// crypto and session layers; only the radio is virtual.
final class MockTransportTests: XCTestCase {
    func testBluetoothStateIsPoweredOn() async {
        let transport = makeTransport()
        var iterator = transport.observeBluetoothState().makeAsyncIterator()
        let state = await iterator.next()
        XCTAssertEqual(state, .poweredOn)
    }

    func testScanYieldsTheCatalogueOnce() async throws {
        let transport = makeTransport()
        let stream = try await transport.scan(profile: .referencePeripheral)
        var iterator = stream.makeAsyncIterator()

        let devices = try await iterator.next()
        XCTAssertEqual(devices?.count, 2)
        XCTAssertEqual(devices?.first?.name, "Mock Motion Sensor")
        XCTAssertEqual(devices?.first?.isConnectable, true)

        await transport.stopScan()
        let afterStop = try await iterator.next()
        XCTAssertNil(afterStop)
    }

    func testEncryptedRoundTripThroughTheMock() async throws {
        let (_, _, session) = try await connected()
        let reply = try await session.request(Data("START".utf8))
        XCTAssertEqual(reply, Data("START_ACK".utf8))
        await session.close()
    }

    /// 100 bytes at a 20-byte MTU forces fragmentation in both directions, so
    /// this also proves that reassembly works over the mock link.
    func testLargePayloadIsChunkedAndReassembled() async throws {
        let (_, _, session) = try await connected(maximumWritePayload: 20)
        let payload = Data((0..<100).map { UInt8($0 & 0xFF) })

        let reply = try await session.request(payload)
        XCTAssertEqual(reply, payload)
        await session.close()
    }

    func testStartEnablesTelemetryEvents() async throws {
        let (_, link, session) = try await connected()
        let sink = EventSink()
        sink.start(session.events)

        _ = try await session.request(Data("START".utf8))
        XCTAssertTrue(link.peripheral.isEmittingTelemetry)
        XCTAssertTrue(link.emitTelemetryNow(advancingBy: .seconds(1)))

        let arrived = await sink.waitFor(1, timeout: .seconds(1))
        XCTAssertTrue(arrived)
        let event = try XCTUnwrap(sink.values.first)
        let telemetry = try TelemetryCodec.decode(event.payload)
        XCTAssertEqual(telemetry.uptimeMilliseconds, 1000)
        XCTAssertEqual(event.sequence, 1)
        await session.close()
    }

    func testStopDisablesTelemetry() async throws {
        let (_, link, session) = try await connected()

        _ = try await session.request(Data("START".utf8))
        _ = try await session.request(Data("STOP".utf8))

        XCTAssertFalse(link.peripheral.isEmittingTelemetry)
        XCTAssertFalse(link.emitTelemetryNow())
        await session.close()
    }

    func testRateCommandReachesThePeripheral() async throws {
        let (_, link, session) = try await connected()
        let reply = try await session.request(Data("SET_RATE:5".utf8))

        XCTAssertEqual(reply, Data("RATE:5".utf8))
        XCTAssertEqual(link.peripheral.telemetryRate, 5)
        await session.close()
    }

    // MARK: - Faults

    func testDroppedResponseTimesOut() async throws {
        let (_, _, session) = try await connected(faults: FaultConfiguration(dropRate: 1))
        do {
            _ = try await session.request(Data("PING".utf8))
            XCTFail("expected timeout")
        } catch let error as SessionError {
            XCTAssertEqual(error, .timedOut)
        }
        await session.close()
    }

    func testCorruptedResponseFailsAuthentication() async throws {
        let (_, _, session) = try await connected(faults: FaultConfiguration(corruptRate: 1))
        do {
            _ = try await session.request(Data("PING".utf8))
            XCTFail("expected authentication failure")
        } catch let error as SessionError {
            XCTAssertEqual(error, .crypto(.authenticationFailed))
        }
        await session.close()
    }

    func testDisconnectAfterRequestClosesTheSession() async throws {
        let (_, link, session) = try await connected(
            faults: FaultConfiguration(disconnectAfterRequests: 1)
        )
        do {
            _ = try await session.request(Data("PING".utf8))
            XCTFail("expected closed session")
        } catch let error as SessionError {
            XCTAssertEqual(error, .closed)
        }

        guard case .failed = link.state else {
            return XCTFail("expected failed state, got \(link.state)")
        }
        XCTAssertTrue(link.isClosed)

        do {
            _ = try await session.request(Data("PING".utf8))
            XCTFail("expected closed session")
        } catch let error as SessionError {
            XCTAssertEqual(error, .closed)
        }
        await session.close()
    }

    func testFaultConfigurationCanBeChangedOnALiveLink() async throws {
        let (transport, _, session) = try await connected()
        transport.applyFaultConfiguration(FaultConfiguration(dropRate: 1))

        do {
            _ = try await session.request(Data("PING".utf8))
            XCTFail("expected timeout")
        } catch let error as SessionError {
            XCTAssertEqual(error, .timedOut)
        }
        await session.close()
    }

    func testSecondConnectionIsRejectedWhileTheFirstIsOpen() async throws {
        let (transport, link, session) = try await connected()
        do {
            _ = try await transport.connect(link.device, profile: .referencePeripheral)
            XCTFail("expected rejection")
        } catch let error as BLEError {
            XCTAssertEqual(
                error,
                .connectionFailed("Another connection is already active")
            )
        }
        await session.close()
    }

    // MARK: - Helpers

    private func makeTransport(
        maximumWritePayload: Int = 182,
        faults: FaultConfiguration = FaultConfiguration()
    ) -> MockDeviceTransport {
        MockDeviceTransport(
            configuration: MockConfiguration(
                maximumWritePayloadLength: maximumWritePayload,
                autoTelemetry: false,
                faults: faults
            )
        )
    }

    private func connected(
        maximumWritePayload: Int = 182,
        faults: FaultConfiguration = FaultConfiguration()
    ) async throws -> (MockDeviceTransport, MockBLELink, EncryptedSession) {
        let transport = makeTransport(maximumWritePayload: maximumWritePayload, faults: faults)
        let stream = try await transport.scan(profile: .referencePeripheral)
        var iterator = stream.makeAsyncIterator()
        let devices = try await iterator.next() ?? []
        let device = try XCTUnwrap(devices.first)

        let anyLink = try await transport.connect(device, profile: .referencePeripheral)
        let link = try XCTUnwrap(anyLink as? MockBLELink)
        let session = EncryptedSession(
            link: link,
            crypto: try AESGCMProvider(key: DemoTestKey.aes128GCM),
            timeout: .milliseconds(400)
        )
        return (transport, link, session)
    }
}
