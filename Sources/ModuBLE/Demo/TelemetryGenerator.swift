import Foundation

/// Produces a deterministic, smooth attitude trace so the demo has something to
/// show without a motion sensor.
///
/// State advances only in `next(advancingBy:)`, so tests and the mock peripheral
/// share the exact same numbers. Every value is rounded to 0.01° so it survives
/// the centidegree wire format unchanged.
public struct TelemetryGenerator: Sendable {
    private var phase: Double = 0
    private var uptime: Double = 0
    private var battery: Double = 82
    public var isCharging: Bool

    public init(isCharging: Bool = false) {
        self.isCharging = isCharging
    }

    /// Seconds of simulated time since the generator was created.
    public var uptimeSeconds: Double { uptime / 1000 }

    public mutating func next(advancingBy delta: Duration = .seconds(1)) -> Telemetry {
        let seconds = Double(delta.components.seconds)
            + Double(delta.components.attoseconds) / 1e18

        phase += seconds * 0.9
        uptime += seconds * 1000
        battery = max(0, battery - seconds * 0.02)

        return Telemetry(
            yaw: Self.roundToCenti(sin(phase) * 45),
            pitch: Self.roundToCenti(sin(phase * 0.7) * 20),
            roll: Self.roundToCenti(cos(phase * 1.3) * 25),
            battery: Int(battery.rounded()),
            isCharging: isCharging,
            uptimeMilliseconds: Int(uptime)
        )
    }

    public mutating func reset() {
        phase = 0
        uptime = 0
        battery = 82
    }

    private static func roundToCenti(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
