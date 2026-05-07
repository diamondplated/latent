import SwiftUI

// Minimal SwiftUI entry point.
//
// Caveat: built from a Swift Package executable target, so the resulting
// binary doesn't get a proper bundle ID, app icon, code signing, or sandbox
// entitlements. It launches and works, but for App Store distribution this
// gets migrated to an Xcode project (separate milestone).

@main
struct PhotoViewerApp: App {
    var body: some Scene {
        WindowGroup("Latent") {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}  // no "New" menu item
        }
    }
}
