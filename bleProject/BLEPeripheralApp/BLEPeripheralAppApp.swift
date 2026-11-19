import SwiftUI
import CoreBluetooth

@main
struct BLEPeripheralAppApp: App {
    @StateObject
    private var peripheralManager = PeripheralManager()

    var body: some Scene {
        WindowGroup {
            ContentView(peripheralManager: peripheralManager)
                .frame(minWidth: 860, minHeight: 560)
        }

        Window("Received Data", id: "received-data") {
            ReceivedDataPanel(peripheralManager: peripheralManager)
                .frame(minWidth: 620, minHeight: 480)
        }
        .defaultSize(width: 760, height: 620)
    }
}
