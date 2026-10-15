import SwiftUI

@main
@MainActor
struct FitcoreApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if let message = store.configurationError {
                    ContentUnavailableView("配置需要调整", systemImage: "gearshape", description: Text(message))
                } else {
                    RootView().environmentObject(store)
                }
            }
            .tint(FitcoreTheme.accent)
            .preferredColorScheme(.light)
            .onChange(of: scenePhase, initial: true) { _, next in
                if next == .active { Task { await store.sceneDidBecomeActive() } }
            }
        }
    }
}
