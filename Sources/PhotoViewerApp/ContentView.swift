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
        // Right-click in Finder → "Open With → Latent" delivers the URL
        // here. Works for both folders (open as a folder) and individual
        // images (open the parent folder, jump to the clicked image).
        .onOpenURL { url in
            Task { await openExternal(url: url) }
        }
    }

    @MainActor
    private func openExternal(url: URL) async {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir {
            await state.loadFolder(url)
        } else {
            // File: load its parent and select the file.
            let parent = url.deletingLastPathComponent()
            await state.loadFolder(parent)
            // After loadFolder completes, the URL list is set; jump to the
            // clicked image if it's there.
            state.select(url: url)
        }
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
