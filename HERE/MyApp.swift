import SwiftUI

@main
struct HEREApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .tint(.hereAccent)
        }
    }
}
