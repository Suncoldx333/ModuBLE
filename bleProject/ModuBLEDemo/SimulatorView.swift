import SwiftUI
import ModuBLE

struct SimulatorView: View {
    @ObservedObject var coordinator: DeviceCoordinator

    @State private var latencyMilliseconds: Double = 0
    @State private var dropRate: Double = 0
    @State private var corruptRate: Double = 0
    @State private var malformedRate: Double = 0
    @State private var disconnectAfterRequests = false
    @State private var disconnectRequestCount = 3

    var body: some View {
        NavigationStack {
            Form {
                transportSection

                if coordinator.transportKind == .mock {
                    faultsSection
                    countersSection
                    dangerSection
                } else {
                    unavailableSection
                }
            }
            .navigationTitle("Simulator")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: load)
        }
    }

    // MARK: - Sections

    private var transportSection: some View {
        Section {
            Picker("Transport", selection: transportBinding) {
                ForEach(TransportKind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Transport")
        } footer: {
            Text("Switching transport disconnects the current device. Mock needs no hardware.")
        }
    }

    private var faultsSection: some View {
        Section {
            slider(
                title: "Latency",
                value: $latencyMilliseconds,
                range: 0...500,
                display: "\(Int(latencyMilliseconds)) ms"
            )
            slider(
                title: "Drop frame",
                value: $dropRate,
                range: 0...1,
                display: percent(dropRate)
            )
            slider(
                title: "Corrupt payload",
                value: $corruptRate,
                range: 0...1,
                display: percent(corruptRate)
            )
            slider(
                title: "Malformed header",
                value: $malformedRate,
                range: 0...1,
                display: percent(malformedRate)
            )

            Toggle("Disconnect after N requests", isOn: $disconnectAfterRequests)
            if disconnectAfterRequests {
                Stepper(
                    "Requests: \(disconnectRequestCount)",
                    value: $disconnectRequestCount,
                    in: 1...20
                )
            }
        } header: {
            Text("Fault injection")
        } footer: {
            Text("Dropping a frame makes the request time out. Corrupting the payload fails AEAD authentication. Damaging the header breaks reassembly. There is no CRC knob because the protocol has no CRC.")
        }
        .onChange(of: latencyMilliseconds) { _, _ in apply() }
        .onChange(of: dropRate) { _, _ in apply() }
        .onChange(of: corruptRate) { _, _ in apply() }
        .onChange(of: malformedRate) { _, _ in apply() }
        .onChange(of: disconnectAfterRequests) { _, _ in apply() }
        .onChange(of: disconnectRequestCount) { _, _ in apply() }
    }

    private var countersSection: some View {
        Section("Observed") {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let counters = coordinator.faultCounters
                VStack(spacing: 8) {
                    row("Dropped", counters.dropped)
                    Divider()
                    row("Corrupted", counters.corrupted)
                    Divider()
                    row("Malformed", counters.malformed)
                    Divider()
                    row("Disconnects", counters.disconnects)
                }
            }
        }
    }

    private var dangerSection: some View {
        Section {
            Button("Drop link now", role: .destructive) {
                coordinator.disconnectNow()
            }
            .disabled(coordinator.connectionState != .ready)

            Button("Clear faults") {
                reset()
            }
            .disabled(isClean)
        } footer: {
            Text("“Drop link now” simulates an unexpected disconnect; the app should enter its reconnect policy.")
        }
    }

    private var unavailableSection: some View {
        Section {
            Text("Fault injection is only available on the Mock transport.")
                .font(.subheadline)
            Button("Switch to Mock") {
                coordinator.selectTransport(.mock)
            }
        } header: {
            Text("CoreBluetooth selected")
        } footer: {
            Text("A real BLE link cannot be made to drop or corrupt frames on demand. Use the macOS peripheral and turn it off to exercise the disconnect path.")
        }
    }

    // MARK: - Controls

    private func slider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(display)
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func row(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .font(.body.monospacedDigit())
                .foregroundColor(value == 0 ? .secondary : .orange)
        }
    }

    private var transportBinding: Binding<TransportKind> {
        Binding(
            get: { coordinator.transportKind },
            set: { coordinator.selectTransport($0) }
        )
    }

    private var isClean: Bool {
        latencyMilliseconds == 0
            && dropRate == 0
            && corruptRate == 0
            && malformedRate == 0
            && !disconnectAfterRequests
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded())) %"
    }

    private func apply() {
        coordinator.faultConfiguration = FaultConfiguration(
            latency: .milliseconds(Int(latencyMilliseconds.rounded())),
            dropRate: dropRate,
            corruptRate: corruptRate,
            malformedRate: malformedRate,
            disconnectAfterRequests: disconnectAfterRequests ? disconnectRequestCount : nil,
            disconnectAfterEvents: coordinator.faultConfiguration.disconnectAfterEvents
        )
        coordinator.applyFaults()
    }

    private func load() {
        let faults = coordinator.faultConfiguration
        let seconds = Double(faults.latency.components.seconds)
            + Double(faults.latency.components.attoseconds) / 1e18
        latencyMilliseconds = seconds * 1000
        dropRate = faults.dropRate
        corruptRate = faults.corruptRate
        malformedRate = faults.malformedRate
        disconnectAfterRequests = faults.disconnectAfterRequests != nil
        disconnectRequestCount = faults.disconnectAfterRequests ?? 3
    }

    private func reset() {
        latencyMilliseconds = 0
        dropRate = 0
        corruptRate = 0
        malformedRate = 0
        disconnectAfterRequests = false
        apply()
    }
}
