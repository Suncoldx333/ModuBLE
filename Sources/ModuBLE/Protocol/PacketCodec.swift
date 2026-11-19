import Foundation

public enum PacketError: Error, Equatable, Sendable {
    case payloadTooLarge(Int)
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownKind(UInt8)
    /// The bytes ended before the full header arrived.
    case truncatedHeader
    case truncatedPayload(expected: Int, available: Int)
}

/// Encodes and decodes a single `Packet`.
///
/// `PacketCodec` works on one complete frame. Use `PacketDecoder` when bytes
/// arrive in pieces, which is always the case over BLE.
public struct PacketCodec: Sendable {
    /// Upper bound accepted by `encode` / `decode`. Keeps a corrupted length
    /// field from making the decoder allocate unbounded memory.
    public static let maxPayloadLength = 4096

    public init() {}

    public func encode(_ packet: Packet) throws -> Data {
        guard packet.payload.count <= Self.maxPayloadLength else {
            throw PacketError.payloadTooLarge(packet.payload.count)
        }

        var data = Data(capacity: Packet.headerLength + packet.payload.count)
        data.append(contentsOf: Packet.magic)
        data.append(Packet.version)
        data.append(packet.kind.rawValue)
        data.appendBigEndian(packet.sequence)
        data.appendBigEndian(UInt16(packet.payload.count))
        data.append(packet.payload)
        return data
    }

    public func decode(_ data: Data) throws -> Packet {
        let bytes = [UInt8](data)
        guard bytes.count >= Packet.headerLength else {
            throw PacketError.truncatedHeader
        }
        guard bytes[0] == Packet.magic[0], bytes[1] == Packet.magic[1] else {
            throw PacketError.invalidMagic
        }
        guard bytes[2] == Packet.version else {
            throw PacketError.unsupportedVersion(bytes[2])
        }
        guard let kind = Packet.Kind(rawValue: bytes[3]) else {
            throw PacketError.unknownKind(bytes[3])
        }

        let sequence = UInt32(bytes[4]) << 24
            | UInt32(bytes[5]) << 16
            | UInt32(bytes[6]) << 8
            | UInt32(bytes[7])
        let length = Int(bytes[8]) << 8 | Int(bytes[9])

        guard length <= Self.maxPayloadLength else {
            throw PacketError.payloadTooLarge(length)
        }
        let available = bytes.count - Packet.headerLength
        guard available >= length else {
            throw PacketError.truncatedPayload(expected: length, available: available)
        }

        let payload = Data(bytes[Packet.headerLength..<(Packet.headerLength + length)])
        return Packet(kind: kind, sequence: sequence, payload: payload)
    }
}

/// Reassembles packets from an arbitrarily fragmented byte stream.
///
/// BLE delivers a `Data` blob per notification, and a single logical frame may
/// span several writes or notifications. `PacketDecoder` buffers until a whole
/// frame is present, and resynchronises on the magic bytes when it sees bytes
/// that cannot start a frame.
public struct PacketDecoder: Sendable {
    private var buffer: [UInt8] = []
    private let codec = PacketCodec()

    public init() {}

    /// Number of bytes currently waiting for the rest of their frame.
    public var bufferedByteCount: Int { buffer.count }

    /// Feeds newly received bytes and returns every frame that completed.
    public mutating func append(_ data: Data) throws -> [Packet] {
        buffer.append(contentsOf: data)
        var packets: [Packet] = []

        while true {
            // Drop bytes that cannot be the start of a frame.
            while buffer.count >= 2, buffer[0] != Packet.magic[0] || buffer[1] != Packet.magic[1] {
                buffer.removeFirst()
            }
            if buffer.count < Packet.headerLength {
                break
            }

            let length = Int(buffer[8]) << 8 | Int(buffer[9])
            guard length <= PacketCodec.maxPayloadLength else {
                // Unrecoverable header; drop the magic so the scanner resyncs.
                buffer.removeFirst(2)
                continue
            }
            let total = Packet.headerLength + length
            guard buffer.count >= total else {
                break
            }

            let frame = Data(buffer[0..<total])
            do {
                packets.append(try codec.decode(frame))
                buffer.removeFirst(total)
            } catch PacketError.unsupportedVersion(let version) {
                // The payload length of an unknown version cannot be trusted,
                // so the rest of the buffer is unusable.
                buffer.removeAll()
                throw PacketError.unsupportedVersion(version)
            } catch {
                // Bad kind or length: skip the magic and resync.
                buffer.removeFirst(2)
            }
        }

        return packets
    }

    public mutating func reset() {
        buffer.removeAll()
    }
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    mutating func appendBigEndian(_ value: UInt16) {
        append(contentsOf: [
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }
}
