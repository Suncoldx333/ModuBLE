import Foundation

/// One telemetry sample from the reference device.
///
/// This is **application data**, not transport data: the SDK carries it as the
/// payload of a `Packet.Kind.event` frame. Angles are stored in degrees; the
/// wire format uses signed centidegrees so a value round-trips exactly without
/// depending on floating-point byte order.
public struct Telemetry: Equatable, Sendable {
    /// Degrees, wrapped to `-180…180`.
    public var yaw: Double
    /// Degrees, `-90…90`.
    public var pitch: Double
    /// Degrees, `-180…180`.
    public var roll: Double
    /// Percent, `0…100`.
    public var battery: Int
    public var isCharging: Bool
    /// Milliseconds since the peripheral booted.
    public var uptimeMilliseconds: Int

    public init(
        yaw: Double = 0,
        pitch: Double = 0,
        roll: Double = 0,
        battery: Int = 100,
        isCharging: Bool = false,
        uptimeMilliseconds: Int = 0
    ) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.battery = battery
        self.isCharging = isCharging
        self.uptimeMilliseconds = uptimeMilliseconds
    }
}

public enum TelemetryError: Error, Equatable, Sendable {
    case truncated(expected: Int, actual: Int)
    case unsupportedVersion(UInt8)
    case unknownKind(UInt8)
    /// The angle cannot be represented as signed centidegrees.
    case angleOutOfRange(Double)
    case batteryOutOfRange(Int)
    case uptimeOutOfRange(Int)
}

/// Binary layout of the demo telemetry payload (big-endian):
///
/// ```text
/// Version (1) | Kind (1) | Yaw (2) | Pitch (2) | Roll (2)
///   | Battery (1) | Flags (1) | Uptime ms (4)        = 14 bytes
/// ```
///
/// Angles are signed centidegrees (`12.34° → 1234`), flags bit 0 is charging.
/// Trailing bytes are ignored so a future version can append fields.
public enum TelemetryCodec {
    public static let version: UInt8 = 0x01
    public static let kind: UInt8 = 0x01
    public static let payloadLength = 14

    private static let chargingFlag: UInt8 = 0x01

    public static func encode(_ telemetry: Telemetry) throws -> Data {
        let yaw = try centidegrees(telemetry.yaw)
        let pitch = try centidegrees(telemetry.pitch)
        let roll = try centidegrees(telemetry.roll)

        guard (0...100).contains(telemetry.battery) else {
            throw TelemetryError.batteryOutOfRange(telemetry.battery)
        }
        guard (0...Int(UInt32.max)).contains(telemetry.uptimeMilliseconds) else {
            throw TelemetryError.uptimeOutOfRange(telemetry.uptimeMilliseconds)
        }

        var data = Data(capacity: payloadLength)
        data.append(version)
        data.append(kind)
        data.appendBigEndian(yaw)
        data.appendBigEndian(pitch)
        data.appendBigEndian(roll)
        data.append(UInt8(telemetry.battery))
        data.append(telemetry.isCharging ? chargingFlag : 0)
        data.appendBigEndian(UInt32(telemetry.uptimeMilliseconds))
        return data
    }

    public static func decode(_ data: Data) throws -> Telemetry {
        let bytes = [UInt8](data)
        guard bytes.count >= payloadLength else {
            throw TelemetryError.truncated(expected: payloadLength, actual: bytes.count)
        }
        guard bytes[0] == version else {
            throw TelemetryError.unsupportedVersion(bytes[0])
        }
        guard bytes[1] == kind else {
            throw TelemetryError.unknownKind(bytes[1])
        }

        let yaw = Int16(bitPattern: UInt16(bytes[2]) << 8 | UInt16(bytes[3]))
        let pitch = Int16(bitPattern: UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
        let roll = Int16(bitPattern: UInt16(bytes[6]) << 8 | UInt16(bytes[7]))
        let battery = Int(bytes[8])
        let flags = bytes[9]
        let uptime = UInt32(bytes[10]) << 24
            | UInt32(bytes[11]) << 16
            | UInt32(bytes[12]) << 8
            | UInt32(bytes[13])

        return Telemetry(
            yaw: Double(yaw) / 100,
            pitch: Double(pitch) / 100,
            roll: Double(roll) / 100,
            battery: battery,
            isCharging: flags & chargingFlag != 0,
            uptimeMilliseconds: Int(uptime)
        )
    }

    private static func centidegrees(_ degrees: Double) throws -> Int16 {
        guard degrees.isFinite else { throw TelemetryError.angleOutOfRange(degrees) }
        let scaled = (degrees * 100).rounded()
        guard scaled >= Double(Int16.min), scaled <= Double(Int16.max) else {
            throw TelemetryError.angleOutOfRange(degrees)
        }
        return Int16(scaled)
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: Int16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }
}
