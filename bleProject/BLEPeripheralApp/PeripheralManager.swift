import Foundation
import CoreBluetooth
import Combine
import ModuBLE

final class PeripheralManager: NSObject, CBPeripheralManagerDelegate, ObservableObject {

    static let serviceUUID = CBUUID(string: "5A0C8B3E-7D2F-4A6B-9C1D-3E5F7A9B1C2D")
    static let characteristicUUID = CBUUID(string: "9F8E7D6C-5B4A-3F2E-8D7C-6B5A4F3E2D1C")

    /// Read + notify characteristic used to report reception status to subscribers.
    static let statusCharacteristicUUID = CBUUID(string: "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D")

    // MARK: - Received data

    struct ReceivedPacket: Identifiable {
        let id = UUID()
        let sequence: Int
        let date: Date
        let data: Data

        var hexString: String {
            data.map { String(format: "%02X", $0) }.joined(separator: " ")
        }

        var text: String? {
            guard !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }

    // MARK: - Published state

    @Published var managerState: CBManagerState = .unknown
    @Published var isAdvertising = false
    @Published var localName: String = "MacBLE"
    @Published var lastError: Error?
    @Published var receivedPackets: [ReceivedPacket] = []
    /// Every byte received since the last clear, in arrival order.
    @Published var receivedStream = Data()
    @Published var latestValue: Data = Data()
    @Published var subscriberCount = 0
    @Published var lastStatus: String = "READY"

    /// Whether the app is holding a power assertion to stay awake and un-napped.
    @Published var keepAwakeActive = false
    /// How many times the watchdog had to revive advertising.
    @Published var advertisingRestartCount = 0
    /// Last time a central subscribed, read or wrote.
    @Published var lastActivityAt: Date?

    // MARK: - CoreBluetooth objects

    private let service: CBMutableService
    private let characteristic: CBMutableCharacteristic
    private let statusCharacteristic: CBMutableCharacteristic
    private var manager: CBPeripheralManager!
    private var hasAddedService = false

    private var subscribedCentrals: [CBCentral] = []
    private var pendingNotifications: [Data] = []
    private var latestStatus = Data("READY".utf8)

    // MARK: - Protocol

    private let codec = PacketCodec()
    private var decoder = PacketDecoder()
    /// Sealed envelopes identify their format in the first byte (GCM `0x01`,
    /// CBC `0x02`), so the peripheral can answer in whatever the central chose.
    /// TEST KEYS ONLY — see `ModuBLE.DemoTestKey`.
    private let providers: [UInt8: any CryptoProvider] = {
        var providers: [UInt8: any CryptoProvider] = [:]
        if let gcm = try? AESGCMProvider(key: DemoTestKey.aes128GCM) {
            providers[AESGCMProvider.envelopeVersion] = gcm
        }
        if let cbc = try? AESCBCProvider(key: DemoTestKey.aes128CBCHMAC) {
            providers[AESCBCProvider.envelopeVersion] = cbc
        }
        return providers
    }()

    /// Held while advertising; released when advertising stops.
    private var activityToken: NSObjectProtocol?
    private var watchdogTimer: Timer?

    private let maxPackets = 100
    private let watchdogInterval: TimeInterval = 5

    // MARK: - Init

    override init() {
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        let characteristic = CBMutableCharacteristic(
            type: Self.characteristicUUID,
            // `.write` accepts write requests (with response), `.writeWithoutResponse`
            // accepts write commands, which many devices (ESP32, embedded, Android)
            // use by default.
            properties: [.read, .write, .writeWithoutResponse],
            value: nil,
            permissions: [.readable, .writeable]
        )
        let statusCharacteristic = CBMutableCharacteristic(
            type: Self.statusCharacteristicUUID,
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable]
        )

        self.service = service
        self.characteristic = characteristic
        self.statusCharacteristic = statusCharacteristic
        super.init()

        service.characteristics = [characteristic, statusCharacteristic]
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    deinit {
        watchdogTimer?.invalidate()
        endKeepAwake()
        manager.stopAdvertising()
    }

    // MARK: - CBPeripheralManagerDelegate

    func peripheralManagerDidUpdateState(_ peripheralManager: CBPeripheralManager) {
        managerState = peripheralManager.state
        debugLog("state = \(peripheralManager.state.rawValue)")

        if peripheralManager.state == .poweredOn {
            // Services may only be added once the manager is powered on.
            if !hasAddedService {
                hasAddedService = true
                peripheralManager.add(service)
            }
        } else {
            isAdvertising = false
            subscribedCentrals.removeAll()
            subscriberCount = 0
            stopWatchdog()
            endKeepAwake()
        }
    }

    func peripheralManager(_ peripheralManager: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            lastError = error
            // Allow a retry instead of permanently giving up on this service.
            hasAddedService = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.manager.state == .poweredOn, !self.hasAddedService else { return }
                self.hasAddedService = true
                self.manager.add(self.service)
            }
            return
        }
        debugLog("service added")
        startAdvertising()
    }

    func peripheralManagerDidStartAdvertising(_ peripheralManager: CBPeripheralManager, error: Error?) {
        if let error = error {
            lastError = error
            isAdvertising = false
            stopWatchdog()
            endKeepAwake()
            return
        }
        isAdvertising = true
        debugLog("advertising started")
        startWatchdog()
        beginKeepAwake()
    }

    func peripheralManager(_ peripheralManager: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        touchActivity()
        guard characteristic.uuid == Self.statusCharacteristicUUID else { return }
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
        subscriberCount = subscribedCentrals.count
        debugLog("central subscribed · subscribers = \(subscriberCount)")
        sendStatus("READY")
    }

    func peripheralManager(_ peripheralManager: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        touchActivity()
        guard characteristic.uuid == Self.statusCharacteristicUUID else { return }
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        subscriberCount = subscribedCentrals.count
        debugLog("central unsubscribed · subscribers = \(subscriberCount)")
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheralManager: CBPeripheralManager) {
        flushPendingNotifications()
    }

    func peripheralManager(_ peripheralManager: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        touchActivity()
        let value: Data
        switch request.characteristic.uuid {
        case Self.statusCharacteristicUUID:
            value = latestStatus
        default:
            value = latestValue
        }

        // Handle long reads: Core Bluetooth asks for the value in chunks.
        guard request.offset <= value.count else {
            peripheralManager.respond(to: request, withResult: .invalidOffset)
            return
        }

        debugLog("didReceiveRead \(request.characteristic.uuid.uuidString) offset \(request.offset) → \(value.count - request.offset) B")
        request.value = value.subdata(in: request.offset..<value.count)
        peripheralManager.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheralManager: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        touchActivity()

        // Core Bluetooth may deliver several write requests in one callback.
        // A long write (prepare/execute) arrives as chunks with increasing
        // `offset`; separate write commands from one central usually all have
        // `offset == 0` and must each be treated as an independent packet.
        var currentPacket = Data()
        var packets: [Data] = []

        for request in requests {
            guard let value = request.value else { continue }

            if request.offset == 0 {
                if !currentPacket.isEmpty {
                    packets.append(currentPacket)
                }
                currentPacket = value
            } else if request.offset == currentPacket.count {
                currentPacket.append(value)
            } else {
                // Out-of-order chunk; treat it as the start of a new packet.
                if !currentPacket.isEmpty {
                    packets.append(currentPacket)
                }
                currentPacket = value
            }
        }
        packets.append(currentPacket)

        for packet in packets {
            debugLog("didReceiveWrite → \(packets.count) packet(s), this one \(packet.count) B, stream now \(receivedStream.count + packet.count) B")
            store(packet)
            updateLocalStatus("RX #\(receivedPackets.count): \(packet.count) bytes")
            ingest(packet)
        }

        // Responding to the first request is enough for the whole batch.
        peripheralManager.respond(to: first, withResult: .success)
    }

    // MARK: - Public API

    private var advertisement: [String: Any] {
        [
            CBAdvertisementDataLocalNameKey: localName,
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID]
        ]
    }

    func startAdvertising() {
        guard manager.state == .poweredOn, !isAdvertising else { return }
        manager.startAdvertising(advertisement)
    }

    func stopAdvertising() {
        manager.stopAdvertising()
        isAdvertising = false
        stopWatchdog()
        endKeepAwake()
    }

    /// Restarts advertising unconditionally. Used by the watchdog and the UI
    /// when the system has silently dropped the advertisement.
    func restartAdvertising() {
        guard manager.state == .poweredOn else { return }
        manager.stopAdvertising()
        manager.startAdvertising(advertisement)
    }

    func clearReceivedPackets() {
        receivedPackets.removeAll()
        receivedStream = Data()
        latestValue = Data()
        decoder.reset()
    }

    /// Pushes a status string to every subscribed central.
    func broadcastStatus(_ text: String) {
        sendStatus(text)
    }

    // MARK: - Private

    private func debugLog(_ message: String) {
        print("[BLEPeripheral] \(message)")
    }

    private func store(_ data: Data) {
        latestValue = data

        let sequence = (receivedPackets.last?.sequence ?? 0) + 1
        let packet = ReceivedPacket(sequence: sequence, date: Date(), data: data)
        receivedPackets.append(packet)
        if receivedPackets.count > maxPackets {
            receivedPackets.removeFirst(receivedPackets.count - maxPackets)
        }

        receivedStream.append(data)
    }

    private func sendStatus(_ text: String) {
        updateLocalStatus(text)
        notifyAll(Data(text.utf8))
    }

    private func updateLocalStatus(_ text: String) {
        lastStatus = text
        latestStatus = Data(text.utf8)
    }

    /// Queues bytes for every subscribed central, split to the smallest
    /// notification size they negotiated.
    private func notifyAll(_ data: Data) {
        guard !subscribedCentrals.isEmpty else {
            debugLog("notify skipped: no subscribed central")
            return
        }
        let limit = max(20, subscribedCentrals.map(\.maximumUpdateValueLength).min() ?? 20)
        let chunks = MTUChunker.chunks(of: data, maxLength: limit)
        debugLog("notify \(data.count) B in \(chunks.count) chunk(s), limit \(limit) B")
        pendingNotifications.append(contentsOf: chunks)
        flushPendingNotifications()
    }

    private func flushPendingNotifications() {
        guard !subscribedCentrals.isEmpty else {
            pendingNotifications.removeAll()
            return
        }
        while let data = pendingNotifications.first {
            guard manager.updateValue(data, for: statusCharacteristic, onSubscribedCentrals: subscribedCentrals) else {
                debugLog("notify blocked, \(pendingNotifications.count) chunk(s) still queued")
                break
            }
            pendingNotifications.removeFirst()
            debugLog("notify \(data.count) B sent")
        }
    }

    // MARK: - Protocol handling
    //
    // Inbound bytes are reassembled into `Packet` frames. A frame's payload is a
    // sealed envelope (AES-128-GCM, see `CryptoProvider`); the response is sealed
    // and notified back with the same sequence.
    //
    // Anything that is not a frame is treated as legacy plain text, so the old
    // "RX #n: k bytes" round trip still works while the apps migrate.

    private func ingest(_ data: Data) {
        var frames: [Packet] = []
        do {
            frames = try decoder.append(data)
        } catch {
            debugLog("frame decode failed: \(error)")
            decoder.reset()
        }

        if frames.isEmpty && decoder.bufferedByteCount == 0 {
            sendStatus("RX #\(receivedPackets.count): \(data.count) bytes")
            return
        }

        for frame in frames {
            handle(frame)
        }
    }

    private func handle(_ packet: Packet) {
        guard packet.kind == .request else {
            debugLog("ignoring frame kind \(packet.kind.rawValue)")
            return
        }
        guard let version = packet.payload.first, let provider = providers[version] else {
            let version = packet.payload.first.map { String(format: "0x%02X", $0) } ?? "empty"
            debugLog("frame #\(packet.sequence): no provider for envelope \(version)")
            updateLocalStatus("UNSUPPORTED ENVELOPE")
            return
        }

        do {
            let plaintext = try provider.decrypt(packet.payload)
            let reply = Self.respond(to: plaintext)
            let sealed = try provider.encrypt(reply)
            let frame = try codec.encode(Packet(kind: .response, sequence: packet.sequence, payload: sealed))
            debugLog(
                "frame #\(packet.sequence) (\(provider.algorithm.displayName)) → \(plaintext.count) B in, \(reply.count) B out, \(frame.count) B on air"
            )
            updateLocalStatus("ENC #\(packet.sequence): \(reply.count) bytes")
            notifyAll(frame)
        } catch {
            debugLog("frame #\(packet.sequence) rejected: \(error)")
            updateLocalStatus("DECRYPT FAIL")
        }
    }

    /// `START` → `START_ACK`, `PING` → `PONG`, everything else is echoed.
    /// The echo branch makes arbitrary binary payloads (including multi-chunk
    /// ones) verifiable end to end.
    private static func respond(to plaintext: Data) -> Data {
        if let text = String(data: plaintext, encoding: .utf8) {
            switch text {
            case "START": return Data("START_ACK".utf8)
            case "PING": return Data("PONG".utf8)
            default: break
            }
        }
        return plaintext
    }

    // MARK: - Keep-awake
    //
    // App Nap and idle sleep are the usual reason a Mac "advertises" (the UI
    // still says yes) while iOS can no longer connect to it. Hold a power
    // assertion only while advertising, so the machine can sleep again once the
    // peripheral is turned off.

    private func beginKeepAwake() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Advertising as a BLE peripheral"
        )
        keepAwakeActive = true
    }

    private func endKeepAwake() {
        guard let token = activityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        activityToken = nil
        keepAwakeActive = false
    }

    // MARK: - Advertising watchdog

    private func startWatchdog() {
        watchdogTimer?.invalidate()
        let timer = Timer(timeInterval: watchdogInterval, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    /// Core Bluetooth can drop the advertisement without telling us, leaving
    /// `isAdvertising` stale. Revive it when the manager reports otherwise.
    private func watchdogTick() {
        guard isAdvertising else { return }
        guard manager.state == .poweredOn else { return }
        guard manager.isAdvertising == false else { return }

        advertisingRestartCount += 1
        manager.startAdvertising(advertisement)
    }

    private func touchActivity() {
        lastActivityAt = Date()
    }
}
