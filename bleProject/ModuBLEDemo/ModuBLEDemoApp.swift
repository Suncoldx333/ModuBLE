import SwiftUI

@main
struct ModuBLEDemoApp: App {
    @StateObject
    private var coordinator = DeviceCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView(coordinator: coordinator)
        }
    }
}
