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
                EmptyStateView(state: state)
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
    @Bindable var state: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                if !state.recents.entries.isEmpty {
                    recentsList
                        .padding(.top, 24)
                }
            }
            .frame(maxWidth: 520)
            .padding(40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { state.recents.refreshExistence() }
    }

    private var hero: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Open a folder of photos to begin")
                .font(.title2)
            Text("Latent browses folders directly — no library import.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Folder…") { state.openFolder() }
                .controlSize(.large)
                .keyboardShortcut("o", modifiers: .command)
                .padding(.top, 8)
        }
    }

    private var recentsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent")
                    .font(.headline)
                Spacer()
                Button("Clear All") { state.recents.removeAll() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 4) {
                ForEach(state.recents.entries, id: \.self) { url in
                    RecentRow(
                        url: url,
                        isStale: state.recents.stale.contains(url),
                        onOpen: { Task { await state.loadFolder(url) } },
                        onRemove: { state.recents.remove(url) }
                    )
                }
            }
        }
    }
}

/// One row in the empty-state recent list. Click anywhere → open. The X on
/// the right is a separate target that removes without opening.
struct RecentRow: View {
    let url: URL
    let isStale: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var hovered: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isStale ? "questionmark.folder" : "folder")
                .font(.system(size: 16))
                .foregroundStyle(isStale ? .secondary : Color.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isStale ? .secondary : .primary)
                    .lineLimit(1)
                Text(prettyParentPath(url))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Show the X only on hover so the row stays clean visually but
            // remove is one click away when needed.
            if hovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from recents")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(hovered ? Color.secondary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
        .opacity(isStale ? 0.55 : 1.0)
        .onTapGesture {
            // Don't open a stale entry — likely just confuses the loader
            // with a missing path.
            guard !isStale else { return }
            onOpen()
        }
        .help(isStale ? "Folder no longer exists" : url.path)
    }

    private func prettyParentPath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let parent = url.deletingLastPathComponent().path
        if parent.hasPrefix(home) { return "~" + parent.dropFirst(home.count) }
        return parent
    }
}
