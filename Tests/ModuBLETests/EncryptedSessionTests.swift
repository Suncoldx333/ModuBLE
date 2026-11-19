import XCTest
@testable import ModuBLE

final class EncryptedSessionTests: XCTestCase {
    private let gcmKey = Data((0..<16).map(UInt8.init))
    private let cbcKey = Data((0..<32).map(UInt8.init))

    // MARK: - Round trip

    func testGCMRoundTrip() async throws {
        let (session, link, crypto) = try makeGCM()
        EchoResponder(link: link, crypto: crypto) { plaintext in
            Data((String(decoding: plaintext, as: UTF8.self) + "_ACK").utf8)
        }.install()

        let response = try await session.request(Data("START".utf8))
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "START_ACK")
        XCTAssertEqual(link.writtenPayloads.count, 1)
    }

    func testCBCRoundTrip() async throws {
        let link = FakeBLELink()
        let crypto = try AESCBCProvider(key: cbcKey)
        let session = EncryptedSession(link: link, crypto: crypto, timeout: .milliseconds(500))
        EchoResponder(link: link, crypto: crypto) { plaintext in
            Data((String(decoding: plaintext, as: UTF8.self) + "_ACK").utf8)
        }.install()

        let response = try await session.request(Data("START".utf8))
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "START_ACK")
    }

    func testWrittenFrameIsARequestWithSealedPayload() async throws {
        let (session, link, crypto) = try makeGCM()
        EchoResponder(link: link, crypto: crypto).install()

        _ = try await session.request(Data("PING".utf8))

        let frame = try XCTUnwrap(link.writtenPayloads.first)
        let packet = try PacketCodec().decode(frame)
        XCTAssertEqual(packet.kind, .request)
        XCTAssertEqual(packet.sequence, 1)
        // The payload on the wire must be the sealed envelope, never plaintext.
        XCTAssertNotEqual(packet.payload, Data("PING".utf8))
        XCTAssertEqual(try crypto.decrypt(packet.payload), Data("PING".utf8))
    }

    func testSequenceIncrementsPerRequest() async throws {
        let (session, link, crypto) = try makeGCM()
        EchoResponder(link: link, crypto: crypto).install()

        _ = try await session.request(Data("A".utf8))
        _ = try await session.request(Data("B".utf8))

        let sequences = try link.writtenPayloads.map { try PacketCodec().decode($0).sequence }
        XCTAssertEqual(sequences, [1, 2])
    }

    // MARK: - Failure paths

    func testTimeoutWhenPeripheralNeverAnswers() async throws {
        let (session, _, _) = try makeGCM(timeout: .milliseconds(120))

        await expectFailure(.timedOut) {
            try await session.request(Data("START".utf8))
        }
    }

    func testHandshakeFailureIsReportedAsCryptoError() async throws {
        let (session, link, crypto) = try makeGCM()
        link.onWrite = { frame in
            guard let packet = try? PacketCodec().decode(frame),
                  let sealed = try? crypto.encrypt(Data("ACK".utf8)),
                  let response = try? PacketCodec().encode(
                      Packet(kind: .response, sequence: packet.sequence, payload: sealed)
                  ) else { return }
            link.emit(Self.tampered(response))
        }

        await expectFailure(.crypto(.authenticationFailed)) {
            try await session.request(Data("START".utf8))
        }
    }

    /// A response for another sequence is stale or bogus. It must be dropped,
    /// not turned into an error for the request that is actually waiting: the
    /// peer may still answer that one in time.
    func testStaleResponseIsDroppedInsteadOfFailingCurrentRequest() async throws {
        let (session, link, crypto) = try makeGCM(timeout: .milliseconds(120))
        link.onWrite = { frame in
            guard let packet = try? PacketCodec().decode(frame),
                  let sealed = try? crypto.encrypt(Data("ACK".utf8)),
                  let response = try? PacketCodec().encode(
                      Packet(kind: .response, sequence: packet.sequence &+ 1, payload: sealed)
                  ) else { return }
            link.emit(response)
        }

        // Before the fix this failed immediately with `.unexpectedResponse`.
        await expectFailure(.timedOut) {
            try await session.request(Data("START".utf8))
        }
    }

    /// Regression: after A timed out, B owns the pending slot. A's delayed
    /// answer must neither complete B with A's payload nor fail it.
    func testLateResponseFromTimedOutRequestDoesNotCompleteNextRequest() async throws {
        let (session, link, crypto) = try makeGCM(timeout: .milliseconds(300))

        do {
            _ = try await session.request(Data("A".utf8))
            XCTFail("expected timeout")
        } catch let error as SessionError {
            XCTAssertEqual(error, .timedOut)
        }

        let first = try XCTUnwrap(link.writtenPayloads.first)
        let staleSequence = try PacketCodec().decode(first).sequence

        let second = Task { try await session.request(Data("B".utf8)) }
        let sent = await waitUntil(timeout: .seconds(1)) { link.writtenPayloads.count == 2 }
        XCTAssertTrue(sent, "the second request was never written")
        let secondSequence = try PacketCodec().decode(link.writtenPayloads[1]).sequence

        // Deliver A's answer, then B's. B must see only its own payload.
        link.emit(try responseFrame(sequence: staleSequence, plaintext: Data("STALE".utf8), crypto: crypto))
        link.emit(try responseFrame(sequence: secondSequence, plaintext: Data("B_ACK".utf8), crypto: crypto))

        let reply = try await second.value
        XCTAssertEqual(reply, Data("B_ACK".utf8))
    }

    /// Same window, but A's late answer fails authentication. B must survive.
    func testCorruptLateResponseDoesNotFailNextRequest() async throws {
        let (session, link, crypto) = try makeGCM(timeout: .milliseconds(300))

        do {
            _ = try await session.request(Data("A".utf8))
            XCTFail("expected timeout")
        } catch let error as SessionError {
            XCTAssertEqual(error, .timedOut)
        }

        let staleSequence = try PacketCodec().decode(link.writtenPayloads[0]).sequence

        let second = Task { try await session.request(Data("B".utf8)) }
        let sent = await waitUntil(timeout: .seconds(1)) { link.writtenPayloads.count == 2 }
        XCTAssertTrue(sent, "the second request was never written")
        let secondSequence = try PacketCodec().decode(link.writtenPayloads[1]).sequence

        let stale = try responseFrame(
            sequence: staleSequence,
            plaintext: Data("STALE".utf8),
            crypto: crypto
        )
        link.emit(Self.tampered(stale))
        link.emit(try responseFrame(sequence: secondSequence, plaintext: Data("B_ACK".utf8), crypto: crypto))

        let reply = try await second.value
        XCTAssertEqual(reply, Data("B_ACK".utf8))
    }

    func testConcurrentRequestIsRejected() async throws {
        let (session, _, _) = try makeGCM(timeout: .milliseconds(500))
        // No responder: the first request stays pending.
        let first = Task { try await session.request(Data("FIRST".utf8)) }
        try await Task.sleep(for: .milliseconds(50))

        await expectFailure(.busy) {
            try await session.request(Data("SECOND".utf8))
        }

        await session.close()
        _ = try? await first.value
    }

    func testCloseReleasesWaitingRequest() async throws {
        let (session, _, _) = try makeGCM(timeout: .seconds(5))
        let request = Task { try await session.request(Data("START".utf8)) }
        try await Task.sleep(for: .milliseconds(50))

        await session.close()

        await expectFailure(.closed) {
            try await request.value
        }
    }

    func testRequestAfterCloseIsRejected() async throws {
        let (session, _, _) = try makeGCM()
        await session.close()

        await expectFailure(.closed) {
            try await session.request(Data("START".utf8))
        }
    }

    /// The envelope version tells the peer which algorithm to use, so a session
    /// can switch without reconnecting.
    func testCryptoCanBeSwitchedMidSession() async throws {
        let link = FakeBLELink()
        let gcm = try AESGCMProvider(key: gcmKey)
        let cbc = try AESCBCProvider(key: cbcKey)
        let session = EncryptedSession(link: link, crypto: gcm, timeout: .milliseconds(500))

        let providers: [UInt8: any CryptoProvider] = [
            AESGCMProvider.envelopeVersion: gcm,
            AESCBCProvider.envelopeVersion: cbc
        ]
        link.onWrite = { frame in
            guard let packet = try? PacketCodec().decode(frame),
                  let version = packet.payload.first,
                  let provider = providers[version],
                  let plaintext = try? provider.decrypt(packet.payload),
                  let sealed = try? provider.encrypt(plaintext),
                  let response = try? PacketCodec().encode(
                      Packet(kind: .response, sequence: packet.sequence, payload: sealed)
                  ) else { return }
            link.emit(response)
        }

        XCTAssertEqual(session.algorithm, .aes128GCM)
        let gcmReply = try await session.request(Data("A".utf8))
        XCTAssertEqual(gcmReply, Data("A".utf8))

        session.updateCrypto(cbc)
        XCTAssertEqual(session.algorithm, .aes128CBCHMAC)
        let cbcReply = try await session.request(Data("B".utf8))
        XCTAssertEqual(cbcReply, Data("B".utf8))

        // The second frame must carry CBC's envelope version, not GCM's.
        let second = try XCTUnwrap(link.writtenPayloads.last)
        let packet = try PacketCodec().decode(second)
        XCTAssertEqual(packet.payload.first, AESCBCProvider.envelopeVersion)
    }

    func testResponseSplitAcrossNotificationsIsReassembled() async throws {        let (session, link, crypto) = try makeGCM()
        EchoResponder(link: link, crypto: crypto, splitInto: 7) { plaintext in
            Data((String(decoding: plaintext, as: UTF8.self) + "_ACK").utf8)
        }.install()

        let response = try await session.request(Data("START".utf8))
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "START_ACK")
    }

    func testStatusTextNoiseDoesNotBreakTheSession() async throws {
        let (session, link, crypto) = try makeGCM()
        let responder = EchoResponder(link: link, crypto: crypto)
        responder.install()

        link.emit(Data("READY".utf8))
        link.emit(Data("RX #1: 5 bytes".utf8))

        let response = try await session.request(Data("START".utf8))
        XCTAssertEqual(String(decoding: response, as: UTF8.self), "START")
    }

    // MARK: - Helpers

    private func makeGCM(timeout: Duration = .milliseconds(500)) throws -> (EncryptedSession, FakeBLELink, AESGCMProvider) {
        let link = FakeBLELink()
        let crypto = try AESGCMProvider(key: gcmKey)
        let session = EncryptedSession(link: link, crypto: crypto, timeout: timeout)
        return (session, link, crypto)
    }

    private func responseFrame(
        sequence: UInt32,
        plaintext: Data,
        crypto: any CryptoProvider
    ) throws -> Data {
        let sealed = try crypto.encrypt(plaintext)
        return try PacketCodec().encode(
            Packet(kind: .response, sequence: sequence, payload: sealed)
        )
    }

    private func waitUntil(
        timeout: Duration,
        _ condition: @escaping @Sendable () -> Bool
    ) async -> Bool {
        await EncryptedSessionConcurrencyTests.waitUntil(timeout: timeout, condition)
    }

    private func expectFailure(
        _ expected: SessionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Data
    ) async {
        do {
            let value = try await body()
            XCTFail("expected \(expected), got \(value.count) B", file: file, line: line)
        } catch let error as SessionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("expected \(expected), got \(error)", file: file, line: line)
        }
    }

    private static func tampered(_ frame: Data) -> Data {
        var copy = frame
        copy[copy.index(before: copy.endIndex)] ^= 0x01
        return copy
    }
}

/// A virtual peripheral: decrypts every request, applies `transform`, and emits
/// the encrypted response with the same sequence.
///
/// Holds the link weakly so `install()` does not create a retain cycle: the
/// link's write handler keeps this responder alive for as long as the link lives.
final class EchoResponder: @unchecked Sendable {
    private let codec = PacketCodec()
    private weak var link: FakeBLELink?
    private let crypto: any CryptoProvider
    private let transform: @Sendable (Data) -> Data
    private let splitInto: Int?
    private let replyDelay: Duration?

    init(
        link: FakeBLELink,
        crypto: any CryptoProvider,
        splitInto: Int? = nil,
        replyDelay: Duration? = nil,
        transform: @escaping @Sendable (Data) -> Data = { $0 }
    ) {
        self.link = link
        self.crypto = crypto
        self.splitInto = splitInto
        self.replyDelay = replyDelay
        self.transform = transform
    }

    func install() {
        link?.onWrite = { [self] frame in
            respond(to: frame)
        }
    }

    private func respond(to frame: Data) {
        guard let link,
              let packet = try? codec.decode(frame),
              let plaintext = try? crypto.decrypt(packet.payload),
              let sealed = try? crypto.encrypt(transform(plaintext)),
              let response = try? codec.encode(
                  Packet(kind: .response, sequence: packet.sequence, payload: sealed)
              ) else { return }

        let deliver: @Sendable () -> Void = { [splitInto] in
            if let splitInto, splitInto > 0, splitInto < response.count {
                link.emit(response.prefix(splitInto))
                link.emit(response.suffix(from: splitInto))
            } else {
                link.emit(response)
            }
        }

        if let replyDelay {
            // Lets a burst of concurrent callers pile up before the first
            // response resolves, which makes "one winner" deterministic.
            Task {
                try? await Task.sleep(for: replyDelay)
                deliver()
            }
        } else {
            deliver()
        }
    }
}
