import Foundation

/// Key material shared by the mock peripheral and the demo central.
public struct MockKeys: Sendable {
    public let gcm: Data
    public let cbc: Data

    /// Defaults to the public demo keys. Never use these outside the demo.
    public init(gcm: Data = DemoTestKey.aes128GCM, cbc: Data = DemoTestKey.aes128CBCHMAC) {
        self.gcm = gcm
        self.cbc = cbc
    }
}

/// The peripheral half of the mock link.
///
/// It uses the **real** `PacketDecoder`, `PacketCodec` and `CryptoProvider`
/// implementations, so a mock round trip exercises the same framing, MTU
/// reassembly and AEAD path as a real device. Only the radio is fictitious.
public final class MockPeripheral: @unchecked Sendable {
    private let codec = PacketCodec()
    private let providers: [UInt8: any CryptoProvider]
    private let lock = NSLock()

    private var decoder = PacketDecoder()
    private var generator = TelemetryGenerator()
    private var telemetryEnabled = false
    private var rate: Double = 1
    private var nextEventSequence: UInt32 = 1
    private var lastEnvelopeVersion: UInt8 = AESGCMProvider.envelopeVersion
    private var receivedPackets = 0

    public init(keys: MockKeys = MockKeys()) {
        var providers: [UInt8: any CryptoProvider] = [:]
        if let gcm = try? AESGCMProvider(key: keys.gcm) {
            providers[AESGCMProvider.envelopeVersion] = gcm
        }
        if let cbc = try? AESCBCProvider(key: keys.cbc) {
            providers[AESCBCProvider.envelopeVersion] = cbc
        }
        self.providers = providers
    }

    public var isEmittingTelemetry: Bool {
        lock.withLock { telemetryEnabled }
    }

    public var telemetryRate: Double {
        lock.withLock { rate }
    }

    /// Feeds bytes exactly as a GATT write would and returns the notification
    /// frames the peripheral wants to send back.
    ///
    /// Bytes that are not a ModuBLE frame fall back to the legacy plain-text
    /// status reply, mirroring the macOS reference peripheral.
    public func receive(_ data: Data) -> [Data] {
        lock.withLock {
            var frames: [Packet] = []
            do {
                frames = try decoder.append(data)
            } catch {
                decoder.reset()
                return []
            }

            if frames.isEmpty && decoder.bufferedByteCount == 0 {
                receivedPackets += 1
                return [Data("RX #\(receivedPackets): \(data.count) bytes".utf8)]
            }

            var replies: [Data] = []
            for frame in frames where frame.kind == .request {
                replies.append(contentsOf: respond(to: frame))
            }
            return replies
        }
    }

    /// Seals one telemetry sample into an `event` frame, or returns `nil` when
    /// telemetry is stopped.
    public func makeTelemetryFrame(advancingBy delta: Duration) -> Data? {
        lock.withLock {
            guard telemetryEnabled,
                  let provider = providers[lastEnvelopeVersion] else { return nil }

            let telemetry = generator.next(advancingBy: delta)
            guard let payload = try? TelemetryCodec.encode(telemetry),
                  let sealed = try? provider.encrypt(payload),
                  let frame = try? codec.encode(
                      Packet(kind: .event, sequence: nextEventSequence, payload: sealed)
                  ) else { return nil }

            nextEventSequence = nextEventSequence == .max ? 1 : nextEventSequence + 1
            return frame
        }
    }

    public func setTelemetryEnabled(_ enabled: Bool) {
        lock.withLock { telemetryEnabled = enabled }
    }

    public func reset() {
        lock.withLock {
            decoder.reset()
            generator.reset()
            telemetryEnabled = false
            rate = 1
            nextEventSequence = 1
            receivedPackets = 0
        }
    }

    // MARK: - Private (already holding the lock)

    private func respond(to packet: Packet) -> [Data] {
        guard let version = packet.payload.first,
              let provider = providers[version],
              let plaintext = try? provider.decrypt(packet.payload) else {
            return []
        }

        lastEnvelopeVersion = version
        let (reply, command) = DemoPeripheralBehavior.handle(plaintext)
        apply(command)

        guard let sealed = try? provider.encrypt(reply),
              let frame = try? codec.encode(
                  Packet(kind: .response, sequence: packet.sequence, payload: sealed)
              ) else { return [] }
        return [frame]
    }

    private func apply(_ command: DemoPeripheralCommand) {
        switch command {
        case .startTelemetry:
            telemetryEnabled = true
        case .stopTelemetry:
            telemetryEnabled = false
        case .setTelemetryRate(let hz):
            rate = hz
        case .ping, .echo:
            break
        }
    }
}
