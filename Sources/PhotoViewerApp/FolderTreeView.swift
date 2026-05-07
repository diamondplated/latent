import SwiftUI
import AppKit

/// Recursive tree node for the folder explorer. Children are lazy — we only
/// `stat` a directory's contents the first time the user expands it. With
/// thousands of nested folders under ~/Pictures, eager expansion would freeze
/// the open path; lazy lets the tree render the root instantly and pay the
/// I/O cost only as the user drills in.
@MainActor
@Observable
final class FolderNode: Identifiable, Hashable {
    let url: URL
    /// `nil` = haven't loaded yet; `[]` = loaded and empty (a "leaf").
    private(set) var children: [FolderNode]?
    /// Persisted across re-renders so the disclosure state survives even when
    /// the parent re-builds the tree on a folder change.
    var isExpanded: Bool = false

    nonisolated var id: URL { url }
    nonisolated var name: String { url.lastPathComponent }

    /// True if we already inspected this dir for child folders. Used by the
    /// row to decide whether to draw a chevron at all (leaves don't need
    /// one) without forcing a load on every render.
    var isLoaded: Bool { children != nil }

    init(url: URL) {
        self.url = url
    }

    func loadChildrenIfNeeded() {
        guard children == nil else { return }
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        children = items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !Self.skipDir(name: $0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { FolderNode(url: $0) }
    }

    /// Re-stat the directory and merge new entries / drop missing ones. Used
    /// after a folder is opened so the tree reflects fs state without
    /// reloading the whole subtree.
    func refreshChildren() {
        let prev = children
        children = nil
        loadChildrenIfNeeded()
        // Preserve isExpanded for nodes that survived.
        if let prev, let now = children {
            let prevByURL = Dictionary(uniqueKeysWithValues: prev.map { ($0.url, $0) })
            for node in now {
                if let old = prevByURL[node.url] {
                    node.isExpanded = old.isExpanded
                    node.children = old.children
                }
            }
        }
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
        .onAppear { rebuildTree(for: state.anchorFolder) }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Folders")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                rootNode?.refreshChildren()
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

    private func rebuildTree(for anchor: URL?) {
        guard let anchor else { rootNode = nil; return }
        let node = FolderNode(url: anchor)
        node.isExpanded = true        // root expanded by default
        node.loadChildrenIfNeeded()
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
            Spacer(minLength: 0)
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
                node.loadChildrenIfNeeded()
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
