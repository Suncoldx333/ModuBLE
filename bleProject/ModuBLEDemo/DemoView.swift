import SwiftUI
import Foundation
import Combine
import UIKit
import ModuBLE

struct DemoView: View {
    @ObservedObject var model: DemoModel

    var body: some View {
        NavigationStack {
            Group {
                if model.discoveredDevices.isEmpty {
                    ContentUnavailableView {
                        Label(model.isScanning ? "Scanning…" : "No BLE Devices", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("Run BLEPeripheralApp on the Mac, then tap Scan.")
                    }
                } else {
                    deviceList
                }
            }
            .navigationTitle("BLE Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(model.isScanning ? "Stop" : "Scan") {
                        if model.isScanning {
                            model.stopScan()
                        } else {
                            model.startScan()
                        }
                    }
                    .disabled(!model.isBluetoothReady)
                }
            }
            .safeAreaInset(edge: .top) {
                if let problem = model.bluetoothProblem, !model.isBluetoothReady {
                    Text(problem)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(Color.orange.opacity(0.12))
                } else if model.isReconnecting || model.reconnectExhausted {
                    reconnectBanner
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let error = model.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.thinMaterial)
                }
            }
        }
        .alert("Reconnect Failed", isPresented: $model.reconnectExhausted) {
            Button("Reconnect Now") {
                model.reconnectManually()
            }
            Button("Cancel", role: .cancel) {
                model.cancelReconnection()
            }
        } message: {
            Text("Automatic reconnection failed after retries at 1, 2, 4, 8, 16 and 32 seconds. Make sure BLEPeripheralApp is running, then reconnect manually.")
        }
    }

    private var reconnectBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise")
                .foregroundColor(.orange)

            if let nextAttemptAt = model.reconnectNextAttemptAt {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    Text(String(
                        format: "Reconnecting %d/%d · next in %.1f s",
                        model.reconnectAttempt,
                        model.reconnectDelays.count,
                        max(0, nextAttemptAt.timeIntervalSince(context.date))
                    ))
                    .font(.caption)
                }
            } else if model.isReconnecting {
                Text("Reconnecting \(model.reconnectAttempt)/\(model.reconnectDelays.count) · connecting…")
                    .font(.caption)
            } else {
                Text("Reconnect failed · reconnect manually")
                    .font(.caption)
            }

            Spacer()

            if model.isReconnecting {
                Button("Stop") {
                    model.cancelReconnection()
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.12))
    }

    private var deviceList: some View {
        List {
            Section {
                ForEach(model.discoveredDevices) { device in
                    NavigationLink {
                        DeviceDetailView(model: model, device: device)
                    } label: {
                        DeviceRowView(
                            device: device,
                            isConnected: model.connectedDevice?.id == device.id
                                && model.connectionState == .ready,
                            isReconnecting: model.isReconnecting
                                && model.connectedDevice?.id == device.id
                        )
                    }
                }
            } footer: {
                Text("Tap a device to connect, send a custom packet and subscribe to its status.")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            model.stopScan()
            model.startScan()
        }
    }
}

struct DeviceRowView: View {
    let device: DemoModel.DiscoveredDevice
    let isConnected: Bool
    let isReconnecting: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.name ?? device.id.uuidString)
                    .font(.headline)
                    .lineLimit(1)

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

                if !device.advertisedServiceUUIDs.isEmpty {
                    Text(device.advertisedServiceUUIDs.joined(separator: ", "))
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
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

struct DeviceDetailView: View {
    @ObservedObject var model: DemoModel
    let device: DemoModel.DiscoveredDevice

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

    // MARK: - Sections

    private var isActiveDevice: Bool {
        model.connectedDevice?.id == device.id
    }

    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Text("State")
                Spacer()
                Text(model.isReconnecting ? "Reconnecting" : model.connectionState.label)
                    .foregroundColor(model.isReconnecting ? .orange : connectionColor)
            }

            if model.isReconnecting {
                reconnectRow
            }

            HStack {
                Text("Status Subscription")
                Spacer()
                Label(
                    model.isSubscribed ? "Active" : "Inactive",
                    systemImage: model.isSubscribed ? "bell.fill" : "bell.slash"
                )
                .foregroundColor(model.isSubscribed ? .green : .secondary)
            }

            HStack {
                Text("ATT MTU")
                Spacer()
                Text("\(model.attMTU) B · max write \(model.maxWritePayload) B")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }

            if model.connectionState.isBusy {
                Button("Cancel", role: .destructive) {
                    model.cancelConnect()
                }
            } else if isActiveDevice && model.connectionState == .ready {
                Button("Disconnect", role: .destructive) {
                    model.disconnect()
                }
            } else if model.isReconnecting {
                Button("Stop Reconnecting", role: .destructive) {
                    model.cancelReconnection()
                }
            } else {
                Button("Connect") {
                    model.connect(device)
                }
            }

            if let error = model.lastError {
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
                Text("Attempt \(model.reconnectAttempt)/\(model.reconnectDelays.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            if let nextAttemptAt = model.reconnectNextAttemptAt {
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

    // MARK: - Quick commands

    private var quickCommandSection: some View {
        Section {
            HStack(spacing: 10) {
                Button("START") {
                    model.sendText("START")
                }
                .buttonStyle(.borderedProminent)

                Button("PING") {
                    model.sendText("PING")
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .disabled(!isActiveDevice || model.connectionState != .ready || model.transferActive)
        } header: {
            Text("Quick Commands")
        } footer: {
            Text(
                model.useEncryption
                    ? "发送字面量 START / PING，经加密会话发出；外设回 START_ACK / PONG。"
                    : "Raw 模式：外设回的是纯文本状态串 RX #n。"
            )
        }
    }

    private var sendSection: some View {
        Section("Send Packet") {
            Picker("Algorithm", selection: $model.algorithm) {
                ForEach(CryptoAlgorithm.allCases, id: \.self) { algorithm in
                    Text(algorithm.shortName).tag(algorithm)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!model.useEncryption)
            .onChange(of: model.algorithm) { _, _ in
                model.applyAlgorithm()
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
        }
    }

    // MARK: - Chunk test

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
            .disabled(!isActiveDevice || model.connectionState != .ready || model.transferActive)
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

    // MARK: - Paced transfer

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
                .disabled(!isActiveDevice || model.connectionState != .ready)

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

    private var logSection: some View {
        Section {
            if model.logEntries.isEmpty {
                Text("No traffic yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(model.logEntries.reversed())) { entry in
                    logRow(entry)
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

    private func logRow(_ entry: CommunicationLog) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName(for: entry))
                .foregroundColor(color(for: entry))
                .font(.caption)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(entry.message)
                        .font(.caption.bold())
                    Spacer()
                    Text(entry.timestamp, style: .time)
                        .font(.caption2)
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

    private static func payloadDescription(_ data: Data) -> String {
        var lines = ["\(data.count) B · \(DemoModel.hexString(data))"]
        if let text = String(data: data, encoding: .utf8),
           !text.isEmpty,
           text.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }) {
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private var connectionColor: Color {
        switch model.connectionState {
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
        isActiveDevice
            && model.connectionState == .ready
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

    private func iconName(for entry: CommunicationLog) -> String {
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

    private func color(for entry: CommunicationLog) -> Color {
        if entry.category == .transmit { return .blue }
        if entry.category == .receive { return .green }
        switch entry.level {
        case .debug, .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func sendPacket() {
        guard let data = outgoingData, !data.isEmpty else {
            model.lastError = "Enter a valid non-empty payload."
            return
        }
        model.send(data, withResponse: useResponse)
    }
}
