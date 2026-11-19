import XCTest
@testable import ModuBLE

/// The transport layer is intentionally thin: it exists so the session and the
/// app do not depend on CoreBluetooth. These tests cover the structural
/// guarantees and the one piece of behaviour the protocol adds.
final class DeviceTransportTests: XCTestCase {
    func testCoreBluetoothTransportReportsItsKind() {
        let transport = CoreBluetoothTransport()
        XCTAssertEqual(transport.kind, .coreBluetooth)
        XCTAssertEqual(transport.kind.label, "CoreBluetooth")
        XCTAssertEqual(TransportKind.allCases, [.coreBluetooth, .mock])
    }

    /// Reading the state must not activate `CBCentralManager`; otherwise merely
    /// constructing the transport would prompt for Bluetooth permission.
    func testBluetoothStateIsUnknownBeforeActivation() {
        let transport = CoreBluetoothTransport()
        XCTAssertEqual(transport.bluetoothState, .unknown)
    }

    func testBLEConnectionConformsToDeviceLink() {
        // Compile-time check: removing the conformance breaks the build.
        expectDeviceLink(BLEConnection.self)
        expectByteLink(BLEConnection.self)
    }

    /// `DeviceLink` adds an explicit write mode. Transports without one (the
    /// mock, and any future transport) fall back to the plain write.
    func testDefaultModeAwareWriteForwardsToPlainWrite() async throws {
        let link: any DeviceLink = FakeDeviceLink()
        try await link.write(Data([0x01, 0x02, 0x03]), mode: .withoutResponse)
        try await link.write(Data([0x04]), mode: .withResponse)

        let fake = try XCTUnwrap(link as? FakeDeviceLink)
        XCTAssertEqual(fake.writtenPayloads, [Data([0x01, 0x02, 0x03]), Data([0x04])])
    }

    func testDeviceLinkExposesMTUForTheDiagnosticsView() {
        let link: any DeviceLink = FakeDeviceLink()
        XCTAssertEqual(link.maximumWritePayloadLength, 182)
        XCTAssertEqual(link.maximumWritePayloadLengthWithoutResponse, 182)
        XCTAssertEqual(link.device.name, "Fake")
    }

    // MARK: - Compile-time helpers

    private func expectDeviceLink<T: DeviceLink>(_: T.Type) {}
    private func expectByteLink<T: BLELink>(_: T.Type) {}
}

/// Minimal `DeviceLink` with no CoreBluetooth dependency. It also documents the
/// shape the mock transport will implement.
private final class FakeDeviceLink: DeviceLink, @unchecked Sendable {
    let device = DiscoveredDevice(id: UUID(), name: "Fake")
    let inbound: AsyncStream<Data>

    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var storage: [Data] = []

    init() {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.inbound = stream
        self.inboundContinuation = continuation
    }

    var writtenPayloads: [Data] { lock.withLock { storage } }
    var maximumWritePayloadLength: Int { 182 }
    var maximumWritePayloadLengthWithoutResponse: Int { 182 }

    func write(_ data: Data) async throws {
        lock.withLock { storage.append(data) }
    }

    func close() async {
        inboundContinuation.finish()
    }

    func observeState() -> AsyncStream<ConnectionState> {
        AsyncStream { continuation in
            continuation.yield(.ready)
            continuation.finish()
        }
    }
}
