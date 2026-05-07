import SwiftUI
import AppKit

/// Sort order for folder rows in the tree sidebar. Owned by AppState
/// (`state.folderSort`) and persisted across launches.
enum FolderSort: String, CaseIterable, Sendable, Identifiable {
    /// Locale-aware alphabetical, the default. Same comparator as Finder.
    case nameAscending
    /// Newest contentModificationDate at the top. For folders this reflects
    /// when the folder was last MODIFIED (file added, removed, renamed) —
    /// which for photo dumps is exactly "when did I last shoot here".
    case modifiedDescending

    var id: String { rawValue }
    var label: String {
        switch self {
        case .nameAscending:       "Name"
        case .modifiedDescending:  "Recently Modified"
        }
    }
    var symbol: String {
        switch self {
        case .nameAscending:       "textformat"
        case .modifiedDescending:  "clock"
        }
    }
}

/// Recursive tree node for the folder explorer. Children are lazy — we only
/// `stat` a directory's contents the first time the user expands it. With
/// thousands of nested folders under ~/Pictures, eager expansion would freeze
/// the open path; lazy lets the tree render the root instantly and pay the
/// I/O cost only as the user drills in.
@MainActor
@Observable
final class FolderNode: Identifiable, Hashable {
    let url: URL
    /// Captured at directory-listing time so a switch to mtime-sort doesn't
    /// have to re-stat every folder. We piggyback on the
    /// `contentsOfDirectory` call's `includingPropertiesForKeys:` prefetch
    /// — one syscall pulls names AND mtimes for the parent's whole listing
    /// at once, way cheaper than per-URL stats.
    let mtime: Date
    /// `nil` = haven't loaded yet; `[]` = loaded and empty (a "leaf").
    private(set) var children: [FolderNode]?
    /// Persisted across re-renders so the disclosure state survives even when
    /// the parent re-builds the tree on a folder change.
    var isExpanded: Bool = false
    /// Image count for this folder's direct contents. `nil` = not measured
    /// yet — populated lazily on first row appearance via `loadPhotoCountIfNeeded`.
    /// Eager-counting at tree build time would re-stat thousands of dirs the
    /// user may never expand.
    private(set) var photoCount: Int?

    nonisolated var id: URL { url }
    nonisolated var name: String { url.lastPathComponent }

    /// True if we already inspected this dir for child folders. Used by the
    /// row to decide whether to draw a chevron at all (leaves don't need
    /// one) without forcing a load on every render.
    var isLoaded: Bool { children != nil }

    init(url: URL, mtime: Date = .distantPast) {
        self.url = url
        self.mtime = mtime
    }

    func loadChildrenIfNeeded(sort: FolderSort) {
        guard children == nil else { return }
        let fm = FileManager.default
        // Prefetch isDirectory + contentModificationDate together so we
        // don't pay an extra stat-per-URL when sort==.modifiedDescending.
        let items = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        var nodes: [FolderNode] = []
        for child in items {
            guard let vals = try? child.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  vals.isDirectory == true,
                  !Self.skipDir(name: child.lastPathComponent) else { continue }
            nodes.append(FolderNode(url: child, mtime: vals.contentModificationDate ?? .distantPast))
        }
        children = Self.sortNodes(nodes, by: sort)
    }

    /// Resort this node's loaded children + recurse into already-loaded
    /// subtrees. Called when the user flips the sort menu — no fs work,
    /// just a re-arrangement of the in-memory tree (mtimes were already
    /// captured at load time).
    func resort(by sort: FolderSort) {
        guard children != nil else { return }
        children = Self.sortNodes(children ?? [], by: sort)
        if let kids = children {
            for k in kids where k.isLoaded {
                k.resort(by: sort)
            }
        }
    }

    private static func sortNodes(_ nodes: [FolderNode], by sort: FolderSort) -> [FolderNode] {
        switch sort {
        case .nameAscending:
            return nodes.sorted {
                $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
        case .modifiedDescending:
            return nodes.sorted { $0.mtime > $1.mtime }
        }
    }

    /// Stat the directory's direct contents and count files matching
    /// Latent's media extensions. Run once per folder, lazily on first row
    /// appearance — the badge in the tree is the visible payoff. Off the
    /// main actor so a deep tree doesn't stutter while badges populate.
    func loadPhotoCountIfNeeded() async {
        guard photoCount == nil else { return }
        let folderURL = url
        let exts = AppState.imageExtensions
        let count = await Task.detached(priority: .background) {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            return items.reduce(0) { acc, u in
                acc + (exts.contains(u.pathExtension.lowercased()) ? 1 : 0)
            }
        }.value
        photoCount = count
    }

    /// Re-stat the directory and merge new entries / drop missing ones. Used
    /// after a folder is opened so the tree reflects fs state without
    /// reloading the whole subtree.
    func refreshChildren(sort: FolderSort) {
        let prev = children
        children = nil
        loadChildrenIfNeeded(sort: sort)
        // Preserve isExpanded + cached photoCount for nodes that survived.
        // (mtime is `let`-captured fresh on the new nodes; it's by definition
        // up-to-date because the new nodes came from a fresh stat.)
        if let prev, let now = children {
            let prevByURL = Dictionary(uniqueKeysWithValues: prev.map { ($0.url, $0) })
            for node in now {
                if let old = prevByURL[node.url] {
                    node.isExpanded = old.isExpanded
                    node.children = old.children
                    node.photoCount = old.photoCount
                }
            }
        }
    }

    /// Splice a single descendant out by URL — used after a folder trash.
    /// Single DFS through whatever children we've already loaded; finds
    /// the matching node and removes it from its parent's array. Returns
    /// true if the URL was found and removed.
    ///
    /// This replaces the previous `recursiveRefresh()` approach. That one
    /// re-stated every loaded folder via `contentsOfDirectory` on main —
    /// for a deeply-expanded tree that was dozens of fs syscalls in
    /// sequence, hanging the app for seconds after every trash. Targeted
    /// removal does no fs work at all; it just walks the in-memory tree.
    @discardableResult
    func removeNode(withURL target: URL) -> Bool {
        // Direct child? Splice it out and we're done — the trashed
        // folder's own subtree (if loaded) gets garbage-collected with it.
        if let kids = children, let idx = kids.firstIndex(where: { $0.url == target }) {
            children?.remove(at: idx)
            return true
        }
        // Recurse into loaded subtrees only. Collapsed/unloaded branches
        // can't possibly contain the row the user just right-clicked
        // (clicking required walking through the parent), so this DFS is
        // bounded by what the user has actually expanded.
        if let kids = children {
            for k in kids {
                if k.removeNode(withURL: target) { return true }
            }
        }
        return false
    }

    /// Drop common noise — Photos library packages, version-control dirs,
    /// node_modules-style dumps. We already pass .skipsPackageDescendants
    /// to FileManager which kills .photoslibrary descent, but list-name
    /// filtering is a belt-and-suspenders for anything else.
    private static func skipDir(name: String) -> Bool {
        let bad: Set<String> = [
            "__MACOSX", ".git", ".DS_Store",
            "node_modules", ".Trash", ".Spotlight-V100", ".fseventsd",
        ]
        if bad.contains(name) { return true }
        if name.hasSuffix(".photoslibrary") { return true }
        return false
    }

    nonisolated static func == (lhs: FolderNode, rhs: FolderNode) -> Bool {
        lhs.url == rhs.url
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

// MARK: - View

/// Sidebar tree of folders. Click a row to load that folder's photos. Click
/// the disclosure chevron (or single-click an already-selected row) to
/// expand and see subfolders. Rooted at `state.anchorFolder` so it reflects
/// whatever the user picked from the Open dialog or Recents.
struct FolderTreeView: View {
    @Bindable var state: AppState
    /// Cached node tree, keyed by anchor folder so switching anchors rebuilds.
    @State private var rootNode: FolderNode? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let rootNode {
                        FolderRowView(node: rootNode, depth: 0, state: state)
                    } else {
                        Text("Open a folder to start browsing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(.background.secondary)
        .onChange(of: state.anchorFolder) { _, new in
            rebuildTree(for: new)
        }
        // After a folder is trashed, AppState bumps `folderTreeChangeTick`
        // and stashes the URL in `lastRemovedFolder`. Splice that one node
        // out of the in-memory tree. No fs walks, no per-node restats —
        // the previous recursive-refresh pass was hanging the app for
        // seconds on deeply-expanded trees.
        .onChange(of: state.folderTreeChangeTick) { _, _ in
            guard let removed = state.lastRemovedFolder else { return }
            // If the trashed folder WAS the tree's root, closeFolder()
            // has already nilled anchorFolder and the anchor handler
            // resets the tree. Targeted removal can't help us here.
            if rootNode?.url == removed { return }
            rootNode?.removeNode(withURL: removed)
        }
        // Sort change → in-memory re-arrange of every loaded subtree. No fs
        // work because mtimes were captured at load time.
        .onChange(of: state.folderSort) { _, new in
            rootNode?.resort(by: new)
        }
        .onAppear { rebuildTree(for: state.anchorFolder) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Folders")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            sortMenu
            Button {
                rootNode?.refreshChildren(sort: state.folderSort)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Rescan folder contents")
            .disabled(rootNode == nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Header sort picker. macOS native menu w/ checkmark on the active
    /// option courtesy of `Picker` inside `Menu`.
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $state.folderSort) {
                ForEach(FolderSort.allCases) { sort in
                    Label(sort.label, systemImage: sort.symbol).tag(sort)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort folders")
    }

    private func rebuildTree(for anchor: URL?) {
        guard let anchor else { rootNode = nil; return }
        // Pull the anchor's own mtime so it sorts correctly if it ever
        // appears as a child of something (currently it doesn't, but the
        // node is part of a uniform model — better than .distantPast).
        let mtime = (try? anchor.resourceValues(forKeys: [.contentModificationDateKey])
                     .contentModificationDate) ?? .distantPast
        let node = FolderNode(url: anchor, mtime: mtime)
        node.isExpanded = true        // root expanded by default
        node.loadChildrenIfNeeded(sort: state.folderSort)
        rootNode = node
    }
}

/// A single row in the tree. Renders a disclosure chevron (only when the
/// node has children we know about), an indent based on depth, the folder
/// icon, and the name. Clicking the row LOADS the folder; clicking the
/// chevron just expands without changing the active folder.
struct FolderRowView: View {
    @Bindable var node: FolderNode
    let depth: Int
    @Bindable var state: AppState

    private var isSelected: Bool { state.folder == node.url }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if node.isExpanded, let children = node.children {
                ForEach(children) { child in
                    FolderRowView(node: child, depth: depth + 1, state: state)
                }
            }
        }
    }

    private var row: some View {
        HStack(spacing: 4) {
            // Indent rule: 12pt per level. Plus a fixed-width chevron slot
            // even on leaves so names line up cleanly.
            Spacer().frame(width: CGFloat(depth) * 12)
            chevron
            Image(systemName: "folder")
                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                .font(.system(size: 12))
            Text(node.name)
                .font(.system(.callout))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            // Photo count for this folder's direct contents — lets the user
            // tell at a glance which folder in a 100-deep tree actually has
            // pictures. Lazy: starts nil (no badge), populates after a
            // background stat. We hide the badge for empty folders to keep
            // the tree clean.
            if let count = node.photoCount, count > 0 {
                Text("\(count)")
                    .font(.system(.caption2, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(isSelected
                                       ? Color.white.opacity(0.18)
                                       : Color.secondary.opacity(0.15))
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSelected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        // Tree-driven loads:
        //   - Don't reset the anchor (tree stays pinned where the user
        //     originally opened, so they can drill + back out freely).
        //   - Don't recurse (the tree IS the navigation; recursing into
        //     subfolders would defeat the point — clicking a parent would
        //     show the same flat photo list as any descendant).
        .onTapGesture {
            Task { await state.loadFolder(node.url, setAsAnchor: false, recursive: false) }
        }
        // Right-click affordances. "Move to Trash" is the headline ask but
        // surfacing Reveal in Finder + the recurse-this-subtree option in
        // the same menu makes the tree a much fuller-fledged file browser.
        .contextMenu {
            Button {
                Task { await state.loadFolder(node.url, setAsAnchor: false, recursive: false) }
            } label: {
                Label("Open", systemImage: "folder")
            }
            Button {
                Task { await state.loadFolder(node.url, setAsAnchor: false, recursive: true) }
            } label: {
                Label("Open with Subfolders", systemImage: "square.3.layers.3d.down.right")
            }
            Divider()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            } label: {
                Label("Reveal in Finder", systemImage: "magnifyingglass")
            }
            Divider()
            Button(role: .destructive) {
                state.trashFolder(at: node.url)
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
        // Kicks off the lazy photo-count stat. .task auto-cancels if the
        // row scrolls offscreen before the stat returns.
        .task(id: node.url) {
            await node.loadPhotoCountIfNeeded()
        }
    }

    @ViewBuilder
    private var chevron: some View {
        // Only show a chevron if there's something to expand. We have to
        // peek (loadChildrenIfNeeded) in cases where the node is collapsed
        // but the tree wants to show whether it has subfolders. Doing a
        // sync stat per row on render would scale badly — instead, use a
        // lightweight check that returns early if we already know.
        if !node.isLoaded {
            // Show a chevron speculatively. Click loads + expands.
            Button {
                node.loadChildrenIfNeeded(sort: state.folderSort)
                node.isExpanded.toggle()
            } label: {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        } else if let kids = node.children, !kids.isEmpty {
            Button {
                node.isExpanded.toggle()
            } label: {
                Image(systemName: node.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        } else {
            // Leaf — empty fixed-width spot to keep alignment.
            Spacer().frame(width: 12, height: 12)
        }
    }
}
