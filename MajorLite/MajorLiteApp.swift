import SwiftUI

@main
struct MajorLiteApp: App {
    @State private var store = DeviceStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}
