import SwiftUI
import UIKit
import ModuBLE

struct LogsView: View {
    @ObservedObject var model: DemoModel

    var body: some View {
        NavigationStack {
            Group {
                if model.logEntries.isEmpty {
                    ContentUnavailableView(
                        "No traffic yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Connect, send a packet, or watch telemetry arrive.")
                    )
                } else {
                    List {
                        ForEach(Array(model.logEntries.reversed())) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Copy") {
                        UIPasteboard.general.string = model.logText
                    }
                    .disabled(model.logEntries.isEmpty)

                    Button("Clear") {
                        model.clearLog()
                    }
                    .disabled(model.logEntries.isEmpty)
                }
            }
        }
    }
}

struct LogEntryRow: View {
    let entry: CommunicationLog

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundColor(color)
                .font(.caption)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.message)
                        .font(.caption.bold())
                    Spacer(minLength: 4)
                    Text(entry.timestamp, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }

                if let payload = entry.payload, !payload.isEmpty {
                    Text(Self.payloadDescription(payload))
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        switch entry.category {
        case .transmit: return "arrow.up.circle.fill"
        case .receive: return "arrow.down.circle.fill"
        case .ble: return "antenna.radiowaves.left.and.right"
        case .gatt: return "square.stack.3d.up"
        case .transport: return "arrow.left.arrow.right"
        case .crypto: return "lock.fill"
        case .session: return "point.3.connected.trianglepath.dotted"
        case .demo: return "play.circle"
        @unknown default: return "circle"
        }
    }

    private var color: Color {
        if entry.category == .transmit { return .blue }
        if entry.category == .receive { return .green }
        switch entry.level {
        case .debug, .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private static func payloadDescription(_ data: Data) -> String {
        var lines = ["\(data.count) B · \(DemoModel.hexString(data))"]
        if let text = String(data: data, encoding: .utf8),
           !text.isEmpty,
           text.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) {
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }
}
