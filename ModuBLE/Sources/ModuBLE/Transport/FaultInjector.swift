import Foundation

/// Faults the mock peripheral can inject, in the same terms a BLE link fails.
///
/// The protocol has no CRC, so there is deliberately no "CRC error" knob:
/// corrupting the sealed payload breaks AEAD authentication, and damaging the
/// header breaks frame reassembly. Those are the two failure modes that exist.
public struct FaultConfiguration: Sendable, Equatable {
    /// Added to every response and event, simulating a slow peripheral.
    public var latency: Duration
    /// The frame never arrives, so the caller hits its timeout.
    public var dropRate: Double
    /// A payload byte is flipped; decryption fails authentication.
    public var corruptRate: Double
    /// The 2-byte length field is wrecked; the decoder cannot find the frame.
    public var malformedRate: Double
    /// Drop the link after this many requests (`nil` disables).
    public var disconnectAfterRequests: Int?
    /// Drop the link after this many events (`nil` disables).
    public var disconnectAfterEvents: Int?

    public init(
        latency: Duration = .zero,
        dropRate: Double = 0,
        corruptRate: Double = 0,
        malformedRate: Double = 0,
        disconnectAfterRequests: Int? = nil,
        disconnectAfterEvents: Int? = nil
    ) {
        self.latency = latency
        self.dropRate = dropRate.clampedToUnit
        self.corruptRate = corruptRate.clampedToUnit
        self.malformedRate = malformedRate.clampedToUnit
        self.disconnectAfterRequests = disconnectAfterRequests
        self.disconnectAfterEvents = disconnectAfterEvents
    }

    public var isClean: Bool {
        latency == .zero
            && dropRate == 0
            && corruptRate == 0
            && malformedRate == 0
            && disconnectAfterRequests == nil
            && disconnectAfterEvents == nil
    }
}

/// Stateful fault channel with a seedable RNG.
///
/// Seeding matters: a failure that only reproduces once in twenty runs is not a
/// useful demo. With a fixed seed the same sequence of drops and corruptions can
/// be replayed from a bug report.
public final class FaultInjector: @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public var dropped: Int
        public var corrupted: Int
        public var malformed: Int
        public var disconnects: Int

        public init(dropped: Int = 0, corrupted: Int = 0, malformed: Int = 0, disconnects: Int = 0) {
            self.dropped = dropped
            self.corrupted = corrupted
            self.malformed = malformed
            self.disconnects = disconnects
        }
    }

    private let lock = NSLock()
    private var storage: FaultConfiguration
    private var rng: SplitMix64
    private var storageCounters = Counters()

    public init(configuration: FaultConfiguration = FaultConfiguration(), seed: UInt64 = 0x5EED_1234_5678_9ABC) {
        self.storage = configuration
        self.rng = SplitMix64(seed: seed)
        self.storageCounters = Counters()
    }

    public var configuration: FaultConfiguration {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }

    public var counters: Counters { lock.withLock { storageCounters } }

    public func resetCounters() {
        lock.withLock { storageCounters = Counters() }
    }

    // MARK: - Decisions

    public func shouldDrop() -> Bool {
        roll(against: configuration.dropRate)
    }

    public func shouldCorrupt() -> Bool {
        roll(against: configuration.corruptRate)
    }

    public func shouldMalform() -> Bool {
        roll(against: configuration.malformedRate)
    }

    public func recordDrop() { lock.withLock { storageCounters.dropped += 1 } }
    public func recordCorruption() { lock.withLock { storageCounters.corrupted += 1 } }
    public func recordMalformed() { lock.withLock { storageCounters.malformed += 1 } }
    public func recordDisconnect() { lock.withLock { storageCounters.disconnects += 1 } }

    // MARK: - Frame damage

    /// Flips one byte inside the sealed payload, past the envelope version, so
    /// the receiver still picks a provider and fails at authentication.
    public func corrupt(_ frame: Data) -> Data {
        guard frame.count > Packet.headerLength + 1 else { return frame }
        var bytes = [UInt8](frame)
        bytes[Packet.headerLength + 1] ^= 0xFF
        return Data(bytes)
    }

    /// Claims a payload longer than the frame, which makes the decoder resync
    /// instead of producing a packet.
    public func malform(_ frame: Data) -> Data {
        guard frame.count >= Packet.headerLength else { return frame }
        var bytes = [UInt8](frame)
        bytes[8] = 0xFF
        bytes[9] = 0xFF
        return Data(bytes)
    }

    // MARK: - Private

    /// Draws one value only when the rate is enabled; a clean configuration
    /// consumes no entropy, so enabling a fault later still starts from the same
    /// point in the sequence.
    private func roll(against rate: Double) -> Bool {
        guard rate > 0 else { return false }
        let value = lock.withLock { rng.unit() }
        return value < rate
    }
}

private extension Double {
    var clampedToUnit: Double { Swift.min(1, Swift.max(0, self)) }
}

/// SplitMix64: tiny, fast, and deterministic across platforms and runs.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)` with 53 bits of precision.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(UInt64(1) << 53)
    }
}
