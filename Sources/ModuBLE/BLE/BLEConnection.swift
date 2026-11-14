import Foundation
import CoreBluetooth

/// One live connection to a peripheral: service discovery, TX notifications and
/// MTU-aware writes to RX.
///
/// All CoreBluetooth state is confined to `queue` (the serial queue the central
/// manager was created with), which is why the class is `@unchecked Sendable`.
/// Public methods are `async` and hop onto that queue; delegate callbacks
/// already arrive there.
public final class BLEConnection: NSObject, BLELink, @unchecked Sendable {
    public let device: DiscoveredDevice
    public let profile: GATTProfile

    public var inbound: AsyncStream<Data> { inboundStream }

    /// Thread-safe snapshot of the connection phase.
    public var state: ConnectionState {
        stateLock.withLock { currentState }
    }

    /// Broadcasts every phase change, starting with the current value.
    ///
    /// Use this — not `inbound` — to react to disconnects. `inbound` is a
    /// single-consumer stream owned by whoever reads the bytes (usually
    /// `EncryptedSession`); a second reader would steal payloads from it.
    public func observeState() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            queue.async { [self] in
                stateObservers[id] = continuation
                continuation.yield(state)
                continuation.onTermination = { [weak self] _ in
                    guard let self else { return }
                    self.queue.async { self.stateObservers[id] = nil }
                }
            }
        }
    }

    /// Largest number of bytes the stack accepts per write, as negotiated.
    /// Meaningful once `state == .ready`; defaults to the BLE minimum payload.
    public var maximumWritePayloadLength: Int {
        mtuLock.withLock { maxWritePayload }
    }

    /// Largest payload per write command. Unlike the write-request limit this
    /// reflects the real ATT MTU: `MTU = maximumWritePayloadLengthWithoutResponse + 3`.
    public var maximumWritePayloadLengthWithoutResponse: Int {
        mtuLock.withLock { maxWritePayloadWithoutResponse }
    }

    /// Upper bound for service discovery plus TX subscription.
    static let preparationTimeout: TimeInterval = 10

    let peripheral: CBPeripheral

    private let queue: DispatchQueue
    private let logStore: CommunicationLogStore?
    private let onClose: @Sendable (UUID) -> Void

    private let inboundStream: AsyncStream<Data>
    private let inboundContinuation: AsyncStream<Data>.Continuation

    private let stateLock = NSLock()
    private var currentState: ConnectionState = .disconnected
    private var stateObservers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]

    private let mtuLock = NSLock()
    private var maxWritePayload = 20
    private var maxWritePayloadWithoutResponse = 20

    private let writeGate = NSLock()
    private var writeInFlight = false

    // MARK: - Queue-confined state

    private enum Phase {
        case idle
        case discoveringServices
        case discoveringCharacteristics
        case subscribing
        case ready
        case closed
    }

    private var phase: Phase = .idle
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withResponse

    private var prepareContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var congestedWrite: (chunk: Data, continuation: CheckedContinuation<Void, Error>)?

    // MARK: - Init

    init(
        peripheral: CBPeripheral,
        device: DiscoveredDevice,
        profile: GATTProfile,
        queue: DispatchQueue,
        logStore: CommunicationLogStore?,
        onClose: @escaping @Sendable (UUID) -> Void
    ) {
        self.peripheral = peripheral
        self.device = device
        self.profile = profile
        self.queue = queue
        self.logStore = logStore
        self.onClose = onClose

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.inboundStream = stream
        self.inboundContinuation = continuation

        super.init()
    }

    public var id: UUID { device.id }

    // MARK: - Setup

    /// Discovers the service/characteristics and subscribes to TX.
    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                switch phase {
                case .ready:
                    continuation.resume()
                    return
                case .closed:
                    continuation.resume(throwing: BLEError.cancelled)
                    return
                case .idle:
                    break
                default:
                    continuation.resume(throwing: BLEError.notReady)
                    return
                }

                setState(.discovering)
                phase = .discoveringServices
                prepareContinuation = continuation
                peripheral.delegate = self
                log(.info, .gatt, "Discovering services")
                peripheral.discoverServices([CBUUID(string: profile.serviceUUID)])

                // A peripheral that never answers would otherwise hang here forever.
                queue.asyncAfter(deadline: .now() + Self.preparationTimeout) { [weak self] in
                    guard let self, self.prepareContinuation != nil else { return }
                    self.failPreparation(.discoveryTimedOut)
                }
            }
        }
    }

    // MARK: - BLELink

    public func write(_ data: Data) async throws {
        try await write(data, mode: nil)
    }

    /// Writes using an explicit write mode for this call; `nil` uses the
    /// connection's `GATTProfile.writeMode`.
    ///
    /// This exists so the demo can exercise both `withResponse` and
    /// `withoutResponse` against the same live connection.
    public func write(_ data: Data, mode: GATTProfile.WriteMode?) async throws {
        guard !data.isEmpty else {
            throw BLEError.emptyPayload
        }

        let accepted = writeGate.withLock { () -> Bool in
            guard !writeInFlight else { return false }
            writeInFlight = true
            return true
        }
        guard accepted else {
            throw BLEError.writeInProgress
        }
        defer { writeGate.withLock { writeInFlight = false } }

        let plan = try await planWrite(data, mode: mode)
        logStore?.log(
            .debug,
            .transmit,
            "TX plan: \(data.count) B → \(plan.chunks.count) chunk(s), max \(plan.limit) B"
        )
        for chunk in plan.chunks {
            try Task.checkCancellation()
            try await writeChunk(chunk, type: plan.type)
        }
    }

    public func close() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard phase != .closed else {
                    continuation.resume()
                    return
                }
                phase = .closed
                setState(.disconnected)
                abortPendingOperations(with: BLEError.cancelled)
                inboundContinuation.finish()
                log(.info, .ble, "Disconnected", payload: nil)
                onClose(device.id)
                continuation.resume()
            }
        }
    }

    /// Called on `queue` when CoreBluetooth reports a disconnect that was not
    /// asked for through `close()`.
    func handleDisconnection(error: Error?) {
        guard phase != .closed else { return }
        phase = .closed

        let reason = error?.localizedDescription
        setState(.failed(reason ?? "Connection lost"))
        abortPendingOperations(with: BLEError.connectionLost(reason))
        log(.error, .ble, "Connection lost", payload: nil)
        inboundContinuation.finish()
    }

    // MARK: - Queue helpers

    private func setState(_ state: ConnectionState) {
        stateLock.withLock { currentState = state }
        for observer in stateObservers.values {
            observer.yield(state)
        }
    }

    private func abortPendingOperations(with error: BLEError) {
        prepareContinuation?.resume(throwing: error)
        prepareContinuation = nil

        writeContinuation?.resume(throwing: error)
        writeContinuation = nil

        congestedWrite?.continuation.resume(throwing: error)
        congestedWrite = nil
    }

    private func planWrite(
        _ data: Data,
        mode: GATTProfile.WriteMode?
    ) async throws -> (type: CBCharacteristicWriteType, limit: Int, chunks: [Data]) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(type: CBCharacteristicWriteType, limit: Int, chunks: [Data]), Error>) in
            queue.async { [self] in
                guard phase == .ready, let characteristic = rxCharacteristic else {
                    continuation.resume(throwing: BLEError.notReady)
                    return
                }

                let type: CBCharacteristicWriteType
                do {
                    type = try Self.resolveWriteType(
                        mode: mode ?? profile.writeMode,
                        characteristic: characteristic
                    )
                } catch let error as BLEError {
                    continuation.resume(throwing: error)
                    return
                } catch {
                    continuation.resume(throwing: BLEError.writeFailed(error.localizedDescription))
                    return
                }

                let maxLength = max(1, peripheral.maximumWriteValueLength(for: type))
                continuation.resume(
                    returning: (type, maxLength, MTUChunker.chunks(of: data, maxLength: maxLength))
                )
            }
        }
    }

    private func writeChunk(_ chunk: Data, type: CBCharacteristicWriteType) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard phase == .ready, let characteristic = rxCharacteristic else {
                    continuation.resume(throwing: BLEError.notReady)
                    return
                }

                switch type {
                case .withResponse:
                    guard writeContinuation == nil else {
                        continuation.resume(throwing: BLEError.writeInProgress)
                        return
                    }
                    writeContinuation = continuation
                    peripheral.writeValue(chunk, for: characteristic, type: .withResponse)

                case .withoutResponse:
                    guard congestedWrite == nil else {
                        continuation.resume(throwing: BLEError.writeInProgress)
                        return
                    }
                    if peripheral.canSendWriteWithoutResponse {
                        peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
                        continuation.resume()
                    } else {
                        // Resume from `peripheralIsReady(toSendWriteWithoutResponse:)`.
                        congestedWrite = (chunk, continuation)
                    }

                @unknown default:
                    continuation.resume(throwing: BLEError.writeFailed("Unsupported write type"))
                }

                log(.debug, .transmit, "TX \(chunk.count) B", payload: chunk)
            }
        }
    }

    private func log(_ level: LogLevel, _ category: LogCategory, _ message: String, payload: Data? = nil) {
        logStore?.log(level, category, message, payload: payload)
    }
}
// MARK: - CBPeripheralDelegate

extension BLEConnection: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard phase == .discoveringServices else { return }

        if let error {
            failPreparation(.connectionFailed(error.localizedDescription))
            return
        }
        guard let service = peripheral.services?.first(
            where: { $0.uuid == CBUUID(string: profile.serviceUUID) }
        ) else {
            failPreparation(.serviceNotFound(profile.serviceUUID))
            return
        }

        log(.debug, .gatt, "Service found \(service.uuid.uuidString)", payload: nil)
        phase = .discoveringCharacteristics
        log(.info, .gatt, "Discovering characteristics")
        peripheral.discoverCharacteristics(
            [
                CBUUID(string: profile.rxCharacteristicUUID),
                CBUUID(string: profile.txCharacteristicUUID)
            ],
            for: service
        )
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard phase == .discoveringCharacteristics else { return }

        if let error {
            failPreparation(.connectionFailed(error.localizedDescription))
            return
        }

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case CBUUID(string: profile.rxCharacteristicUUID):
                rxCharacteristic = characteristic
            case CBUUID(string: profile.txCharacteristicUUID):
                txCharacteristic = characteristic
            default:
                break
            }
        }

        guard let rx = rxCharacteristic else {
            failPreparation(.characteristicNotFound(profile.rxCharacteristicUUID))
            return
        }
        guard let tx = txCharacteristic else {
            failPreparation(.characteristicNotFound(profile.txCharacteristicUUID))
            return
        }
        guard tx.properties.contains(.notify) else {
            failPreparation(.notifySubscriptionFailed("TX characteristic does not support notify"))
            return
        }

        do {
            writeType = try Self.resolveWriteType(mode: profile.writeMode, characteristic: rx)
        } catch let error as BLEError {
            failPreparation(error)
            return
        } catch {
            failPreparation(.writeFailed(error.localizedDescription))
            return
        }

        mtuLock.withLock {
            maxWritePayload = max(1, peripheral.maximumWriteValueLength(for: writeType))
            maxWritePayloadWithoutResponse = max(1, peripheral.maximumWriteValueLength(for: .withoutResponse))
        }

        log(.debug, .gatt, "Characteristics found, subscribing to TX", payload: nil)
        phase = .subscribing
        log(.info, .gatt, "Subscribing to TX \(profile.txCharacteristicUUID)")
        peripheral.setNotifyValue(true, for: tx)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard phase == .subscribing else { return }
        guard characteristic.uuid == CBUUID(string: profile.txCharacteristicUUID) else { return }

        if let error {
            failPreparation(.notifySubscriptionFailed(error.localizedDescription))
            return
        }
        guard characteristic.isNotifying else {
            failPreparation(.notifySubscriptionFailed("Peripheral refused the subscription"))
            return
        }

        phase = .ready
        setState(.ready)
        prepareContinuation?.resume()
        prepareContinuation = nil
        log(.info, .ble, "Notify subscribed", payload: nil)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == CBUUID(string: profile.txCharacteristicUUID) else { return }

        if let error {
            log(.error, .transport, "Notification error: \(error.localizedDescription)", payload: nil)
            return
        }
        guard let data = characteristic.value, !data.isEmpty else { return }

        log(.debug, .receive, "RX \(data.count) B", payload: data)
        inboundContinuation.yield(data)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == CBUUID(string: profile.rxCharacteristicUUID) else { return }

        let continuation = writeContinuation
        writeContinuation = nil

        if let error {
            log(.error, .transport, "Write failed: \(error.localizedDescription)", payload: nil)
            continuation?.resume(throwing: BLEError.writeFailed(error.localizedDescription))
        } else {
            continuation?.resume()
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let pending = congestedWrite else { return }
        congestedWrite = nil

        guard phase == .ready, let characteristic = rxCharacteristic else {
            pending.continuation.resume(throwing: BLEError.notReady)
            return
        }
        peripheral.writeValue(pending.chunk, for: characteristic, type: .withoutResponse)
        pending.continuation.resume()
    }
}

// MARK: - Helpers

private extension BLEConnection {
    func failPreparation(_ error: BLEError) {
        phase = .closed
        setState(.failed(error.localizedDescription))
        abortPendingOperations(with: error)
        log(.error, .ble, "Setup failed: \(error.localizedDescription)", payload: nil)
    }

    static func resolveWriteType(
        mode: GATTProfile.WriteMode,
        characteristic: CBCharacteristic
    ) throws -> CBCharacteristicWriteType {
        switch mode {
        case .withResponse:
            guard characteristic.properties.contains(.write) else {
                throw BLEError.writeFailed("RX characteristic does not accept write requests")
            }
            return .withResponse
        case .withoutResponse:
            guard characteristic.properties.contains(.writeWithoutResponse) else {
                throw BLEError.writeFailed("RX characteristic does not accept write commands")
            }
            return .withoutResponse
        case .automatic:
            if characteristic.properties.contains(.write) {
                return .withResponse
            }
            if characteristic.properties.contains(.writeWithoutResponse) {
                return .withoutResponse
            }
            throw BLEError.writeFailed("RX characteristic is not writable")
        }
    }
}
