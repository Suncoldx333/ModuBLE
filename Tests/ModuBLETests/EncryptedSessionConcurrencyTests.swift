import XCTest
@testable import ModuBLE

/// Regression tests for the window between reserving a sequence and installing
/// the pending continuation.
///
/// Before the fix, two callers could both observe `pending == nil`, both take a
/// sequence, and the second `pending` write silently orphaned the first
/// continuation. The symptom is not an error: the caller hangs forever, because
/// its timeout handler only resolves the *current* pending request.
final class EncryptedSessionConcurrencyTests: XCTestCase {
    private let gcmKey = Data((0..<16).map(UInt8.init))

    /// Thread-safe outcome recorder for concurrently running request tasks.
    private final class OutcomeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Result<Data, Error>] = []

        func record(_ result: Result<Data, Error>) {
            lock.withLock { storage.append(result) }
        }

        var results: [Result<Data, Error>] { lock.withLock { storage } }
        var count: Int { lock.withLock { storage.count } }

        var summary: String {
            var success = 0
            var busy = 0
            var other: [String] = []
            for result in results {
                switch result {
                case .success:
                    success += 1
                case .failure(let error):
                    if let session = error as? SessionError, session == .busy {
                        busy += 1
                    } else {
                        other.append("\(error)")
                    }
                }
            }
            return "success=\(success) busy=\(busy) other=\(other)"
        }
    }

    /// A burst of simultaneous requests must settle: one winner, everyone else
    /// `busy`, and — the point of this test — nobody left suspended.
    func testConcurrentRequestsNeverLeakAContinuation() async throws {
        let rounds = 20
        let concurrent = 128

        for round in 0..<rounds {
            let link = FakeBLELink()
            let crypto = try AESGCMProvider(key: gcmKey)
            let session = EncryptedSession(link: link, crypto: crypto, timeout: .seconds(3))
            // Hold the response briefly so the whole burst is admitted (or
            // rejected) before the first request can resolve.
            EchoResponder(link: link, crypto: crypto, replyDelay: .milliseconds(20)).install()

            let log = OutcomeLog()
            for _ in 0..<concurrent {
                Task {
                    do {
                        log.record(.success(try await session.request(Data("X".utf8))))
                    } catch {
                        log.record(.failure(error))
                    }
                }
            }

            let settled = await Self.waitUntil(timeout: .seconds(3)) {
                log.count == concurrent
            }
            XCTAssertTrue(
                settled,
                "round \(round): \(log.count)/\(concurrent) settled · \(log.summary)"
            )

            let results = log.results
            let successes = results.filter {
                if case .success = $0 { return true }
                return false
            }.count
            let busy = results.filter {
                if case .failure(let error) = $0,
                   let sessionError = error as? SessionError,
                   sessionError == .busy {
                    return true
                }
                return false
            }.count

            XCTAssertGreaterThanOrEqual(successes, 1, "round \(round): no request won")
            XCTAssertEqual(
                successes + busy,
                results.count,
                "round \(round): \(log.summary)"
            )

            await session.close()
        }
    }

    /// A local encoding failure must return the reserved sequence, otherwise the
    /// session stays `busy` forever even though nothing is in flight.
    func testReservationIsReleasedWhenFramingFails() async throws {
        let link = FakeBLELink()
        // A provider whose ciphertext grows past the packet limit. The size
        // guard uses the provider's own accounting, so a custom provider can
        // still fail at encode time.
        let expanding = ExpandingProvider()
        let session = EncryptedSession(link: link, crypto: expanding, timeout: .milliseconds(500))

        do {
            _ = try await session.request(Data(repeating: 0x01, count: 10))
            XCTFail("expected framing failure")
        } catch let error as SessionError {
            guard case .framing(.payloadTooLarge(let size)) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(size, 5010)
        }

        // The slot must be free again.
        let crypto = try AESGCMProvider(key: gcmKey)
        session.updateCrypto(crypto)
        EchoResponder(link: link, crypto: crypto).install()

        let reply = try await session.request(Data("PING".utf8))
        XCTAssertEqual(reply, Data("PING".utf8))
    }

    /// Closing while callers are still in the reservation window must release
    /// every one of them.
    func testConcurrentRequestsDuringCloseAlwaysSettle() async throws {
        for round in 0..<20 {
            let link = FakeBLELink()
            let crypto = try AESGCMProvider(key: gcmKey)
            let session = EncryptedSession(link: link, crypto: crypto, timeout: .seconds(2))

            let log = OutcomeLog()
            for _ in 0..<32 {
                Task {
                    do {
                        log.record(.success(try await session.request(Data("X".utf8))))
                    } catch {
                        log.record(.failure(error))
                    }
                }
            }

            await session.close()

            let settled = await Self.waitUntil(timeout: .seconds(2)) {
                log.count == 32
            }
            XCTAssertTrue(
                settled,
                "round \(round): \(log.count)/32 settled · \(log.summary)"
            )
        }
    }

    /// After a timeout the next request must be admitted, not rejected as busy.
    func testTimeoutReleasesTheSlot() async throws {
        let link = FakeBLELink()
        let crypto = try AESGCMProvider(key: gcmKey)
        let session = EncryptedSession(link: link, crypto: crypto, timeout: .milliseconds(80))

        do {
            _ = try await session.request(Data("FIRST".utf8))
            XCTFail("expected timeout")
        } catch let error as SessionError {
            XCTAssertEqual(error, .timedOut)
        }

        do {
            _ = try await session.request(Data("SECOND".utf8))
            XCTFail("expected timeout")
        } catch let error as SessionError {
            // The point: `.timedOut`, never `.busy`.
            XCTAssertEqual(error, .timedOut)
        }
    }

    /// Regression for the window between the sequence check and `finish`.
    ///
    /// A's response is admitted and starts decrypting; A times out while the
    /// decryption is still running; B then installs itself as the pending
    /// request; when A's decryption finally completes it must not resolve B.
    func testDecryptionFinishingAfterTimeoutDoesNotCompleteNextRequest() async throws {
        let link = FakeBLELink()
        let base = try AESGCMProvider(key: gcmKey)
        let session = EncryptedSession(
            link: link,
            crypto: SlowDecryptProvider(base: base, seconds: 0.4),
            timeout: .milliseconds(200)
        )
        EchoResponder(link: link, crypto: base).install()

        let first = Task { try await session.request(Data("A".utf8)) }
        // A has timed out; its response is still inside `decrypt`.
        try await Task.sleep(for: .milliseconds(250))

        let second = Task { try await session.request(Data("B".utf8)) }
        let reply = try await second.value
        XCTAssertEqual(reply, Data("B".utf8))
        _ = try? await first.value
    }

    // MARK: - Helpers

    static func waitUntil(
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

/// Seals into an envelope that no 4096-byte frame can hold, without changing
/// the reported `maxPlaintextLength`.
private struct ExpandingProvider: CryptoProvider {
    let algorithm: CryptoAlgorithm = .aes128GCM

    func encrypt(_ plaintext: Data) throws -> Data {
        plaintext + Data(repeating: 0xEE, count: 5000)
    }

    func decrypt(_ ciphertext: Data) throws -> Data {
        ciphertext
    }
}

/// Wraps the real provider and blocks inside `decrypt`, so a test can make the
/// response handler straddle a request timeout deterministically.
private struct SlowDecryptProvider: CryptoProvider {
    let base: AESGCMProvider
    let seconds: TimeInterval

    var algorithm: CryptoAlgorithm { base.algorithm }

    func encrypt(_ plaintext: Data) throws -> Data {
        try base.encrypt(plaintext)
    }

    func decrypt(_ ciphertext: Data) throws -> Data {
        Thread.sleep(forTimeInterval: seconds)
        return try base.decrypt(ciphertext)
    }
}
