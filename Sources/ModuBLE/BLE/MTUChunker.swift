import Foundation

/// Splits a payload into writes that fit the negotiated ATT MTU.
public enum MTUChunker {
    /// - Parameters:
    ///   - data: The logical payload.
    ///   - maxLength: Maximum bytes per write, normally
    ///     `CBPeripheral.maximumWriteValueLength(for:)`.
    /// - Returns: Non-empty chunks in order. Empty for empty input.
    public static func chunks(of data: Data, maxLength: Int) -> [Data] {
        guard !data.isEmpty else { return [] }
        guard maxLength > 0 else { return [data] }

        let bytes = [UInt8](data)
        var chunks: [Data] = []
        chunks.reserveCapacity((bytes.count + maxLength - 1) / maxLength)

        var offset = 0
        while offset < bytes.count {
            let end = Swift.min(offset + maxLength, bytes.count)
            chunks.append(Data(bytes[offset..<end]))
            offset = end
        }
        return chunks
    }
}
