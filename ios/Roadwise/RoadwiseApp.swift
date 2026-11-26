import SwiftUI

@main
struct RoadwiseApp: App {
    // One model for the phone and the CarPlay screen, so a trip started on either shows on both.
    @StateObject private var app = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.settings)
        }
    }
}
