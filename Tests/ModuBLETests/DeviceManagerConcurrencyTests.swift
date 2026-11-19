import XCTest
@testable import ModuBLE

/// Regression tests for the actor-reentrancy window inside `connect()`.
///
/// `transport.connect` suspends, so a second `connect()`, a `disconnect()`, a
/// transport switch or a cancelled task can all run before the link returns.
/// The manager must never mount a link from an attempt that is no longer
/// current, and must close it instead.
final class DeviceManagerConcurrencyTests: XCTestCase {
    // MARK: - Concurrent connect

    func testConcurrentConnectIsRejectedWhileConnecting() async throws {
        let (manager, transport) = makeManager()
        let device = DiscoveredDevice(id: UUID(), name: "Gated")
        defer { transport.failAll() }

        let first = Task { try await manager.connect(device) }
        let started = await poll { transport.connectCount == 1 }
        XCTAssertTrue(started)

        let phase = await manager.phase
        let connecting = await manager.isConnecting
        XCTAssertEqual(phase, .connecting)
        XCTAssertTrue(connecting)

        do {
            _ = try await manager.connect(device)
            XCTFail("expected the second attempt to be rejected")
        } catch let error as BLEError {
            XCTAssertEqual(
                error,
                .connectionFailed("A connection attempt is already in progress")
            )
        }

        let link = GatedDeviceLink(device: device)
        transport.completeNext(with: link)

        let session = try await first.value
        let current = await manager.currentSession
        let connected = await manager.phase
        let stillConnecting = await manager.isConnecting
        XCTAssertTrue(current === session)
        XCTAssertEqual(connected, .connected)
        XCTAssertFalse(stillConnecting)

        await manager.disconnect()
    }

    /// Once the first attempt succeeds, the normal "already active" rejection
    /// still applies.
    func testConnectAfterSuccessIsStillRejected() async throws {
        let (manager, transport) = makeManager()
        let device = DiscoveredDevice(id: UUID(), name: "Gated")

        let first = Task { try await manager.connect(device) }
        let started = await poll { transport.connectCount == 1 }
        XCTAssertTrue(started)
        transport.completeNext(with: GatedDeviceLink(device: device))
        _ = try await first.value

        do {
            _ = try await manager.connect(device)
            XCTFail("expected rejection")
        } catch let error as BLEError {
            XCTAssertEqual(error, .connectionFailed("Another connection is already active"))
        }

        await manager.disconnect()
    }

    // MARK: - Disconnect / cancel

    func testDisconnectDuringConnectDoesNotInstallSession() async throws {
        let (manager, transport) = makeManager()
        let device = DiscoveredDevice(id: UUID(), name: "Gated")

        let attempt = Task { try await manager.connect(device) }
        let started = await poll { transport.connectCount == 1 }
        XCTAssertTrue(started)

        await manager.disconnect()

        await expectCancelled(attempt)
        let current = await manager.currentSession
        let phase = await manager.phase
        XCTAssertNil(current)
        XCTAssertEqual(transport.cancelCount, 1)
        XCTAssertEqual(phase, .idle)
    }

    /// A transport that ignores cancellation eventually returns a link. That
    /// link must be closed, and the caller must see `.cancelled`.
    func testLateLinkAfterCancelIsClosedAndNotInstalled() async throws {
        let (manager, transport) = makeManager()
        let device = DiscoveredDevice(id: UUID(), name: "Gated")
        transport.ignoresCancellation = true

        let attempt = Task { try await manager.connect(device) }
        let started = await poll { transport.connectCount == 1 }
        XCTAssertTrue(started)

        await manager.cancelPendingConnection()

        let late = GatedDeviceLink(device: device)
        transport.completeNext(with: late)

        await expectCancelled(attempt)
        let current = await manager.currentSession
        XCTAssertTrue(late.isClosed)
        XCTAssertNil(current)
        XCTAssertEqual(transport.cancelCount, 1)
    }

    /// A cancelled caller task makes the attempt invalid even when the
    /// transport itself does not observe cancellation.
    func testCancelledConnectTaskDoesNotCreateSession() async throws {
        let (manager, transport) = makeManager()
        let device = DiscoveredDevice(id: UUID(), name: "Gated")

        let attempt = Task { try await manager.connect(device) }
        let started = await poll { transport.connectCount == 1 }
        XCTAssertTrue(started)

        attempt.cancel()

        let late = GatedDeviceLink(device: device)
        transport.completeNext(with: late)

        await expectCancelled(attempt)
        let current = await manager.currentSession
        XCTAssertTrue(late.isClosed)
        XCTAssertNil(current)
    }

    /// Cancelling one attempt must not poison the manager: the next connect
    /// works normally and the cleanup gate is released.
    func testConnectAfterCancelledAttemptStillWorks() async throws {
        let (manager, transport) = makeManager()
        let device = DiscoveredDevice(id: UUID(), name: "Gated")

        let attempt = Task { try await manager.connect(device) }
        let started = await poll { transport.connectCount == 1 }
        XCTAssertTrue(started)
        await manager.cancelPendingConnection()
        transport.completeNext(with: GatedDeviceLink(device: device))
        await expectCancelled(attempt)

        let retry = Task { try await manager.connect(device) }
        let retried = await poll { transport.connectCount == 2 }
        XCTAssertTrue(retried)
        let link = GatedDeviceLink(device: device)
        transport.completeNext(with: link)
        let session = try await retry.value

        let current = await manager.currentSession
        XCTAssertTrue(current === session)
        XCTAssertFalse(link.isClosed)

        await manager.disconnect()
    }

    // MARK: - Transport switch

    func testSwitchTransportDuringConnectClosesOldLink() async throws {
        let device = DiscoveredDevice(id: UUID(), name: "Gated")
        let transport = GatedDeviceTransport()
        let newTransport = GatedDeviceTransport(kind: .coreBluetooth)
        transport.ignoresCancellation = true
        let manager = DeviceManager(
            transport: transport,
            crypto: { try AESGCMProvider(key: Data((0..<16).map(UInt8.init))) }
        )

        let attempt = Task { try await manager.connect(device) }
        let started = await poll { transport.connectCount == 1 }
        XCTAssertTrue(started)

        await manager.switchTransport(newTransport)

        let late = GatedDeviceLink(device: device)
        transport.completeNext(with: late)

        await expectCancelled(attempt)
        let current = await manager.currentSession
        let kind = await manager.transportKind
        let phase = await manager.phase
        XCTAssertTrue(late.isClosed)
        XCTAssertNil(current)
        XCTAssertEqual(kind, .coreBluetooth)
        XCTAssertEqual(transport.cancelCount, 1)
        XCTAssertEqual(phase, .idle)
    }

    // MARK: - Helpers

    private func makeManager() -> (DeviceManager, GatedDeviceTransport) {
        let transport = GatedDeviceTransport()
        let manager = DeviceManager(
            transport: transport,
            crypto: { try AESGCMProvider(key: Data((0..<16).map(UInt8.init))) }
        )
        return (manager, transport)
    }

    private func expectCancelled(
        _ task: Task<DeviceSession, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("expected cancellation", file: file, line: line)
        } catch let error as BLEError {
            XCTAssertEqual(error, .cancelled, file: file, line: line)
        } catch {
            XCTFail("expected .cancelled, got \(error)", file: file, line: line)
        }
    }

    private func poll(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

/// A transport whose `connect` suspends until the test completes it, so the
/// actor-reentrancy window is deterministic instead of timing-dependent.
final class GatedDeviceTransport: DeviceTransport, @unchecked Sendable {
    let kind: TransportKind

    private let lock = NSLock()
    private var pending: [CheckedContinuation<any DeviceLink, Error>] = []
    private var connectCountStorage = 0
    private var cancelCountStorage = 0
    private var ignoresCancellationStorage = false

    init(kind: TransportKind = .mock) {
        self.kind = kind
    }

    var connectCount: Int { lock.withLock { connectCountStorage } }
    var cancelCount: Int { lock.withLock { cancelCountStorage } }

    var ignoresCancellation: Bool {
        get { lock.withLock { ignoresCancellationStorage } }
        set { lock.withLock { ignoresCancellationStorage = newValue } }
    }

    func observeBluetoothState() -> AsyncStream<BluetoothState> {
        AsyncStream { continuation in
            continuation.yield(.poweredOn)
            continuation.finish()
        }
    }

    func scan(
        profile: GATTProfile
    ) async throws -> AsyncThrowingStream<[DiscoveredDevice], Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func stopScan() async {}

    func connect(
        _ device: DiscoveredDevice,
        profile: GATTProfile
    ) async throws -> any DeviceLink {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                connectCountStorage += 1
                pending.append(continuation)
            }
        }
    }

    func cancelPendingConnection() async {
        let continuations: [CheckedContinuation<any DeviceLink, Error>] = lock.withLock {
            cancelCountStorage += 1
            guard !ignoresCancellationStorage else { return [] }
            let current = pending
            pending = []
            return current
        }
        for continuation in continuations {
            continuation.resume(throwing: BLEError.cancelled)
        }
    }

    // MARK: - Test controls

    func completeNext(with link: any DeviceLink) {
        let continuation: CheckedContinuation<any DeviceLink, Error>? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            return pending.removeFirst()
        }
        continuation?.resume(returning: link)
    }

    func failNext(_ error: Error) {
        let continuation: CheckedContinuation<any DeviceLink, Error>? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            return pending.removeFirst()
        }
        continuation?.resume(throwing: error)
    }

    /// Releases every suspended attempt so a failed test cannot leak
    /// continuations and hang the suite.
    func failAll() {
        let continuations: [CheckedContinuation<any DeviceLink, Error>] = lock.withLock {
            let current = pending
            pending = []
            return current
        }
        for continuation in continuations {
            continuation.resume(throwing: BLEError.cancelled)
        }
    }
}

/// Minimal `DeviceLink` whose close state is observable by the tests.
final class GatedDeviceLink: DeviceLink, @unchecked Sendable {
    let device: DiscoveredDevice
    let inbound: AsyncStream<Data>

    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var closedStorage = false

    init(device: DiscoveredDevice) {
        self.device = device
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.inbound = stream
        self.inboundContinuation = continuation
    }

    var isClosed: Bool { lock.withLock { closedStorage } }
    var maximumWritePayloadLength: Int { 182 }
    var maximumWritePayloadLengthWithoutResponse: Int { 182 }

    func write(_ data: Data) async throws {}

    func close() async {
        lock.withLock { closedStorage = true }
        inboundContinuation.finish()
    }

    func observeState() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
    }
}
