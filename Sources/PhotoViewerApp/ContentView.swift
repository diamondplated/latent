import SwiftUI

struct ContentView: View {
    @State private var state = AppState()
    /// Window-level arrow-key monitor. Lives at the ContentView level so it
    /// installs as soon as the app launches, not only after a folder opens —
    /// otherwise arrow keys do nothing on the first folder you load (the
    /// monitor's host view is still in empty state).
    @State private var keyMonitor = NavigationKeyMonitor()

    var body: some View {
        Group {
            if state.folder == nil {
                EmptyStateView { state.openFolder() }
            } else {
                BrowserView(state: state)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.openFolder()
                } label: {
                    Label("Open Folder…", systemImage: "folder")
                }
            }
        }
        .onAppear { keyMonitor.install(state: state) }
        .onDisappear { keyMonitor.uninstall() }
    }
}

struct EmptyStateView: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Open a folder of photos to begin")
                .font(.title2)
            Text("Latent browses folders directly — no library import.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Folder…") { onOpen() }
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
                .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
