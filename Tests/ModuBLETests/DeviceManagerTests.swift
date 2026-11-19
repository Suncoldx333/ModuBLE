import XCTest
@testable import ModuBLE

final class DeviceManagerTests: XCTestCase {
    func testScanAndBluetoothStateAreForwarded() async throws {
        let manager = makeManager()

        let states = await manager.observeBluetoothState()
        var stateIterator = states.makeAsyncIterator()
        let state = await stateIterator.next()
        XCTAssertEqual(state, .poweredOn)

        let stream = try await manager.scan()
        var iterator = stream.makeAsyncIterator()
        let devices = try await iterator.next() ?? []
        XCTAssertEqual(devices.count, 2)

        let kind = await manager.transportKind
        XCTAssertEqual(kind, .mock)
    }

    func testConnectReturnsAReadySession() async throws {
        let manager = makeManager()
        let device = try await firstDevice(manager)

        let session = try await manager.connect(device)

        XCTAssertEqual(session.device.id, device.id)
        XCTAssertEqual(session.state, .ready)
        let current = await manager.currentSession
        XCTAssertNotNil(current)
        XCTAssertTrue(current === session)
        await manager.disconnect()
    }

    func testSecondConnectionIsRejected() async throws {
        let manager = makeManager()
        let device = try await firstDevice(manager)
        _ = try await manager.connect(device)

        do {
            _ = try await manager.connect(device)
            XCTFail("expected rejection")
        } catch let error as BLEError {
            XCTAssertEqual(error, .connectionFailed("Another connection is already active"))
        }
        await manager.disconnect()
    }

    func testDisconnectClosesAndClearsTheSession() async throws {
        let manager = makeManager()
        let device = try await firstDevice(manager)
        let session = try await manager.connect(device)

        await manager.disconnect()

        XCTAssertTrue(session.isClosed)
        let current = await manager.currentSession
        XCTAssertNil(current)
    }

    /// After an unexpected link loss the manager must not keep a dead session,
    /// otherwise every later `connect` is rejected as "already active".
    func testLinkLossReleasesTheSession() async throws {
        let transport = MockDeviceTransport(
            configuration: MockConfiguration(
                autoTelemetry: false,
                faults: FaultConfiguration(disconnectAfterRequests: 1)
            )
        )
        let manager = makeManager(transport: transport)
        let device = try await firstDevice(manager)
        let session = try await manager.connect(device)

        _ = try? await session.request(Data("PING".utf8))

        let released = await poll { await manager.currentSession == nil }
        XCTAssertTrue(released)
        XCTAssertTrue(session.isClosed)
    }

    func testSwitchTransportDisconnectsFirst() async throws {
        let manager = makeManager()
        let device = try await firstDevice(manager)
        let session = try await manager.connect(device)

        await manager.switchTransport(CoreBluetoothTransport())

        XCTAssertTrue(session.isClosed)
        let kind = await manager.transportKind
        XCTAssertEqual(kind, .coreBluetooth)
    }

    /// A crypto failure must close the half-open link instead of leaking it.
    func testCryptoFailureClosesTheLink() async throws {
        let transport = MockDeviceTransport(
            configuration: MockConfiguration(autoTelemetry: false)
        )
        let manager = DeviceManager(
            transport: transport,
            crypto: { throw CryptoError.invalidKeyLength(3) }
        )
        let device = try await firstDevice(manager)

        do {
            _ = try await manager.connect(device)
            XCTFail("expected crypto failure")
        } catch let error as CryptoError {
            XCTAssertEqual(error, .invalidKeyLength(3))
        }

        XCTAssertEqual(transport.activeLink?.isClosed, true)
        let current = await manager.currentSession
        XCTAssertNil(current)
    }

    // MARK: - Helpers

    private func makeManager(
        transport: MockDeviceTransport? = nil,
        crypto: @escaping @Sendable () throws -> any CryptoProvider = {
            try AESGCMProvider(key: DemoTestKey.aes128GCM)
        }
    ) -> DeviceManager {
        DeviceManager(
            transport: transport
                ?? MockDeviceTransport(configuration: MockConfiguration(autoTelemetry: false)),
            crypto: crypto
        )
    }

    private func firstDevice(_ manager: DeviceManager) async throws -> DiscoveredDevice {
        let stream = try await manager.scan()
        var iterator = stream.makeAsyncIterator()
        let devices = try await iterator.next() ?? []
        return try XCTUnwrap(devices.first)
    }

    private func poll(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }
}
