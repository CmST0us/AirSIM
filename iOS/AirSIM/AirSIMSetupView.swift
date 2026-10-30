import SwiftUI

struct AirSIMFirstConnectionView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("airsim.first-connection-complete", store: UITestScenario.defaults) private var completed = false
    @State private var presentation: V2SettingsSheet?

    var body: some View {
        NavigationStack {
            if let cloud = model.cloudV2 {
                Form {
                    V2ConnectionSections(model: cloud, presentation: $presentation)
                    Section { Button("完成，进入 AirSIM") { completed = true } }
                }
                .navigationTitle("连接 AirSIM")
                .sheet(item: $presentation) { $0.content(model: cloud) }
            }
        }
    }
}

struct AirSIMSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let cloud = model.cloudV2 {
            A1CardsView(cloud: cloud)
        }
    }
}
