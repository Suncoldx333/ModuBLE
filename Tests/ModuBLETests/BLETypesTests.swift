import XCTest
import CoreBluetooth
@testable import ModuBLE

final class BLETypesTests: XCTestCase {
    func testManagerStateMapsToActionableErrors() {
        XCTAssertEqual(BLECentralManager.error(for: .poweredOff), .bluetoothOff)
        XCTAssertEqual(BLECentralManager.error(for: .unauthorized), .bluetoothUnauthorized)
        XCTAssertEqual(BLECentralManager.error(for: .unsupported), .bluetoothUnsupported)
        XCTAssertEqual(BLECentralManager.error(for: .resetting), .bluetoothResetting)
        XCTAssertEqual(BLECentralManager.error(for: .unknown), .bluetoothResetting)
    }

    func testConnectionStateBusyFlags() {
        XCTAssertTrue(ConnectionState.connecting.isBusy)
        XCTAssertTrue(ConnectionState.discovering.isBusy)
        XCTAssertFalse(ConnectionState.ready.isBusy)
        XCTAssertFalse(ConnectionState.disconnected.isBusy)
        XCTAssertFalse(ConnectionState.failed("x").isBusy)
    }

    func testConnectionStateLabels() {
        XCTAssertEqual(ConnectionState.ready.label, "Ready")
        XCTAssertEqual(ConnectionState.failed("boom").label, "Failed: boom")
    }

    func testReferenceProfileMatchesDocumentedPeripheral() {
        let profile = GATTProfile.referencePeripheral
        XCTAssertEqual(profile.serviceUUID, "5A0C8B3E-7D2F-4A6B-9C1D-3E5F7A9B1C2D")
        XCTAssertEqual(profile.rxCharacteristicUUID, "9F8E7D6C-5B4A-3F2E-8D7C-6B5A4F3E2D1C")
        XCTAssertEqual(profile.txCharacteristicUUID, "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C5D")
        // The peripheral exposes both write types; requests give us flow control.
        XCTAssertEqual(profile.writeMode, .withResponse)
    }

    func testProfileUUIDsAreNormalised() {
        let profile = GATTProfile(
            serviceUUID: "5a0c8b3e-7d2f-4a6b-9c1d-3e5f7a9b1c2d",
            rxCharacteristicUUID: "9f8e7d6c-5b4a-3f2e-8d7c-6b5a4f3e2d1c",
            txCharacteristicUUID: "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d"
        )
        XCTAssertEqual(profile.serviceUUID, profile.serviceUUID.uppercased())
        XCTAssertEqual(profile.writeMode, .automatic)
    }

    func testBluetoothStateMapping() {
        XCTAssertEqual(BLECentralManager.bluetoothState(for: .poweredOn), .poweredOn)
        XCTAssertEqual(BLECentralManager.bluetoothState(for: .poweredOff), .poweredOff)
        XCTAssertEqual(BLECentralManager.bluetoothState(for: .unauthorized), .unauthorized)
        XCTAssertEqual(BLECentralManager.bluetoothState(for: .unsupported), .unsupported)
        XCTAssertEqual(BLECentralManager.bluetoothState(for: .resetting), .resetting)
        XCTAssertEqual(BLECentralManager.bluetoothState(for: .unknown), .unknown)
    }

    func testBluetoothStateUserFacingMessages() {
        XCTAssertTrue(BluetoothState.poweredOn.isReady)
        XCTAssertFalse(BluetoothState.poweredOff.isReady)
        XCTAssertNil(BluetoothState.poweredOn.problemDescription)
        XCTAssertNil(BluetoothState.unknown.problemDescription)
        XCTAssertNotNil(BluetoothState.poweredOff.problemDescription)
        XCTAssertNotNil(BluetoothState.unauthorized.problemDescription)
        XCTAssertNotNil(BluetoothState.unsupported.problemDescription)
    }

    func testDiscoveredDeviceDisplayNameFallsBackToIdentifier() {        let id = UUID()
        let device = DiscoveredDevice(id: id)
        XCTAssertEqual(device.displayName, id.uuidString)

        var named = device
        named.name = "MacBLE"
        XCTAssertEqual(named.displayName, "MacBLE")
    }
}
