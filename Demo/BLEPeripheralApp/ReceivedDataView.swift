import SwiftUI
import AppKit

/// Shows every received packet and the concatenation of everything received
/// since the last clear.
struct ReceivedDataPanel: View {
    @ObservedObject var peripheralManager: PeripheralManager

    @State private var format: FullMessageFormat = .hex

    enum FullMessageFormat: String, CaseIterable, Identifiable {
        case hex = "HEX"
        case utf8 = "UTF-8"
        case ascii = "ASCII"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            packetList
            Divider()
            fullMessageSection
        }
        .padding(20)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Received Packets")
                    .font(.headline)
                Text("\(peripheralManager.receivedPackets.count) packet(s) · \(peripheralManager.receivedStream.count) bytes total")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Clear") {
                peripheralManager.clearReceivedPackets()
            }
            .disabled(peripheralManager.receivedPackets.isEmpty)
        }
    }

    // MARK: - Packet list

    private var packetList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if peripheralManager.receivedPackets.isEmpty {
                    Text("Waiting for data from a connected BLE central…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                } else {
                    ForEach(Array(peripheralManager.receivedPackets.reversed())) { packet in
                        packetRow(packet)
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.secondary.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func packetRow(_ packet: PeripheralManager.ReceivedPacket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("#\(packet.sequence)")
                    .font(.caption.bold().monospaced())
                Text(packet.date.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(packet.data.count) B")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    copyToPasteboard(packet.hexString)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy this packet as HEX")
            }

            Text(packet.hexString)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let text = packet.text, !text.isEmpty {
                Text(text)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Full message

    private var fullMessageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Full Message")
                    .font(.headline)

                Text("\(peripheralManager.receivedStream.count) bytes")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Picker("Format", selection: $format) {
                    ForEach(FullMessageFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)

                Button {
                    copyToPasteboard(fullMessageText)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(peripheralManager.receivedStream.isEmpty)
            }

            ScrollView {
                Text(fullMessageText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 130)
            .background(Color.secondary.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("All bytes received since the last Clear, joined in arrival order.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Formatting

    private var fullMessageText: String {
        let stream = peripheralManager.receivedStream
        guard !stream.isEmpty else { return "No data received yet." }

        switch format {
        case .hex:
            return stream.map { String(format: "%02X", $0) }.joined(separator: " ")
        case .utf8:
            return String(data: stream, encoding: .utf8)
                ?? "The received bytes are not valid UTF-8. Switch to HEX or ASCII."
        case .ascii:
            return String(stream.map { byte in
                Character(UnicodeScalar(byte >= 32 && byte < 127 ? byte : 46))
            })
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
