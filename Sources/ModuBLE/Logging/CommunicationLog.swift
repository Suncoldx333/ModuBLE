import Foundation

public enum LogLevel: String, Sendable, CaseIterable, Comparable {
    case debug
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum LogCategory: String, Sendable, CaseIterable {
    case ble
    case gatt
    case transport
    /// Bytes written to the peripheral (TX from the central's point of view).
    case transmit
    /// Bytes notified by the peripheral.
    case receive
    case crypto
    case session
    case demo
}

/// One structured communication event.
///
/// `payload` is only for non-sensitive bytes: demo traffic, ciphertext, nonce or
/// IV. Keys, session secrets and production plaintext must never be passed here.
public struct CommunicationLog: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
    public let payload: Data?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        category: LogCategory,
        message: String,
        payload: Data? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.payload = payload
    }
}

/// Bounded, ordered in-memory log store. The UI observes it; the SDK appends.
///
/// Appends are synchronous and ordered, so a burst of BLE callbacks produces a
/// log that reads in the same order the traffic happened. Thread safety comes
/// from a lock rather than an actor on purpose: `await`ing an actor hop would
/// let concurrent producers interleave.
public final class CommunicationLogStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CommunicationLog] = []
    private var appendHandler: (@Sendable (CommunicationLog) -> Void)?
    private var mirrorConsole = false
    private let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = max(1, capacity)
    }

    /// Mirrors every entry to stdout as well, so the Xcode console shows the
    /// same ordered stream as the in-app log. Off by default.
    public func setMirrorsToConsole(_ enabled: Bool) {
        lock.withLock { mirrorConsole = enabled }
    }

    /// One line per entry, in append order. Handy for copying a session out of
    /// the demo and pasting it into an issue.
    public func textDump() -> String {
        lock.withLock {
            storage.map(Self.line(for:)).joined(separator: "\n")
        }
    }

    /// Installs a callback invoked in append order, outside the lock.
    ///
    /// Consumers that must preserve ordering (a UI log view) should hop to their
    /// own serial executor inside the callback rather than spawning unordered
    /// tasks.
    public func setAppendHandler(_ handler: (@Sendable (CommunicationLog) -> Void)?) {
        lock.withLock { appendHandler = handler }
    }

    public var entries: [CommunicationLog] {
        lock.withLock { storage }
    }

    public func append(_ entry: CommunicationLog) {
        let (handler, mirror): ((@Sendable (CommunicationLog) -> Void)?, Bool) = lock.withLock {
            storage.append(entry)
            if storage.count > capacity {
                storage.removeFirst(storage.count - capacity)
            }
            return (appendHandler, mirrorConsole)
        }
        if mirror {
            print(Self.line(for: entry))
        }
        handler?(entry)
    }

    public func append(contentsOf newEntries: [CommunicationLog]) {
        let (handler, mirror): ((@Sendable (CommunicationLog) -> Void)?, Bool) = lock.withLock {
            storage.append(contentsOf: newEntries)
            if storage.count > capacity {
                storage.removeFirst(storage.count - capacity)
            }
            return (appendHandler, mirrorConsole)
        }
        for entry in newEntries {
            if mirror { print(Self.line(for: entry)) }
            handler?(entry)
        }
    }

    public func clear() {
        lock.withLock { storage.removeAll() }
    }
}

extension CommunicationLogStore {
    /// Shorthand used by the transport layer.
    func log(_ level: LogLevel, _ category: LogCategory, _ message: String, payload: Data? = nil) {
        append(CommunicationLog(level: level, category: category, message: message, payload: payload))
    }

    private static func line(for entry: CommunicationLog) -> String {
        var line = "[\(timeString(entry.timestamp))] "
        line += entry.level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
        line += entry.category.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)
        line += entry.message
        if let payload = entry.payload, !payload.isEmpty {
            let hex = payload.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
            line += " | \(payload.count) B: \(hex)\(payload.count > 32 ? " …" : "")"
        }
        return line
    }

    private static func timeString(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.hour, .minute, .second, .nanosecond],
            from: date
        )
        return String(
            format: "%02d:%02d:%02d.%03d",
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0,
            (parts.nanosecond ?? 0) / 1_000_000
        )
    }
}
