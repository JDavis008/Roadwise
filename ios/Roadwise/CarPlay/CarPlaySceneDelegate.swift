import CarPlay
import UIKit

/// CarPlay entry point (navigation category). The car gets its own window for the map; the
/// phone keeps its SwiftUI WindowGroup. Both share AppModel.shared.
///
/// CarPlay only lists Roadwise when the app is signed with Apple's
/// `com.apple.developer.carplay-maps` entitlement (Roadwise.entitlements); see ios/CARPLAY.md.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController, to window: CPWindow) {
        controller = CarPlayController(interface: interfaceController, window: window, app: AppModel.shared)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnect interfaceController: CPInterfaceController, from window: CPWindow) {
        controller?.disconnect()
        controller = nil
    }
}
