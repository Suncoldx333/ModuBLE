import Foundation
import Combine
import ModuBLE

/// Demo view model.
///
/// Every byte that touches the radio goes through `ModuBLE`. This type only owns
/// presentation state, the paced-transfer feature and the reconnect policy —
/// things that belong to the demo, not to the SDK.
///
/// `@unchecked Sendable` is deliberate: async work reads only immutable
/// configuration (`profile`, `central`) and funnels every `@Published` mutation
/// through `onMain(_:)`.
final class DemoModel: ObservableObject, @unchecked Sendable {
    typealias DiscoveredDevice = ModuBLE.DiscoveredDevice
    typealias ConnectionState = ModuBLE.ConnectionState
    typealias LogEntry = CommunicationLog

    // MARK: - Models kept for the existing UI

    struct TransferPacket: Identifiable {
        enum Status: Equatable {
            case pending
            case writing
            case acknowledged
            case failed
        }

        let id = UUID()
        let index: Int
        let offset: Int
        let data: Data
        var status: Status = .pending
        var sentAt: Date?
        var acknowledgedAt: Date?
        var errorMessage: String?

        var byteRange: String {
            "\(offset)…\(offset + data.count - 1)"
        }

        var latencyMilliseconds: Int? {
            guard let sentAt, let acknowledgedAt else { return nil }
            return Int((acknowledgedAt.timeIntervalSince(sentAt) * 1000).rounded())
        }
    }

    // MARK: - Published state

    @Published var isBluetoothReady = false
    @Published var bluetoothProblem: String?
    @Published var isScanning = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectionState: ConnectionState = .disconnected
    @Published var connectedDevice: DiscoveredDevice?
    @Published var isSubscribed = false
    @Published var lastError: String?
    @Published var logEntries: [CommunicationLog] = []
    @Published var useEncryption = true
    @Published var algorithm: CryptoAlgorithm = .aes128GCM
    @Published var lastResponse: Data?

    // MARK: - Auto-reconnect state

    /// Delays between reconnect attempts: 1, 2, 4, 8, 16, 32 seconds.
    let reconnectDelays: [TimeInterval] = [1, 2, 4, 8, 16, 32]
    @Published var isReconnecting = false
    @Published var reconnectAttempt = 0
    @Published var reconnectNextAttemptAt: Date?
    @Published var reconnectExhausted = false

    // MARK: - Paced transfer state

    @Published var transferTotalBytes = 500
    /// Logical packet size; the SDK still splits it to the negotiated MTU.
    @Published var transferChunkSize = 100
    @Published var transferActive = false
    @Published var transferFinished = false
    @Published var transferSentBytes = 0
    @Published var transferPackets: [TransferPacket] = []
    @Published var transferNextSendAt: Date?
    @Published var transferEffectiveChunkSize = 0
    @Published var transferError: String?

    let transferInterval: TimeInterval = 3

    // MARK: - SDK

    private let profile = GATTProfile.referencePeripheral
    private let logStore = CommunicationLogStore(capacity: 300)
    private lazy var central = BLECentralManager(logStore: logStore)

    private var connection: BLEConnection?
    private var session: EncryptedSession?
    private var reconnectTargetDevice: DiscoveredDevice?

    private var scanTask: Task<Void, Never>?
    private var bluetoothStateTask: Task<Void, Never>?
    private var connectionStateTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var scanGeneration = 0
    private var userInitiatedDisconnect = false
    private var hadSuccessfulConnection = false

    // MARK: - Init

    init() {
        logStore.setAppendHandler { [weak self] entry in
            // Main queue keeps the SDK's append order, unlike unordered Tasks.
            DispatchQueue.main.async { self?.receive(entry) }
        }
        #if DEBUG
        logStore.setMirrorsToConsole(true)
        #endif
        startBluetoothStateObservation()
    }

    /// Full session log, one line per entry, for copying into a bug report.
    var logText: String {
        logStore.textDump()
    }

    // MARK: - Bluetooth state

    private func startBluetoothStateObservation() {
        let states = central.observeBluetoothState()
        bluetoothStateTask = Task { [weak self] in
            for await state in states {
                guard let self else { return }
                self.onMain {
                    self.isBluetoothReady = state.isReady
                    self.bluetoothProblem = state.problemDescription
                    if state.isReady { self.lastError = nil }
                }
            }
        }
    }

    // MARK: - Scanning

    func startScan() {
        guard isBluetoothReady else { return }

        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        lastError = nil

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                // The SDK stops any previous scan before installing this stream.
                let stream = try await self.central.scan(profile: self.profile)
                for try await snapshot in stream {
                    self.onMain { self.discoveredDevices = snapshot }
                }
            } catch {
                self.onMain { self.lastError = Self.describe(error) }
            }
            self.onMain {
                guard self.scanGeneration == generation else { return }
                self.isScanning = false
                self.scanTask = nil
            }
        }
    }

    func stopScan() {
        scanGeneration += 1
        isScanning = false
        scanTask = nil
        Task { [weak self] in await self?.central.stopScan() }
    }

    // MARK: - Connecting

    func connect(_ device: DiscoveredDevice) {
        guard connection == nil else {
            lastError = "Disconnect from the current peripheral first."
            return
        }

        cancelReconnection()
        userInitiatedDisconnect = false
        connectionState = .connecting
        lastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let newConnection = try await self.central.connect(device, profile: self.profile)
                self.onMain { self.attach(newConnection, device: device) }
            } catch {
                let message = Self.describe(error)
                self.onMain {
                    if let ble = error as? BLEError, ble == .cancelled {
                        self.connectionState = .disconnected
                        return
                    }
                    self.connectionState = .failed(message)
                    self.lastError = message
                }
            }
        }
    }

    /// Abandons an in-flight connection attempt.
    func cancelConnect() {
        connectionState = .disconnected
        Task { [weak self] in await self?.central.cancelPendingConnection() }
    }

    func disconnect() {
        cancelReconnection()
        userInitiatedDisconnect = true

        guard let connection else {
            resetConnectionState()
            return
        }
        Task { await connection.close() }
    }

    func reconnectManually() {
        reconnectExhausted = false
        guard let device = connectedDevice ?? reconnectTargetDevice else { return }
        connect(device)
    }

    /// Stops the automatic reconnect loop and returns to the idle state.
    func cancelReconnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        reconnectNextAttemptAt = nil
        reconnectExhausted = false
        reconnectTargetDevice = nil
        isReconnecting = false
    }

    // MARK: - Sending

    func send(_ data: Data, withResponse: Bool) {
        lastResponse = nil
        guard !data.isEmpty else {
            lastError = "Packet is empty."
            return
        }
        guard let connection, connectionState == .ready else {
            lastError = "Connect to a peripheral before sending data."
            return
        }
        guard !transferActive else {
            lastError = "A paced transfer is running. Stop it before sending manually."
            return
        }

        let mode: GATTProfile.WriteMode = withResponse ? .withResponse : .withoutResponse

        if useEncryption {
            guard let session else {
                lastError = "The encrypted session is not ready yet."
                return
            }
            Task { [weak self] in
                do {
                    let reply = try await session.request(data)
                    self?.onMain { self?.lastResponse = reply }
                } catch let error as SessionError {
                    self?.onMain { self?.lastError = Self.describe(error) }
                } catch {
                    self?.onMain { self?.lastError = error.localizedDescription }
                }
            }
            return
        }

        Task { [weak self] in
            do {
                try await connection.write(data, mode: mode)
            } catch {
                self?.onMain { self?.lastError = Self.describe(error) }
            }
        }
    }

    func clearLog() {
        logStore.clear()
        logEntries.removeAll()
    }

    /// Sends a fixed command string through whatever transport is selected.
    func sendText(_ text: String) {
        send(Data(text.utf8), withResponse: true)
    }

    /// Rebuilds the provider and hands it to the live session.
    func applyAlgorithm() {
        guard let session else { return }
        do {
            session.updateCrypto(try makeProvider(for: algorithm))
        } catch {
            lastError = "Could not create the crypto provider."
        }
    }

    private func makeProvider(for algorithm: CryptoAlgorithm) throws -> any CryptoProvider {
        switch algorithm {
        case .aes128GCM:
            return try AESGCMProvider(key: DemoTestKey.aes128GCM)
        case .aes128CBCHMAC:
            return try AESCBCProvider(key: DemoTestKey.aes128CBCHMAC)
        }
    }

    /// Sends a deterministic payload big enough to span several ATT writes.
    /// `00 01 02 … FF` repeats, so the Mac side is trivial to verify.
    func sendChunkTest(bytes: Int) {
        let count = max(1, bytes)
        let payload = Data((0..<count).map { UInt8($0 & 0xFF) })
        send(payload, withResponse: true)
    }

    /// How many ATT writes a payload of this size will produce right now.
    func plannedWrites(for bytes: Int) -> Int {
        let payload = max(1, connection?.maximumWritePayloadLength ?? 20)
        return Int(ceil(Double(max(1, bytes)) / Double(payload)))
    }

    /// Largest payload the stack accepts per write for the current connection.
    var maxWritePayload: Int {
        connection?.maximumWritePayloadLength ?? 20
    }

    /// Real ATT MTU, derived from the write-command payload limit.
    var attMTU: Int {
        (connection?.maximumWritePayloadLengthWithoutResponse ?? 20) + 3
    }

    // MARK: - Paced transfer

    var plannedChunkSize: Int {
        let mtuPayload = connection?.maximumWritePayloadLength ?? 20
        return max(1, min(transferChunkSize, mtuPayload))
    }

    var plannedPacketCount: Int {
        let total = max(1, transferTotalBytes)
        return Int(ceil(Double(total) / Double(plannedChunkSize)))
    }

    var transferProgress: Double {
        guard transferTotalBytes > 0 else { return 0 }
        return min(1, Double(transferSentBytes) / Double(transferTotalBytes))
    }

    func startPacedTransfer() {
        guard !transferActive else { return }
        guard let connection, connectionState == .ready else {
            lastError = "Connect to a peripheral before starting a transfer."
            return
        }

        let total = max(1, transferTotalBytes)
        let chunkSize = plannedChunkSize
        // Deterministic payload: 00 01 02 … FF, repeating.
        let payload = Data((0..<total).map { UInt8($0 & 0xFF) })

        var packets: [TransferPacket] = []
        var offset = 0
        var index = 0
        while offset < payload.count {
            let end = min(offset + chunkSize, payload.count)
            packets.append(
                TransferPacket(index: index, offset: offset, data: payload.subdata(in: offset..<end))
            )
            offset = end
            index += 1
        }

        transferPackets = packets
        transferEffectiveChunkSize = chunkSize
        transferSentBytes = 0
        transferActive = true
        transferFinished = false
        transferError = nil
        transferNextSendAt = nil
        lastError = nil

        logStore.append(
            CommunicationLog(
                level: .info,
                category: .demo,
                message: "Transfer started · \(total) B · \(packets.count) packets · \(chunkSize) B/packet"
            )
        )

        let plan = packets
        transferTask = Task { [weak self] in
            guard let self else { return }
            for (index, packet) in plan.enumerated() {
                guard !Task.isCancelled else { return }

                self.onMain {
                    guard self.transferPackets.indices.contains(index) else { return }
                    self.transferPackets[index].status = .writing
                    self.transferPackets[index].sentAt = Date()
                    self.transferNextSendAt = nil
                }

                do {
                    try await connection.write(packet.data)
                } catch {
                    let message = Self.describe(error)
                    self.onMain {
                        guard self.transferPackets.indices.contains(index) else { return }
                        self.transferPackets[index].status = .failed
                        self.transferPackets[index].errorMessage = message
                        self.transferError = message
                        self.lastError = message
                        self.stopPacedTransfer(logMessage: false)
                    }
                    return
                }

                self.onMain {
                    guard self.transferPackets.indices.contains(index) else { return }
                    self.transferPackets[index].status = .acknowledged
                    self.transferPackets[index].acknowledgedAt = Date()
                    self.transferSentBytes += packet.data.count
                }

                guard index < plan.count - 1 else { continue }
                self.onMain {
                    self.transferNextSendAt = Date().addingTimeInterval(self.transferInterval)
                }
                try? await Task.sleep(nanoseconds: UInt64(self.transferInterval * 1_000_000_000))
            }

            self.onMain { self.finishTransfer() }
        }
    }

    func stopPacedTransfer() {
        stopPacedTransfer(logMessage: true)
    }

    func resetTransfer() {
        stopPacedTransfer(logMessage: false)
        transferPackets.removeAll()
        transferSentBytes = 0
        transferFinished = false
        transferError = nil
        transferEffectiveChunkSize = 0
    }

    // MARK: - Private helpers

    /// Runs on the main thread; `@Published` mutations must stay ordered.
    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    private func receive(_ entry: CommunicationLog) {
        logEntries.append(entry)
        if logEntries.count > 300 {
            logEntries.removeFirst(logEntries.count - 300)
        }
    }

    private func attach(_ connection: BLEConnection, device: DiscoveredDevice) {
        self.connection = connection
        connectedDevice = device
        connectionState = .ready
        isSubscribed = connection.state == .ready
        hadSuccessfulConnection = true
        userInitiatedDisconnect = false
        lastError = nil
        lastResponse = nil

        do {
            // TEST KEYS ONLY — see ModuBLE.DemoTestKey.
            session = EncryptedSession(
                link: connection,
                crypto: try makeProvider(for: algorithm),
                timeout: .seconds(6),
                logStore: logStore
            )
        } catch {
            session = nil
            lastError = "Could not create the crypto provider."
        }

        connectionStateTask = Task { [weak self] in
            // Do NOT drain connection.inbound here: it is a single-consumer
            // stream and EncryptedSession owns it. Observe phase changes instead.
            for await state in connection.observeState() {
                guard let self else { return }
                switch state {
                case .failed, .disconnected:
                    self.onMain { self.handleConnectionEnded(connection) }
                    return
                case .ready, .connecting, .discovering:
                    continue
                }
            }
        }
    }

    private func handleConnectionEnded(_ ended: BLEConnection) {
        guard connection === ended else { return }

        stopPacedTransfer(logMessage: false)
        connection = nil
        session = nil
        connectionStateTask = nil
        isSubscribed = false

        let device = connectedDevice
        connectedDevice = nil

        let wasUserInitiated = userInitiatedDisconnect
        userInitiatedDisconnect = false
        let finalState = ended.state

        if wasUserInitiated {
            hadSuccessfulConnection = false
            connectionState = .disconnected
            return
        }

        connectionState = finalState
        if case .failed(let reason) = finalState {
            lastError = reason
        }

        if let device, hadSuccessfulConnection {
            startAutoReconnect(for: device)
        }
    }

    private func resetConnectionState() {
        connection = nil
        connectedDevice = nil
        isSubscribed = false
        hadSuccessfulConnection = false
        connectionState = .disconnected
    }

    private func finishTransfer() {
        transferTask = nil
        transferNextSendAt = nil
        transferActive = false
        transferFinished = true
        logStore.append(
            CommunicationLog(
                level: .info,
                category: .demo,
                message: "Transfer complete · \(transferSentBytes)/\(transferTotalBytes) B"
            )
        )
    }

    private func stopPacedTransfer(logMessage: Bool) {
        transferTask?.cancel()
        transferTask = nil
        transferNextSendAt = nil

        if transferActive, logMessage {
            logStore.append(
                CommunicationLog(
                    level: .info,
                    category: .demo,
                    message: "Transfer stopped · \(transferSentBytes)/\(transferTotalBytes) B sent"
                )
            )
        }
        transferActive = false
    }

    // MARK: - Auto-reconnect

    private func startAutoReconnect(for device: DiscoveredDevice) {
        reconnectTask?.cancel()
        reconnectTargetDevice = device
        connectedDevice = device

        isReconnecting = true
        reconnectExhausted = false
        reconnectAttempt = 0
        reconnectNextAttemptAt = nil
        connectionState = .disconnected

        logStore.append(
            CommunicationLog(
                level: .info,
                category: .ble,
                message: "Auto-reconnect started · delays 1, 2, 4, 8, 16, 32 s"
            )
        )

        reconnectTask = Task { [weak self] in
            guard let self else { return }

            for (index, delay) in self.reconnectDelays.enumerated() {
                guard !Task.isCancelled else { return }
                self.onMain {
                    self.reconnectAttempt = index + 1
                    self.reconnectNextAttemptAt = Date().addingTimeInterval(delay)
                }

                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.onMain { self.reconnectNextAttemptAt = nil }

                do {
                    let newConnection = try await self.central.connect(device, profile: self.profile)
                    self.onMain {
                        self.reconnectTask = nil
                        self.reconnectTargetDevice = nil
                        self.isReconnecting = false
                        self.attach(newConnection, device: device)
                    }
                    return
                } catch {
                    self.onMain { self.lastError = Self.describe(error) }
                }
            }

            self.onMain {
                self.reconnectTask = nil
                self.isReconnecting = false
                self.reconnectAttempt = self.reconnectDelays.count
                self.reconnectExhausted = true
                self.connectionState = .disconnected
                self.lastError = "All automatic reconnect attempts failed."
            }
        }
    }
}

// MARK: - Error presentation

extension DemoModel {
    static func describe(_ error: SessionError) -> String {
        switch error {
        case .busy:
            return "Another encrypted request is still waiting for its response."
        case .timedOut:
            return "The peripheral did not answer the encrypted request in time."
        case .payloadTooLarge(let max):
            return "Payload is too large for the current cipher (max \(max) B per request)."
        case .closed:
            return "The encrypted session is closed."
        case .unexpectedResponse(let expected, let received):
            return "Response #\(received) does not match request #\(expected)."
        case .crypto(.authenticationFailed):
            return "Response failed authentication: tampered, or the two sides use different keys."
        case .crypto(let reason):
            return "Crypto error: \(reason)"
        case .framing(let reason):
            return "Framing error: \(reason)"
        case .transport(let reason):
            return describe(reason)
        }
    }
}

extension DemoModel {
    static func describe(_ error: Error) -> String {
        guard let ble = error as? BLEError else {
            return error.localizedDescription
        }
        switch ble {
        case .bluetoothOff:
            return "Bluetooth is off."
        case .bluetoothUnauthorized:
            return "Bluetooth permission was denied."
        case .bluetoothUnsupported:
            return "This device does not support Bluetooth Low Energy."
        case .bluetoothResetting:
            return "Bluetooth is resetting. Try again in a moment."
        case .peripheralNotFound:
            return "Peripheral is no longer available. Scan again."
        case .peripheralNotConnectable:
            return "This device is advertising as non-connectable, so no link can be created. Check the peripheral side."
        case .notConnected, .notReady:
            return "The connection is not ready."
        case .emptyPayload:
            return "Packet is empty."
        case .writeInProgress:
            return "A write is already in progress."
        case .connectionTimedOut:
            return "Timed out: the peripheral never accepted the connection (15 s). Check that BLEPeripheralApp is still advertising and in range."
        case .discoveryTimedOut:
            return "Timed out during service discovery or TX subscription (10 s). The Service/Characteristic UUIDs may not match."
        case .cancelled:
            return "The operation was cancelled."
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .connectionLost(let reason):
            return reason.map { "Connection lost: \($0)" } ?? "Connection lost."
        case .serviceNotFound(let uuid):
            return "Service \(uuid) not found on the peripheral."
        case .characteristicNotFound(let uuid):
            return "Characteristic \(uuid) not found on the peripheral."
        case .writeFailed(let reason):
            return "Write failed: \(reason)"
        case .notifySubscriptionFailed(let reason):
            return "Subscription failed: \(reason)"
        }
    }
}

// MARK: - Hex helpers

extension DemoModel {
    static func hexString(_ data: Data) -> String {
        let shown = data.prefix(32)
        let hex = shown.map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > shown.count ? hex + " …" : hex
    }

    /// Parses "48 65 6C 6C 6F", "0x48656C6C6F" or "48656C6C6F".
    static func data(fromHex text: String) -> Data? {
        let cleaned = text
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .filter { !$0.isWhitespace }
        guard !cleaned.isEmpty, cleaned.count.isMultiple(of: 2) else { return nil }

        var data = Data(capacity: cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
