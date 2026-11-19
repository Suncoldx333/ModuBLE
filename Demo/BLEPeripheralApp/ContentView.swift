import SwiftUI
import CoreBluetooth
import Foundation
import ModuBLE

struct ContentView: View {
    @ObservedObject var peripheralManager: PeripheralManager

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            controlPanel
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)

            ReceivedDataPanel(peripheralManager: peripheralManager)
                .frame(minWidth: 460)
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    // MARK: - Control panel

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                TextField("Device Name", text: deviceNameBinding)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit {
                        if peripheralManager.isAdvertising {
                            peripheralManager.stopAdvertising()
                            peripheralManager.startAdvertising()
                        }
                    }

                Text("This Mac is advertising itself as a Bluetooth Low Energy peripheral.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                HStack {
                    Text("State:")
                    stateBadge
                }
                .font(.callout)

                HStack {
                    Text("Advertising:")
                    Text(peripheralManager.isAdvertising ? "Yes" : "No")
                        .font(.callout.bold())
                }

                HStack {
                    Text("Status Subscribers:")
                    Text("\(peripheralManager.subscriberCount)")
                        .font(.callout.bold())
                }

                Divider()

                uuidBlock("Service UUID", PeripheralManager.serviceUUID.uuidString)
                uuidBlock("Data Characteristic UUID", PeripheralManager.characteristicUUID.uuidString)
                uuidBlock("Status Characteristic UUID (notify)", PeripheralManager.statusCharacteristicUUID.uuidString)

                Divider()

                diagnostics

                Divider()

                telemetryPanel

                Divider()

                Button(action: toggleAdvertising) {
                    Text(peripheralManager.isAdvertising ? "Stop Advertising" : "Start Advertising")
                        .frame(maxWidth: .infinity)
                }
                .disabled(peripheralManager.managerState != .poweredOn)

                Button {
                    peripheralManager.restartAdvertising()
                } label: {
                    Label("Force Restart Advertising", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(peripheralManager.managerState != .poweredOn)

                Button {
                    openWindow(id: "received-data")
                } label: {
                    Label("Open Received Data Window", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }

                if let error = peripheralManager.lastError {
                    Text("Error: \(error.localizedDescription)")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 34))
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("BLE Peripheral")
                    .font(.title3.bold())
                Text("Advertising as a BLE peripheral")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func uuidBlock(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }

    // MARK: - Diagnostics

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack {
                Text("Keep-awake")
                    .font(.caption)
                Spacer()
                Text(peripheralManager.keepAwakeActive ? "Active" : "Inactive")
                    .font(.caption.monospaced())
                    .foregroundColor(peripheralManager.keepAwakeActive ? .green : .secondary)
            }

            HStack {
                Text("Advertising watchdog")
                    .font(.caption)
                Spacer()
                Text("\(peripheralManager.advertisingRestartCount) restart(s)")
                    .font(.caption.monospaced())
                    .foregroundColor(peripheralManager.advertisingRestartCount == 0 ? .secondary : .orange)
            }

            HStack {
                Text("Last central activity")
                    .font(.caption)
                Spacer()
                Text(lastActivityText)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            if peripheralManager.advertisingRestartCount > 0 {
                Text("Advertising was dropped by the system and has been revived. If this keeps increasing, keep the Mac awake and plugged in.")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }

    private var lastActivityText: String {
        guard let date = peripheralManager.lastActivityAt else { return "none" }
        return date.formatted(date: .omitted, time: .standard)
    }

    // MARK: - Telemetry

    private var telemetryPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Telemetry")
                .font(.caption2)
                .foregroundColor(.secondary)

            HStack {
                Text("Streaming")
                    .font(.caption)
                Spacer()
                Text(peripheralManager.telemetryEnabled ? "Yes" : "No")
                    .font(.caption.monospaced())
                    .foregroundColor(peripheralManager.telemetryEnabled ? .green : .secondary)
            }

            HStack {
                Text("Rate")
                    .font(.caption)
                Spacer()
                Text("\(DemoPeripheralBehavior.format(peripheralManager.telemetryRate)) Hz")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Events sent")
                    .font(.caption)
                Spacer()
                Text("\(peripheralManager.eventsSent)")
                    .font(.caption.monospaced())
                    .foregroundColor(peripheralManager.eventsSent == 0 ? .secondary : .primary)
            }

            if let telemetry = peripheralManager.latestTelemetry {
                HStack {
                    Text("Yaw / Pitch / Roll")
                        .font(.caption)
                    Spacer()
                    Text(String(format: "%.1f / %.1f / %.1f",
                                telemetry.yaw, telemetry.pitch, telemetry.roll))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Battery")
                        .font(.caption)
                    Spacer()
                    Text("\(telemetry.battery) %")
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                }
            } else {
                Text("No samples yet. Send START from the iPhone, or start locally.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Button(peripheralManager.telemetryEnabled ? "Stop Telemetry" : "Start Telemetry") {
                peripheralManager.setTelemetryEnabled(!peripheralManager.telemetryEnabled)
            }
            .frame(maxWidth: .infinity)
            .disabled(peripheralManager.subscriberCount == 0)

            if peripheralManager.subscriberCount == 0 {
                Text("Waiting for a subscribed central.")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - Helpers

    private var deviceNameBinding: Binding<String> {
        Binding(
            get: { peripheralManager.localName },
            set: { peripheralManager.localName = $0 }
        )
    }

    private func toggleAdvertising() {
        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
        } else {
            peripheralManager.startAdvertising()
        }
    }

    private var stateBadge: some View {
        Text(stateDescription)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.2))
            .clipShape(Capsule())
    }

    private var stateDescription: String {
        if peripheralManager.managerState == .poweredOn {
            return "Powered On"
        }
        if peripheralManager.managerState == .poweredOff {
            return "Powered Off"
        }
        if peripheralManager.managerState == .unsupported {
            return "Unsupported"
        }
        if peripheralManager.managerState == .unauthorized {
            return "Unauthorized"
        }
        if peripheralManager.managerState == .resetting {
            return "Resetting"
        }
        return "Unknown"
    }
}
