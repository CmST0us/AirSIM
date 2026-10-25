import SwiftUI

@main
struct AirSIMIPadApp: App {
    @UIApplicationDelegateAdaptor(AirSIMNotificationDelegate.self) private var appDelegate
    @StateObject private var router = AppRouteCoordinator.shared
    var body: some Scene {
        WindowGroup { AirSIMRouteView().environmentObject(router).defaultAppStorage(R7UITestScenario.defaults) }
    }
}
