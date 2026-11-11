import SwiftUI

@main
struct FM1App: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.live)
                .environmentObject(model.catalog)
                .task { await model.start() }
                .onOpenURL { url in
                    if url.pathExtension == "fm1" { model.open(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // Audio keeps running in the background (UIBackgroundModes: audio);
            // just make sure nothing is lost if iOS kills us later.
            if phase == .background { model.save() }
        }
    }
}
