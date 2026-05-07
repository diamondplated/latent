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
        // Single Window (not WindowGroup): Latent is a viewer, one library
        // at a time — there's no useful "second window of the same app"
        // mode. Using Window instead of WindowGroup also fixes a Finder
        // integration: right-click an image → Open With → Latent used to
        // spawn a *new* window because WindowGroup creates one per
        // open-event; now it routes through onOpenURL on the existing
        // window.
        Window("Latent", id: "main") {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}  // no "New" menu item
        }
    }
}
