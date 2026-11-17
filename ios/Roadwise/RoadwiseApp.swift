import SwiftUI

@main
struct RoadwiseApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.settings)
        }
    }
}
