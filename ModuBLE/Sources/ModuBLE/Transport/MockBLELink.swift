import Foundation

/// A `DeviceLink` backed by `MockPeripheral` instead of CoreBluetooth.
///
/// The link keeps the same contract as `BLEConnection`: writes are chunked at
/// the negotiated MTU, notifications are chunked again on the way back, and a
/// disconnect finishes `inbound`. Faults are applied between the two, so a
/// dropped or corrupted frame behaves exactly like a bad radio link.
public final class MockBLELink: DeviceLink, @unchecked Sendable {
    public let device: DiscoveredDevice
    public let inbound: AsyncStream<Data>

    public let maximumWritePayloadLength: Int
    public let maximumWritePayloadLengthWithoutResponse: Int

    public let peripheral: MockPeripheral
    public let injector: FaultInjector

    private let continuation: AsyncStream<Data>.Continuation
    private let logStore: CommunicationLogStore?
    private let autoTelemetry: Bool
    private let telemetryTick: Duration

    private let lock = NSLock()
    private var currentState: ConnectionState = .ready
    private var stateObservers: [UUID: AsyncStream<ConnectionState>.Continuation] = [:]
    private var closed = false
    private var requestCount = 0
    private var eventCount = 0
    private var elapsedSinceEvent: Duration = .zero
    private var telemetryTask: Task<Void, Never>?

    init(
        device: DiscoveredDevice,
        peripheral: MockPeripheral,
        injector: FaultInjector,
        maximumWritePayloadLength: Int,
        autoTelemetry: Bool,
        telemetryTick: Duration,
        logStore: CommunicationLogStore?
    ) {
        self.device = device
        self.peripheral = peripheral
        self.injector = injector
        self.maximumWritePayloadLength = maximumWritePayloadLength
        self.maximumWritePayloadLengthWithoutResponse = maximumWritePayloadLength
        self.autoTelemetry = autoTelemetry
        self.telemetryTick = telemetryTick
        self.logStore = logStore

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.inbound = stream
        self.continuation = continuation

        startTelemetryLoopIfNeeded()
    }

    public var state: ConnectionState { lock.withLock { currentState } }
    public var isClosed: Bool { lock.withLock { closed } }

    public func observeState() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            let id = UUID()
            let initial = lock.withLock { () -> ConnectionState in
                if !closed { stateObservers[id] = continuation }
                return currentState
            }
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.stateObservers[id] = nil }
            }
        }
    }

    // MARK: - DeviceLink

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { throw BLEError.emptyPayload }
        guard state == .ready else { throw BLEError.notReady }

        let latency = injector.configuration.latency
        if latency > .zero {
            try? await Task.sleep(for: latency)
        }

        let index = lock.withLock { () -> Int in
            requestCount += 1
            return requestCount
        }
        if injector.configuration.disconnectAfterRequests == index {
            injector.recordDisconnect()
            finish(state: .failed("Mock peripheral disconnected after request #\(index)"), log: "Mock link dropped")
            return
        }

        logStore?.log(.debug, .transmit, "TX \(data.count) B", payload: data)

        var replies: [Data] = []
        for chunk in MTUChunker.chunks(of: data, maxLength: maximumWritePayloadLength) {
            replies.append(contentsOf: peripheral.receive(chunk))
        }
        for reply in replies {
            deliver(reply)
        }
    }

    public func close() async {
        finish(state: .disconnected, log: "Mock link closed")
    }

    // MARK: - Telemetry

    /// Emits one telemetry event immediately, bypassing the automatic timer.
    ///
    /// Tests use this so they never depend on wall-clock scheduling. Returns
    /// `false` when telemetry is stopped or the link is gone.
    @discardableResult
    public func emitTelemetryNow(advancingBy delta: Duration = .seconds(1)) -> Bool {
        guard !isClosed else { return false }
        guard let frame = peripheral.makeTelemetryFrame(advancingBy: delta) else { return false }

        let index = lock.withLock { () -> Int in
            eventCount += 1
            return eventCount
        }
        if injector.configuration.disconnectAfterEvents == index {
            injector.recordDisconnect()
            finish(state: .failed("Mock peripheral disconnected after event #\(index)"), log: "Mock link dropped")
            return false
        }

        deliver(frame)
        return true
    }

    // MARK: - Delivery

    private func deliver(_ frame: Data) {
        guard !isClosed else { return }

        if injector.shouldDrop() {
            injector.recordDrop()
            logStore?.log(.warning, .receive, "Mock: dropped a frame")
            return
        }

        var outbound = frame
        if injector.shouldCorrupt() {
            outbound = injector.corrupt(outbound)
            injector.recordCorruption()
            logStore?.log(.warning, .receive, "Mock: corrupted a frame")
        } else if injector.shouldMalform() {
            outbound = injector.malform(outbound)
            injector.recordMalformed()
            logStore?.log(.warning, .receive, "Mock: malformed a frame")
        }

        let limit = max(1, maximumWritePayloadLengthWithoutResponse)
        for chunk in MTUChunker.chunks(of: outbound, maxLength: limit) {
            logStore?.log(.debug, .receive, "RX \(chunk.count) B", payload: chunk)
            continuation.yield(chunk)
        }
    }

    private func finish(state newState: ConnectionState, log message: String) {
        let observers: [AsyncStream<ConnectionState>.Continuation]? = lock.withLock {
            guard !closed else { return nil }
            closed = true
            currentState = newState
            return Array(stateObservers.values)
        }
        guard let observers else { return }

        telemetryTask?.cancel()
        telemetryTask = nil
        continuation.finish()
        for observer in observers {
            observer.yield(newState)
        }
        logStore?.log(.info, .ble, message)
    }

    // MARK: - Automatic telemetry loop

    private func startTelemetryLoopIfNeeded() {
        guard autoTelemetry else { return }
        let tick = telemetryTick
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard let self else { return }
                guard self.tickTelemetry() else { return }
            }
        }
    }

    /// - Returns: `false` once the link is gone, so the loop can exit.
    private func tickTelemetry() -> Bool {
        guard !isClosed else { return false }
        guard peripheral.isEmittingTelemetry else {
            lock.withLock { elapsedSinceEvent = .zero }
            return true
        }

        let rate = peripheral.telemetryRate
        guard rate > 0 else { return true }
        let interval = 1 / rate

        let due = lock.withLock { () -> Bool in
            elapsedSinceEvent += telemetryTick
            guard elapsedSinceEvent >= .seconds(interval) else { return false }
            elapsedSinceEvent = .zero
            return true
        }
        guard due else { return true }

        emitTelemetryNow(advancingBy: .seconds(interval))
        return !isClosed
    }
}
