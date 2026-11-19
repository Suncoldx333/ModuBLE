import XCTest
@testable import ModuBLE

final class CommunicationLogStoreTests: XCTestCase {
    func testAppendKeepsOrder() {
        let store = CommunicationLogStore()
        store.append(CommunicationLog(level: .info, category: .ble, message: "connected"))
        store.append(CommunicationLog(level: .debug, category: .crypto, message: "encrypted"))

        XCTAssertEqual(store.entries.map(\.message), ["connected", "encrypted"])
    }

    func testStoreIsBounded() {
        let store = CommunicationLogStore(capacity: 3)
        for index in 1...5 {
            store.append(CommunicationLog(level: .info, category: .session, message: "\(index)"))
        }

        XCTAssertEqual(store.entries.count, 3)
        XCTAssertEqual(store.entries.map(\.message), ["3", "4", "5"])
    }

    func testClear() {
        let store = CommunicationLogStore()
        store.append(CommunicationLog(level: .error, category: .ble, message: "boom"))
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPayloadIsCarriedVerbatim() {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let store = CommunicationLogStore()
        store.append(CommunicationLog(level: .debug, category: .transport, message: "notify", payload: payload))
        XCTAssertEqual(store.entries.first?.payload, payload)
    }

    func testLevelOrdering() {
        XCTAssertLessThan(LogLevel.debug, LogLevel.info)
        XCTAssertLessThan(LogLevel.info, LogLevel.warning)
        XCTAssertLessThan(LogLevel.warning, LogLevel.error)
    }

    func testAppendHandlerSeesEveryEntryInOrderEvenWhenTrimmed() {
        let store = CommunicationLogStore(capacity: 2)
        let received = MessageBox()

        store.setAppendHandler { entry in
            received.append(entry.message)
        }

        for index in 1...4 {
            store.append(CommunicationLog(level: .info, category: .ble, message: "\(index)"))
        }

        XCTAssertEqual(received.snapshot, ["1", "2", "3", "4"])
        XCTAssertEqual(store.entries.map(\.message), ["3", "4"])
    }
}

/// Thread-safe collector for values produced by a `@Sendable` callback.
private final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ item: String) {
        lock.withLock { items.append(item) }
    }

    var snapshot: [String] {
        lock.withLock { items }
    }
}
