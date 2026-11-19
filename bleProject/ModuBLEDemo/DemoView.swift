import SwiftUI
import Foundation
import UIKit
import ModuBLE

struct RootView: View {
    @ObservedObject var coordinator: DeviceCoordinator

    var body: some View {
        TabView {
            DiscoveryTab(coordinator: coordinator)
                .tabItem { Label("Devices", systemImage: "antenna.radiowaves.left.and.right") }

            DashboardView(coordinator: coordinator)
                .tabItem { Label("Dashboard", systemImage: "gauge") }

            LogsView(model: coordinator.diagnostics)
                .tabItem { Label("Logs", systemImage: "list.bullet.rectangle") }

            SimulatorView(coordinator: coordinator)
                .tabItem { Label("Simulator", systemImage: "slider.horizontal.3") }
        }
    }
}

// MARK: - Discovery

struct DiscoveryTab: View {
    @ObservedObject var coordinator: DeviceCoordinator

    var body: some View {
        NavigationStack {
            Group {
                if coordinator.devices.isEmpty {
                    ContentUnavailableView {
                        Label(
                            coordinator.isScanning ? "Scanning…" : "No BLE Devices",
                            systemImage: "dot.radiowaves.left.and.right"
                        )
                    } description: {
                        Text(emptyHint)
                    }
                } else {
                    deviceList
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(coordinator.isScanning ? "Stop" : "Scan") {
                        if coordinator.isScanning {
                            coordinator.stopScan()
                        } else {
                            coordinator.startScan()
                        }
                    }
                    .disabled(!coordinator.isBluetoothReady)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    transportPicker
                    if let problem = coordinator.bluetoothProblem, !coordinator.isBluetoothReady {
                        banner(problem, color: .orange)
                    } else if !coordinator.isBluetoothReady {
                        banner("Waiting for Bluetooth…", color: .orange)
                    } else if coordinator.isReconnecting || coordinator.reconnectExhausted {
                        reconnectBanner
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = coordinator.lastError, !coordinator.isReconnecting {
                    banner(error, color: .red)
                }
            }
        }
        .alert(
            "Reconnect Failed",
            isPresented: Binding(
                get: { coordinator.reconnectExhausted },
                set: { if !$0 { coordinator.cancelReconnection() } }
            )
        ) {
            Button("Reconnect Now") { coordinator.reconnectManually() }
            Button("Cancel", role: .cancel) { coordinator.cancelReconnection() }
        } message: {
            Text("Automatic reconnection failed after retries at 1, 2, 4, 8, 16 and 32 seconds. Make sure the peripheral is reachable, then reconnect manually.")
        }
    }

    private var emptyHint: String {
        switch coordinator.transportKind {
        case .mock:
            return "Tap Scan. Mock devices need no hardware."
        case .coreBluetooth:
            return "Run BLEPeripheralApp on the Mac, then tap Scan."
        }
    }

    private var transportPicker: some View {
        Picker(
            "Transport",
            selection: Binding(
                get: { coordinator.transportKind },
                set: { coordinator.selectTransport($0) }
            )
        ) {
            ForEach(TransportKind.allCases, id: \.self) { kind in
                Text(kind.label).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var deviceList: some View {
        List {
            Section {
                ForEach(coordinator.devices) { device in
                    NavigationLink {
                        DiagnosticsView(
                            coordinator: coordinator,
                            model: coordinator.diagnostics,
                            device: device
                        )
                    } label: {
                        DeviceRowView(
                            device: device,
                            source: coordinator.transportKind,
                            isConnected: coordinator.connectedDevice?.id == device.id
                                && coordinator.connectionState == .ready,
                            isReconnecting: coordinator.isReconnecting
                                && coordinator.connectedDevice?.id == device.id
                        )
                    }
                }
            } footer: {
                Text("Tap a device to connect, send a custom packet and watch its telemetry.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            coordinator.stopScan()
            coordinator.startScan()
        }
    }

    private var reconnectBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise")
                .foregroundColor(.orange)

            if let nextAttemptAt = coordinator.reconnectNextAttemptAt {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    Text(String(
                        format: "Reconnecting %d/%d · next in %.1f s",
                        coordinator.reconnectAttempt,
                        coordinator.reconnectDelays.count,
                        max(0, nextAttemptAt.timeIntervalSince(context.date))
                    ))
                    .font(.caption)
                }
            } else if coordinator.isReconnecting {
                Text("Reconnecting \(coordinator.reconnectAttempt)/\(coordinator.reconnectDelays.count) · connecting…")
                    .font(.caption)
            } else {
                Text("Reconnect failed · reconnect manually")
                    .font(.caption)
            }

            Spacer()

            if coordinator.isReconnecting {
                Button("Stop") { coordinator.cancelReconnection() }
                    .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.12))
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(color)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(color.opacity(0.12))
    }
}

struct DeviceRowView: View {
    let device: DiscoveredDevice
    let source: TransportKind
    let isConnected: Bool
    let isReconnecting: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name ?? device.id.uuidString)
                        .font(.headline)
                        .lineLimit(1)

                    Text(source.label)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .clipShape(Capsule())
                }

                if isReconnecting {
                    Text("Reconnecting…")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                Text(device.id.uuidString)
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                Text("RSSI \(device.rssi) dBm")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(rssiColor)

                if device.isConnectable == false {
                    Label("Not connectable", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.bold())
                        .foregroundColor(.red)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        if isReconnecting { return "arrow.clockwise.circle.fill" }
        return isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right.circle"
    }

    private var iconColor: Color {
        if isReconnecting { return .orange }
        return isConnected ? .green : .accentColor
    }

    private var rssiColor: Color {
        switch device.rssi {
        case ..<(-85): return .red
        case ..<(-70): return .orange
        default: return .secondary
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsView: View {
    @ObservedObject var coordinator: DeviceCoordinator
    @ObservedObject var model: DemoModel
    let device: DiscoveredDevice

    @State private var payload = "Hello from ModuBLEDemo"
    @State private var isHexInput = false
    @State private var useResponse = true
    @State private var chunkTestBytes = 1000

    var body: some View {
        List {
            connectionSection
            quickCommandSection
            sendSection
            chunkTestSection
            transferSection
            logSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(device.name ?? "Device")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isActiveDevice: Bool {
        coordinator.connectedDevice?.id == device.id
    }

    private var isReady: Bool {
        isActiveDevice && coordinator.connectionState == .ready
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Text("State")
                Spacer()
                Text(coordinator.isReconnecting ? "Reconnecting" : coordinator.connectionState.label)
                    .foregroundColor(coordinator.isReconnecting ? .orange : connectionColor)
            }

            if coordinator.isReconnecting {
                reconnectRow
            }

            HStack {
                Text("Encrypted session")
                Spacer()
                Label(
                    isReady ? "Ready" : "Inactive",
                    systemImage: isReady ? "lock.fill" : "lock.slash"
                )
                .foregroundColor(isReady ? .green : .secondary)
            }

            HStack {
                Text("ATT MTU")
                Spacer()
                Text("\(model.attMTU) B · max write \(model.maxWritePayload) B")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            if coordinator.connectionState.isBusy && isActiveDevice {
                Button("Cancel", role: .destructive) {
                    coordinator.cancelConnect()
                }
            } else if isReady {
                Button("Disconnect", role: .destructive) {
                    coordinator.disconnect()
                }
            } else if coordinator.isReconnecting {
                Button("Stop Reconnecting", role: .destructive) {
                    coordinator.cancelReconnection()
                }
            } else if coordinator.connectedDevice != nil {
                Text("Disconnect the current device before connecting to this one.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Button("Connect") {
                    coordinator.connect(device)
                }
            }

            if let error = coordinator.lastError, isActiveDevice {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    private var reconnectRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Label("Auto-reconnect", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundColor(.orange)
                Spacer()
                Text("Attempt \(coordinator.reconnectAttempt)/\(coordinator.reconnectDelays.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            if let nextAttemptAt = coordinator.reconnectNextAttemptAt {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    Text(String(format: "Next attempt in %.1f s", max(0, nextAttemptAt.timeIntervalSince(context.date))))
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.orange)
                }
            } else {
                Text("Connecting…")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 1)
    }

    // MARK: Quick commands

    private var quickCommandSection: some View {
        Section {
            HStack(spacing: 10) {
                Button("START") { model.sendText("START") }
                    .buttonStyle(.borderedProminent)
                Button("STOP") { model.sendText("STOP") }
                    .buttonStyle(.bordered)
                Button("PING") { model.sendText("PING") }
                    .buttonStyle(.bordered)
                Spacer()
            }
            .disabled(!isReady || model.transferActive)
        } header: {
            Text("Quick Commands")
        } footer: {
            Text(
                model.useEncryption
                    ? "发送 START / STOP / PING，经加密会话发出；Mock 与参考外设返回 *_ACK / PONG。"
                    : "Raw 模式：外设回的是纯文本状态串 RX #n。"
            )
        }
    }

    // MARK: Send

    private var sendSection: some View {
        Section("Send Packet") {
            Picker("Algorithm", selection: $coordinator.algorithm) {
                ForEach(CryptoAlgorithm.allCases, id: \.self) { algorithm in
                    Text(algorithm.shortName).tag(algorithm)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!model.useEncryption)
            .onChange(of: coordinator.algorithm) { _, _ in
                coordinator.applyAlgorithm()
            }

            Picker("Transport", selection: $model.useEncryption) {
                Text("Encrypted").tag(true)
                Text("Raw").tag(false)
            }
            .pickerStyle(.segmented)

            Picker("Format", selection: $isHexInput) {
                Text("UTF-8").tag(false)
                Text("HEX").tag(true)
            }
            .pickerStyle(.segmented)

            TextField(
                isHexInput ? "48 65 6C 6C 6F" : "Text payload",
                text: $payload,
                axis: .vertical
            )
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(1...4)

            Picker("Write Type", selection: $useResponse) {
                Text("With Response").tag(true)
                Text("Without Response").tag(false)
            }
            .pickerStyle(.segmented)
            .disabled(model.useEncryption)

            if model.useEncryption {
                Text("Encrypted mode seals the payload and always writes with response. The peripheral replies with a sealed frame.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Payload Size")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                payloadInfo
            }

            Button {
                sendPacket()
            } label: {
                Label(
                    model.useEncryption ? "Send Encrypted Request" : "Send Packet",
                    systemImage: model.useEncryption ? "lock.fill" : "paperplane.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)

            if let response = model.lastResponse {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last Decrypted Response")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(Self.payloadDescription(response))
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: Chunk test

    private var chunkTestSection: some View {
        Section {
            Stepper(
                "Payload: \(chunkTestBytes) B",
                value: $chunkTestBytes,
                in: 100...2000,
                step: 100
            )

            HStack {
                Text("Plan")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(model.plannedWrites(for: chunkTestBytes)) ATT write(s)")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            Button {
                model.sendChunkTest(bytes: chunkTestBytes)
            } label: {
                Label("Send \(chunkTestBytes) B (auto-chunked)", systemImage: "square.stack.3d.up.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!isReady || model.transferActive)
        } header: {
            Text("Chunk Test")
        } footer: {
            if model.plannedWrites(for: chunkTestBytes) == 1 {
                Text("This fits in a single ATT write (max \(model.maxWritePayload) B), so no chunking happens. Raise the payload above \(model.maxWritePayload) B to exercise MTUChunker.")
            } else {
                Text("Payload is 00 01 02 … FF repeating. The SDK splits it at the negotiated MTU; each chunk appears as its own TX entry in the log.")
            }
        }
    }

    // MARK: Paced transfer

    private var transferSection: some View {
        Section {
            Stepper(
                "Payload: \(model.transferTotalBytes) B",
                value: $model.transferTotalBytes,
                in: 100...2000,
                step: 100
            )
            .disabled(model.transferActive)

            Stepper(
                "Packet size: \(model.transferChunkSize) B",
                value: $model.transferChunkSize,
                in: 20...200,
                step: 20
            )
            .disabled(model.transferActive)

            HStack {
                Text("Plan")
                Spacer()
                Text("\(model.plannedChunkSize) B × \(model.plannedPacketCount) packets")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            if !model.transferPackets.isEmpty {
                transferProgressView
            }

            if model.transferActive {
                Button("Stop Transfer", role: .destructive) {
                    model.stopPacedTransfer()
                }
            } else {
                Button {
                    model.startPacedTransfer()
                } label: {
                    Label("Start \(model.transferTotalBytes) B Transfer", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isReady)

                if !model.transferPackets.isEmpty {
                    Button("Reset Transfer") {
                        model.resetTransfer()
                    }
                }
            }

            ForEach(model.transferPackets) { packet in
                transferRow(packet)
            }
        } header: {
            Text("Paced Transfer · raw writes, with response · every \(Int(model.transferInterval)) s")
        }
    }

    private var transferProgressView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(model.transferSentBytes) / \(model.transferTotalBytes) B")
                    .font(.caption.monospaced())
                Spacer()
                Text("\(Int((model.transferProgress * 100).rounded()))%")
                    .font(.caption.bold())
            }

            ProgressView(value: model.transferProgress)
                .tint(model.transferFinished ? .green : .blue)

            if model.transferActive {
                if let nextSendAt = model.transferNextSendAt {
                    TimelineView(.periodic(from: .now, by: 0.1)) { context in
                        Text(String(format: "Next packet in %.1f s", max(0, nextSendAt.timeIntervalSince(context.date))))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Awaiting write response…")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            } else if model.transferFinished {
                Text("Transfer complete")
                    .font(.caption2)
                    .foregroundColor(.green)
            } else if let error = model.transferError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func transferRow(_ packet: DemoModel.TransferPacket) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("#\(packet.index)")
                .font(.caption.monospaced())
                .frame(width: 34, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(packet.data.count) B · offset \(packet.byteRange)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(DemoModel.hexString(packet.data))
                    .font(.caption2.monospaced())
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(transferStatusText(packet.status))
                    .font(.caption2.bold())
                    .foregroundColor(transferStatusColor(packet.status))
                if let latency = packet.latencyMilliseconds {
                    Text("\(latency) ms")
                        .font(.caption2.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 1)
    }

    private func transferStatusText(_ status: DemoModel.TransferPacket.Status) -> String {
        switch status {
        case .pending: return "Pending"
        case .writing: return "Writing"
        case .acknowledged: return "ACK"
        case .failed: return "Failed"
        }
    }

    private func transferStatusColor(_ status: DemoModel.TransferPacket.Status) -> Color {
        switch status {
        case .pending: return .secondary
        case .writing: return .orange
        case .acknowledged: return .green
        case .failed: return .red
        }
    }

    // MARK: Log

    private var logSection: some View {
        Section {
            if model.logEntries.isEmpty {
                Text("No traffic yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(model.logEntries.reversed().prefix(60))) { entry in
                    LogEntryRow(entry: entry)
                }
            }
        } header: {
            HStack {
                Text("Log (\(model.logEntries.count))")
                Spacer()
                Button("Copy") {
                    UIPasteboard.general.string = model.logText
                }
                .font(.caption)
                .disabled(model.logEntries.isEmpty)
                Button("Clear") {
                    model.clearLog()
                }
                .font(.caption)
                .disabled(model.logEntries.isEmpty)
            }
        }
    }

    // MARK: Helpers

    private var connectionColor: Color {
        switch coordinator.connectionState {
        case .ready: return .green
        case .connecting, .discovering: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

    private var outgoingData: Data? {
        if isHexInput {
            return DemoModel.data(fromHex: payload)
        }
        return payload.data(using: .utf8)
    }

    private var canSend: Bool {
        isReady
            && !model.transferActive
            && !(outgoingData?.isEmpty ?? true)
    }

    @ViewBuilder
    private var payloadInfo: some View {
        if isHexInput && outgoingData == nil {
            Text("Invalid HEX")
                .font(.caption)
                .foregroundColor(.red)
        } else {
            Text("\(outgoingData?.count ?? 0) bytes")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func sendPacket() {
        guard let data = outgoingData, !data.isEmpty else {
            model.lastError = "Enter a valid non-empty payload."
            return
        }
        model.send(data, withResponse: useResponse)
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
