import SwiftUI
import AppKit

// Minimal SwiftUI entry point.
//
// `swift run Latent` launches the bare SwiftPM executable. For Finder use,
// scripts/build_app.sh wraps it in a bundle with the real bundle ID, icon,
// document declarations, and an ad-hoc signature by default (or Developer ID
// signing when explicitly configured). Sandboxing, notarization/stapling, and
// App Store distribution still need a dedicated release workflow.

@MainActor
final class LatentLifecycleDelegate: NSObject, NSApplicationDelegate {
    var flushBeforeTermination: (() -> Bool)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard flushBeforeTermination?() != false else {
            // Keep the process — and its app-scoped AppState — alive. Bring the
            // existing SwiftUI window back so its persistence alert is visible
            // and the user can retry after fixing the destination.
            sender.activate(ignoringOtherApps: true)
            sender.windows.first(where: { $0.canBecomeKey })?
                .makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        return .terminateNow
    }
}

@main
struct PhotoViewerApp: App {
    @NSApplicationDelegateAdaptor(LatentLifecycleDelegate.self)
    private var lifecycleDelegate
    /// App-scoped ownership preserves unsaved culling state if the sole window
    /// closes after a disk failure. Reopening the window reuses this instance;
    /// application termination is separately vetoed until its flush succeeds.
    @State private var state = AppState()

    var body: some Scene {
        // Single Window (not WindowGroup): Latent is a viewer, one library
        // at a time — there's no useful "second window of the same app"
        // mode. Using Window instead of WindowGroup also fixes a Finder
        // integration: right-click an image → Open With → Latent used to
        // spawn a *new* window because WindowGroup creates one per
        // open-event; now it routes through onOpenURL on the existing
        // window.
        Window("Latent", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 800, minHeight: 600)
                .onAppear {
                    lifecycleDelegate.flushBeforeTermination = { [weak state] in
                        state?.flushCullingState() ?? true
                    }
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}  // no "New" menu item
        }
    }
}
