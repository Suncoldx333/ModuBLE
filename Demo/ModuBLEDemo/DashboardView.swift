import SwiftUI
import ModuBLE

struct DashboardView: View {
    @ObservedObject var coordinator: DeviceCoordinator
    @State private var rate: Double = 1

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if !isReady {
                        ContentUnavailableView(
                            "No device connected",
                            systemImage: "gauge",
                            description: Text("Pick a device in the Devices tab, then start telemetry.")
                        )
                        .padding(.top, 80)
                    } else {
                        header
                        if let telemetry = coordinator.telemetry {
                            attitudeGrid(telemetry)
                            AttitudeBars(telemetry: telemetry)
                            statusCard(telemetry)
                        } else {
                            waitingCard
                        }
                        controls
                    }
                }
                .padding(16)
            }
            .navigationTitle("Dashboard")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var isReady: Bool {
        coordinator.connectionState == .ready && coordinator.connectedDevice != nil
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(coordinator.connectedDevice?.displayName ?? "Device")
                    .font(.headline)
                Text("\(coordinator.transportKind.label) · \(coordinator.connectionState.label)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if coordinator.isTelemetryRequested {
                Label("Streaming", systemImage: "waveform")
                    .font(.caption.bold())
                    .foregroundColor(.green)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func attitudeGrid(_ telemetry: Telemetry) -> some View {
        HStack(spacing: 10) {
            angleTile("Yaw", telemetry.yaw, color: .blue)
            angleTile("Pitch", telemetry.pitch, color: .orange)
            angleTile("Roll", telemetry.roll, color: .purple)
        }
    }

    private func angleTile(_ title: String, _ value: Double, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(String(format: "%.2f°", value))
                .font(.title3.monospacedDigit().bold())
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statusCard(_ telemetry: Telemetry) -> some View {
        VStack(spacing: 10) {
            row(
                "Battery",
                value: "\(telemetry.battery) %" + (telemetry.isCharging ? " · charging" : ""),
                systemImage: telemetry.isCharging ? "battery.100.bolt" : "battery.75"
            )
            Divider()
            row("Uptime", value: Self.uptime(telemetry.uptimeMilliseconds), systemImage: "clock")
            Divider()
            row("Events", value: "\(coordinator.eventCount)", systemImage: "waveform.path")
            Divider()
            row(
                "Last update",
                value: coordinator.lastTelemetryAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "—",
                systemImage: "arrow.down.circle"
            )
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ title: String, value: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private var waitingCard: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Connected, waiting for telemetry")
                .font(.subheadline)
            Text("Send START to ask the peripheral for samples.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    coordinator.startTelemetry()
                } label: {
                    Label("Start", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    coordinator.stopTelemetry()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Stepper(
                value: $rate,
                in: 0.2...10,
                step: 0.2
            ) {
                Text("Sample rate · \(String(format: "%g", rate)) Hz")
                    .font(.subheadline)
            }
            .onChange(of: rate) { _, newValue in
                coordinator.setTelemetryRate(newValue)
            }
            .onAppear {
                rate = coordinator.telemetryRate
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private static func uptime(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}

/// Three centred bars. Enough to show motion without a 3D sphere.
private struct AttitudeBars: View {
    let telemetry: Telemetry

    var body: some View {
        VStack(spacing: 10) {
            bar("Yaw", value: telemetry.yaw, limit: 180, color: .blue)
            bar("Pitch", value: telemetry.pitch, limit: 90, color: .orange)
            bar("Roll", value: telemetry.roll, limit: 180, color: .purple)
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func bar(_ title: String, value: Double, limit: Double, color: Color) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .leading)

            GeometryReader { geometry in
                let width = geometry.size.width
                let clamped = max(-limit, min(limit, value))
                let ratio = (clamped / limit + 1) / 2

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Rectangle()
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1)
                        .offset(x: width / 2)
                    Circle()
                        .fill(color)
                        .frame(width: 12, height: 12)
                        .offset(x: max(0, min(width - 12, ratio * width - 6)))
                }
            }
            .frame(height: 12)

            Text(String(format: "%+.1f", value))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
