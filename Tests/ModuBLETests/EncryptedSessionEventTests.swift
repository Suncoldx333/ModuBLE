import XCTest
@testable import ModuBLE

/// `event` frames used to be logged and dropped. They now go through the same
/// decrypt path as responses and are published on `EncryptedSession.events`.
final class EncryptedSessionEventTests: XCTestCase {
    private let gcmKey = Data((0..<16).map(UInt8.init))

    func testEventIsDecryptedAndForwarded() async throws {
        let (session, link, crypto) = try makeSession()
        let sink = EventSink()
        sink.start(session.events)
        session.start()   // deliberately no request: events must arrive on their own

        link.emit(try frame(kind: .event, sequence: 7, payload: Data("HELLO".utf8), crypto: crypto))

        let arrived = await sink.waitFor(1, timeout: .seconds(1))
        XCTAssertTrue(arrived)
        XCTAssertEqual(sink.values.first?.sequence, 7)
        XCTAssertEqual(sink.values.first?.payload, Data("HELLO".utf8))
        await session.close()
    }

    func testEventSequenceIsIndependentOfRequestSequence() async throws {
        let (session, link, crypto) = try makeSession()
        EchoResponder(link: link, crypto: crypto) { _ in Data("OK".utf8) }.install()

        let sink = EventSink()
        sink.start(session.events)
        session.start()

        link.emit(try frame(kind: .event, sequence: 10_000, payload: Data("E".utf8), crypto: crypto))
        let reply = try await session.request(Data("R".utf8))

        XCTAssertEqual(reply, Data("OK".utf8))
        let secondArrived = await sink.waitFor(1, timeout: .seconds(1))
        XCTAssertTrue(secondArrived)
        XCTAssertEqual(sink.values.first?.sequence, 10_000)
        await session.close()
    }

    func testEventAndResponseDoNotInterfere() async throws {
        let (session, link, crypto) = try makeSession()
        EchoResponder(link: link, crypto: crypto) { plaintext in plaintext + Data("_ACK".utf8) }.install()

        let sink = EventSink()
        sink.start(session.events)
        session.start()

        link.emit(try frame(kind: .event, sequence: 3, payload: Data("TELEMETRY".utf8), crypto: crypto))
        let reply = try await session.request(Data("START".utf8))
        link.emit(try frame(kind: .event, sequence: 4, payload: Data("MORE".utf8), crypto: crypto))

        XCTAssertEqual(reply, Data("START_ACK".utf8))
        let bothArrived = await sink.waitFor(2, timeout: .seconds(1))
        XCTAssertTrue(bothArrived)
        XCTAssertEqual(sink.values.map(\.sequence), [3, 4])
        await session.close()
    }

    /// One corrupt event is logged and dropped; it must not close the session or
    /// poison the next request.
    func testMalformedEventIsDroppedAndSessionSurvives() async throws {
        let (session, link, crypto) = try makeSession(timeout: .milliseconds(400))
        EchoResponder(link: link, crypto: crypto).install()

        let sink = EventSink()
        sink.start(session.events)
        session.start()

        // Correct frame, corrupt envelope: first byte says GCM, the rest is junk.
        var junk = Data([AESGCMProvider.envelopeVersion])
        junk.append(Data(repeating: 0x5A, count: 40))
        let bad = try PacketCodec().encode(Packet(kind: .event, sequence: 5, payload: junk))
        link.emit(bad)

        let reply = try await session.request(Data("PING".utf8))
        XCTAssertEqual(reply, Data("PING".utf8))
        XCTAssertTrue(sink.values.isEmpty)
        await session.close()
    }

    func testEventStreamFinishesWhenSessionCloses() async throws {
        let (session, _, _) = try makeSession()
        let sink = EventSink()
        sink.start(session.events)
        session.start()

        await session.close()

        let finished = await sink.waitUntilFinished(timeout: .seconds(1))
        XCTAssertTrue(finished)
    }

    func testEventStreamFinishesWhenLinkEnds() async throws {
        let (session, link, _) = try makeSession()
        let sink = EventSink()
        sink.start(session.events)
        session.start()

        await link.close()

        let finished = await sink.waitUntilFinished(timeout: .seconds(1))
        XCTAssertTrue(finished)
    }

    // MARK: - Helpers

    private func makeSession(
        timeout: Duration = .milliseconds(500)
    ) throws -> (EncryptedSession, FakeBLELink, AESGCMProvider) {
        let link = FakeBLELink()
        let crypto = try AESGCMProvider(key: gcmKey)
        let session = EncryptedSession(link: link, crypto: crypto, timeout: timeout)
        return (session, link, crypto)
    }

    private func frame(
        kind: Packet.Kind,
        sequence: UInt32,
        payload: Data,
        crypto: any CryptoProvider
    ) throws -> Data {
        let sealed = try crypto.encrypt(payload)
        return try PacketCodec().encode(Packet(kind: kind, sequence: sequence, payload: sealed))
    }
}

/// Collects events from the (single-consumer) event stream and offers polling
/// waits, so a regression fails instead of hanging the test run.
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SessionEvent] = []
    private var finished = false
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncStream<SessionEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.lock.withLock { self.storage.append(event) }
            }
            guard let self else { return }
            self.lock.withLock { self.finished = true }
        }
    }

    var values: [SessionEvent] { lock.withLock { storage } }
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
