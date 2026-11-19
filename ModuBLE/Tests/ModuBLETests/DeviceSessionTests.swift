import XCTest
@testable import ModuBLE

final class DeviceSessionTests: XCTestCase {
    private let key = Data(repeating: 0x22, count: 16)
    private let cbcKey = Data(repeating: 0x33, count: 32)

    func testTelemetryEventIsParsed() async throws {
        let (session, link, crypto) = try makeSession()
        let sink = DeviceEventSink()
        sink.start(session.events)

        let telemetry = Telemetry(
            yaw: 12.34,
            pitch: -5.6,
            roll: 179.99,
            battery: 42,
            isCharging: true,
            uptimeMilliseconds: 42
        )
        let payload = try TelemetryCodec.encode(telemetry)
        link.emit(try eventFrame(payload, sequence: 7, crypto: crypto))

        let arrived = await sink.waitFor(1, timeout: .seconds(1))
        XCTAssertTrue(arrived)
        let event = try XCTUnwrap(sink.values.first)
        XCTAssertEqual(event.sequence, 7)
        XCTAssertEqual(event.payload, payload)
        XCTAssertEqual(event.telemetry, telemetry)
        await session.close()
    }

    /// A non-telemetry event must still reach the app, just without a decoded
    /// model. Dropping it would hide application events the SDK does not know.
    func testNonTelemetryEventKeepsItsPayload() async throws {
        let (session, link, crypto) = try makeSession()
        let sink = DeviceEventSink()
        sink.start(session.events)

        let payload = Data("HELLO".utf8)
        link.emit(try eventFrame(payload, sequence: 3, crypto: crypto))

        let arrived = await sink.waitFor(1, timeout: .seconds(1))
        XCTAssertTrue(arrived)
        XCTAssertEqual(sink.values.first?.payload, payload)
        XCTAssertNil(sink.values.first?.telemetry)
        await session.close()
    }

    func testRequestResponseAndMTUForwarding() async throws {
        let (session, link, crypto) = try makeSession(maximumWritePayload: 182)
        respond(on: link, crypto: crypto, reply: Data("OK".utf8))

        let reply = try await session.request(Data("PING".utf8))
        XCTAssertEqual(reply, Data("OK".utf8))
        XCTAssertEqual(session.maximumWritePayloadLength, 182)
        XCTAssertEqual(session.attMTU, 185)
        await session.close()
    }

    func testLinkFailureClosesTheSessionAndFinishesEvents() async throws {
        let (session, link, _) = try makeSession()
        let sink = DeviceEventSink()
        sink.start(session.events)

        link.fail("radio lost")

        let closed = await poll { session.state == .closed(reason: "radio lost") }
        XCTAssertTrue(closed)
        XCTAssertTrue(session.isClosed)
        let finished = await sink.waitUntilFinished(timeout: .seconds(1))
        XCTAssertTrue(finished)
    }

    func testCloseIsIdempotentAndFinishesEvents() async throws {
        let (session, _, _) = try makeSession()
        let sink = DeviceEventSink()
        sink.start(session.events)

        await session.close()
        await session.close()

        XCTAssertTrue(session.isClosed)
        XCTAssertEqual(session.state, .closed(reason: nil))
        let finished = await sink.waitUntilFinished(timeout: .seconds(1))
        XCTAssertTrue(finished)
    }

    func testRequestAfterCloseIsRejected() async throws {
        let (session, _, _) = try makeSession()
        await session.close()

        do {
            _ = try await session.request(Data("PING".utf8))
            XCTFail("expected closed")
        } catch let error as SessionError {
            XCTAssertEqual(error, .closed)
        }

        do {
            try await session.write(Data("RAW".utf8))
            XCTFail("expected notReady")
        } catch let error as BLEError {
            XCTAssertEqual(error, .notReady)
        }
    }

    func testCryptoSwitchAndRawWriteAreForwarded() async throws {
        let (session, link, _) = try makeSession()

        XCTAssertEqual(session.algorithm, .aes128GCM)
        XCTAssertEqual(session.maxPlaintextLength, 4067)

        session.updateCrypto(try AESCBCProvider(key: cbcKey))
        XCTAssertEqual(session.algorithm, .aes128CBCHMAC)
        XCTAssertEqual(session.maxPlaintextLength, 4031)

        try await session.write(Data("RAW".utf8), mode: .withoutResponse)
        XCTAssertEqual(link.writtenPayloads.last, Data("RAW".utf8))
        await session.close()
    }

    // MARK: - Helpers

    private func makeSession(
        maximumWritePayload: Int = 182,
        timeout: Duration = .milliseconds(300)
    ) throws -> (DeviceSession, ScriptedDeviceLink, AESGCMProvider) {
        let crypto = try AESGCMProvider(key: key)
        let link = ScriptedDeviceLink(maximumWritePayload: maximumWritePayload)
        let session = DeviceSession(link: link, crypto: crypto, timeout: timeout)
        return (session, link, crypto)
    }

    private func eventFrame(
        _ payload: Data,
        sequence: UInt32,
        crypto: any CryptoProvider
    ) throws -> Data {
        let sealed = try crypto.encrypt(payload)
        return try PacketCodec().encode(Packet(kind: .event, sequence: sequence, payload: sealed))
    }

    private func respond(
        on link: ScriptedDeviceLink,
        crypto: any CryptoProvider,
        reply: Data
    ) {
        link.onWrite = { frame in
            guard let packet = try? PacketCodec().decode(frame),
                  let sealed = try? crypto.encrypt(reply),
                  let response = try? PacketCodec().encode(
                      Packet(kind: .response, sequence: packet.sequence, payload: sealed)
                  ) else { return }
            link.emit(response)
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

/// In-memory `DeviceLink` with manual control over inbound bytes and state.
/// Unlike `MockBLELink` it has no protocol stack, so a test can inject exactly
/// the frame it wants.
final class ScriptedDeviceLink: DeviceLink, @unchecked Sendable {
    let device: DiscoveredDevice
    let inbound: AsyncStream<Data>
    let maximumWritePayloadLength: Int
    let maximumWritePayloadLengthWithoutResponse: Int

    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var currentState: ConnectionState = .ready
    private var stateObservers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var writtenStorage: [Data] = []
    private var writeHandler: (@Sendable (Data) -> Void)?
    private var finished = false

    init(
        device: DiscoveredDevice = DiscoveredDevice(id: UUID(), name: "Scripted"),
        maximumWritePayload: Int = 182
    ) {
        self.device = device
        self.maximumWritePayloadLength = maximumWritePayload
        self.maximumWritePayloadLengthWithoutResponse = maximumWritePayload

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.inbound = stream
        self.continuation = continuation
    }

    var writtenPayloads: [Data] { lock.withLock { writtenStorage } }

    var onWrite: (@Sendable (Data) -> Void)? {
        get { lock.withLock { writeHandler } }
        set { lock.withLock { writeHandler = newValue } }
    }

    var isClosed: Bool { lock.withLock { finished } }
    var state: ConnectionState { lock.withLock { currentState } }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { throw BLEError.emptyPayload }
        let handler: (@Sendable (Data) -> Void)? = lock.withLock {
            guard !finished else { return nil }
            writtenStorage.append(data)
            return writeHandler
        }
        if lock.withLock({ finished }) { throw BLEError.notConnected }
        handler?(data)
    }

    func close() async {
        finish(state: .disconnected)
    }

    func observeState() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            let initial = lock.withLock { () -> ConnectionState in
                if !finished { stateObservers[id] = continuation }
                return currentState
            }
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.stateObservers[id] = nil }
            }
        }
    }

    /// Simulates a notification from the peripheral.
    func emit(_ data: Data) {
        continuation.yield(data)
    }

    /// Simulates an unexpected disconnect.
    func fail(_ reason: String) {
        finish(state: .failed(reason))
    }

    private func finish(state newState: ConnectionState) {
        let observers: [AsyncStream<ConnectionState>.Continuation]? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            currentState = newState
            return Array(stateObservers.values)
        }
        guard let observers else { return }

        continuation.finish()
        for observer in observers {
            observer.yield(newState)
        }
    }
}

/// Collects `DeviceEvent`s and fails instead of hanging when a stream regresses.
private final class DeviceEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DeviceEvent] = []
    private var finished = false
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<DeviceEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.lock.withLock { self.storage.append(event) }
            }
            guard let self else { return }
            self.lock.withLock { self.finished = true }
        }
    }

    var values: [DeviceEvent] { lock.withLock { storage } }
    var isFinished: Bool { lock.withLock { finished } }

    func waitFor(_ count: Int, timeout: Duration) async -> Bool {
        await poll(timeout: timeout) { self.values.count >= count }
    }

    func waitUntilFinished(timeout: Duration) async -> Bool {
        await poll(timeout: timeout) { self.isFinished }
    }

    private func poll(
        timeout: Duration,
        _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}
