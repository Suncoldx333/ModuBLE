import SwiftUI

@main
struct ModuBLEDemoApp: App {
    @StateObject
    private var model = DemoModel()

    var body: some Scene {
        WindowGroup {
            DemoView(model: model)
        }
    }
}
