import Foundation

/// What a plaintext request asked the reference device to do.
///
/// Shared by the mock peripheral and the macOS app so the two cannot drift into
/// slightly different command semantics.
public enum DemoPeripheralCommand: Equatable, Sendable {
    case startTelemetry
    case stopTelemetry
    case setTelemetryRate(Double)
    case ping
    case echo
}

/// The reference device's command table.
public enum DemoPeripheralBehavior {
    /// Rates outside this range are rejected instead of silently clamped.
    public static let rateRange: ClosedRange<Double> = 0.2...10

    /// Maps a decrypted request payload to the reply and the side effect.
    ///
    /// | request | reply | side effect |
    /// |---|---|---|
    /// | `START` | `START_ACK` | start telemetry |
    /// | `STOP` | `STOP_ACK` | stop telemetry |
    /// | `SET_RATE:<hz>` | `RATE:<hz>` | change the emit rate |
    /// | `PING` | `PONG` | — |
    /// | anything else | echoed verbatim | — |
    public static func handle(_ plaintext: Data) -> (reply: Data, command: DemoPeripheralCommand) {
        guard let text = String(data: plaintext, encoding: .utf8) else {
            return (plaintext, .echo)
        }

        switch text {
        case "START":
            return (Data("START_ACK".utf8), .startTelemetry)
        case "STOP":
            return (Data("STOP_ACK".utf8), .stopTelemetry)
        case "PING":
            return (Data("PONG".utf8), .ping)
        default:
            break
        }

        let prefix = "SET_RATE:"
        if text.hasPrefix(prefix) {
            let raw = text.dropFirst(prefix.count)
            if let hz = Double(raw), rateRange.contains(hz) {
                return (Data("RATE:\(format(hz))".utf8), .setTelemetryRate(hz))
            }
            return (Data("RATE_ERROR".utf8), .echo)
        }

        return (plaintext, .echo)
    }

    /// Compact, stable rendering: `2` rather than `2.0`, `0.5` as-is.
    public static func format(_ hz: Double) -> String {
        String(format: "%g", hz)
    }
}
