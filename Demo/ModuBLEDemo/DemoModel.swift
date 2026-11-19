import Foundation
import Combine
import ModuBLE

/// Diagnostics view model.
///
/// It owns the raw-send, chunk-test and paced-transfer features plus the log
/// mirror. It deliberately does **not** own scanning, connecting or reconnecting:
/// those belong to `DeviceCoordinator`, which owns the `DeviceManager`.
///
/// `@unchecked Sendable` is deliberate: async work reads only the injected
/// session and funnels every `@Published` mutation through `onMain(_:)`.
final class DemoModel: ObservableObject, @unchecked Sendable {
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

    @Published var logEntries: [CommunicationLog] = []
    @Published var useEncryption = true
    @Published var lastResponse: Data?
    @Published var lastError: String?

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

    // MARK: - Dependencies

    private let logStore: CommunicationLogStore
    private var session: DeviceSession?
    private var transferTask: Task<Void, Never>?

    init(logStore: CommunicationLogStore) {
        self.logStore = logStore
        logStore.setAppendHandler { [weak self] entry in
            // Main queue keeps the SDK's append order, unlike unordered Tasks.
            DispatchQueue.main.async { self?.receive(entry) }
        }
        #if DEBUG
        logStore.setMirrorsToConsole(true)
        #endif
    }

    /// Called when the coordinator opens or closes a session.
    func bind(_ session: DeviceSession?) {
        self.session = session
        lastResponse = nil
        lastError = nil
        if session == nil {
            stopPacedTransfer(logMessage: false)
        }
    }

    /// Full session log, one line per entry, for copying into a bug report.
    var logText: String {
        logStore.textDump()
    }

    // MARK: - Sending

    func send(_ data: Data, withResponse: Bool) {
        lastResponse = nil
        guard !data.isEmpty else {
            lastError = "Packet is empty."
            return
        }
        guard let session, !session.isClosed else {
            lastError = "Connect to a peripheral before sending data."
            return
        }
        guard !transferActive else {
            lastError = "A paced transfer is running. Stop it before sending manually."
            return
        }

        if useEncryption {
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

        let mode: GATTProfile.WriteMode = withResponse ? .withResponse : .withoutResponse
        Task { [weak self] in
            do {
                try await session.write(data, mode: mode)
            } catch {
                self?.onMain { self?.lastError = Self.describe(error) }
            }
        }
    }

    func clearLog() {
        logStore.clear()
        logEntries.removeAll()
    }

    /// Sends a fixed command string through whatever session is bound.
    func sendText(_ text: String) {
        send(Data(text.utf8), withResponse: true)
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
        let payload = max(1, maxWritePayload)
        return Int(ceil(Double(max(1, bytes)) / Double(payload)))
    }

    /// Largest payload the stack accepts per write for the current session.
    var maxWritePayload: Int {
        session?.maximumWritePayloadLength ?? 20
    }

    /// Real ATT MTU, derived from the write-command payload limit.
    var attMTU: Int {
        session?.attMTU ?? 23
    }

    // MARK: - Paced transfer

    var plannedChunkSize: Int {
        max(1, min(transferChunkSize, maxWritePayload))
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
        guard let session, !session.isClosed else {
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
                    try await session.write(packet.data)
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
        transferNextSendAt = nil
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
