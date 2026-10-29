import SwiftUI

@main
struct BridgeDropApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacApplicationDelegate.self) private var appDelegate
    #endif
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task {
                    #if os(macOS)
                    model.start()
                    #endif
                    // iOS starts only on explicit action or confirmed import. Scene activation
                    // may precede onOpenURL on a cold/warm URL launch; never auto-connect here.
                }
                .onOpenURL { url in model.receivePairingInput(url.absoluteString) }
                .onChange(of: scenePhase) { phase in
                    #if os(iOS)
                    if phase == .background {
                        model.stop()
                    }
                    #endif
                }
        }
        #if os(macOS)
        .defaultSize(width: 960, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #endif
    }
}
