import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotoIO

/// Holds the currently-selected folder and the list of image URLs in it.
/// Watches the folder for changes via DispatchSource so adds/removes update
/// the grid in near-real-time.
///
/// Composes `SelectionManager` and `TrashManager` for focused state
/// management. Backward-compatible API wrappers delegate to the sub-objects.
@MainActor
@Observable
final class AppState {
    /// Folder currently being browsed (or the temp dir produced by archive
    /// extraction when the user opened an archive).
    var folder: URL? = nil
    /// Image URLs in `folder` and any subfolders, sorted by relative path.
    var imageURLs: [URL] = []

    // MARK: - Composed sub-objects

    /// Selection state: single-select, multi-select, navigation.
    let selection = SelectionManager()
    /// Trash & undo state: trash history ring, optimistic removal, restore.
    let trash = TrashManager()

    // MARK: - Delegation wrappers (backward compatibility)

    /// Forwarded from SelectionManager for views that read directly.
    var selectedIndex: Int? {
        get { selection.selectedIndex }
        set { selection.selectedIndex = newValue }
    }
    var multiSelection: Set<URL> {
        get { selection.multiSelection }
        set { selection.multiSelection = newValue }
    }
    var currentURL: URL? { selection.currentURL }

    /// True while the folder is being scanned. Computed from `loadPhase` so
    /// every loading-related field stays in lockstep — no chance of
    /// `isLoading=true` with a stale `loadPhase=nil` or vice versa.
    var isLoading: Bool { loadPhase != nil }
    /// Structured "what's happening right now" so the loader UI can render a
    /// rich, contextual scene instead of a plain spinner.
    var loadPhase: LoadPhase? = nil
    /// Last error surface (extraction failed, etc.) — UI can show in a toast.
    var lastError: String? = nil
    /// MRU list of opened folders — drives the empty-state Recent panel.
    /// Shared singleton so the empty state and any future "Open Recent" menu
    /// stay in sync.
    let recents = RecentFolders()
    /// Speculative full-res decoder for the current selection ± neighbors.
    /// Owned here so trashImage / closeFolder can poke it. The prefetch
    /// window is updated by BrowserView when selectedIndex changes.
    let prefetcher = ImagePrefetcher(capacity: 5)

    /// Whether the enhancement side panel is visible. Default false: the app
    /// is primarily a viewer; enhancement is opt-in. Toolbar button toggles.
    var showEnhancementPanel: Bool = false
    /// Whether the folder-tree sidebar (far-left pane) is visible. Default
    /// false to keep the layout simple for new users; toolbar button toggles.
    var showFolderTree: Bool = false
    /// Sort order applied to folders in the tree sidebar. Persisted across
    /// launches because it's the kind of preference you set once. Default
    /// is alphabetical; "Recently Modified" is the choice for users who
    /// want the latest shoot at the top of their tree.
    var folderSort: FolderSort = .nameAscending {
        didSet { UserDefaults.standard.set(folderSort.rawValue, forKey: "Latent.FolderSort") }
    }
    /// Sort order applied to photos in the grid. Same enum as folderSort —
    /// the cases are conceptually identical (Name asc / Modified desc).
    /// Changes re-sort `imageURLs` in place; no fs work because
    /// contentModificationDate was prefetched during the walk.
    var photoSort: FolderSort = .nameAscending {
        didSet {
            UserDefaults.standard.set(photoSort.rawValue, forKey: "Latent.PhotoSort")
            // Keep the user's selection on the same photo across re-sort.
            let currentlySelected = currentURL
            if let basePath = folder?.path {
                imageURLs = Self.sortPhotos(imageURLs, by: photoSort, basePath: basePath)
            }
            if let url = currentlySelected, let i = imageURLs.firstIndex(of: url) {
                selectedIndex = i
            }
        }
    }

    init() {
        // Set backing fields directly so didSet doesn't re-write the value
        // we just read. (didSet still fires on init; the re-write is
        // harmless but pointless.)
        if let raw = UserDefaults.standard.string(forKey: "Latent.FolderSort"),
           let sort = FolderSort(rawValue: raw) {
            folderSort = sort
        }
        if let raw = UserDefaults.standard.string(forKey: "Latent.PhotoSort"),
           let sort = FolderSort(rawValue: raw) {
            photoSort = sort
        }
        // Wire up SelectionManager's URL source.
        selection.imageURLs = { [weak self] in self?.imageURLs ?? [] }
        // Wire up TrashManager callbacks.
        trash.onOptimisticRemove = { [weak self] urls in
            self?.optimisticallyRemoveImages(urls)
        }
        trash.onReinsertURLs = { [weak self] urls in
            self?.reinsertFailedTrashURLs(urls)
        }
        trash.onEvictPrefetch = { [weak self] url in
            self?.prefetcher.evict(url: url)
        }
        trash.onFolderTrashed = { [weak self] url in
            self?.handleFolderTrashSuccess(url)
        }
        trash.onRemoveRecent = { [weak self] url in
            self?.recents.remove(url)
        }
        trash.onRestoreFolder = { [weak self] url in
            guard let self else { return }
            Task {
                guard let currentFolder = self.folder else { return }
                let prefix = currentFolder.path.hasSuffix("/")
                    ? currentFolder.path
                    : currentFolder.path + "/"
                guard url.path == currentFolder.path || url.path.hasPrefix(prefix) else { return }
                let recursive = self.loadedRecursively
                let sort = self.photoSort
                let selectedURL = self.selectedIndex.flatMap { index in
                    index < self.imageURLs.count ? self.imageURLs[index] : nil
                }
                let urls = await Self.walkAndSort(currentFolder, recursive: recursive, sort: sort)
                guard self.folder == currentFolder else { return }
                self.imageURLs = urls
                self.selectedIndex = selectedURL.flatMap { urls.firstIndex(of: $0) }
                    ?? (urls.isEmpty ? nil : 0)
            }
        }
    }
    /// Root the folder tree displays from. Set to whatever the user picked
    /// in the Open dialog or Recents — clicking a subfolder in the tree
    /// updates `folder` but leaves anchor pinned, so the tree stays put as
    /// the user drills around. Distinct from `folder`, which is the active
    /// (photo-list) folder.
    var anchorFolder: URL? = nil

    /// What stage the folder/archive open is in. Used to drive the loader UI.
    enum LoadPhase: Equatable {
        /// We're shelling out to /usr/bin/unzip or /usr/bin/tar.
        case extracting(archiveName: String)
        /// We're recursively walking the (possibly archive-extracted) folder.
        /// `photosFound` updates live as the AsyncStream yields batches.
        case scanning(folderName: String, photosFound: Int)
    }

    private var fileWatcher: DispatchSourceFileSystemObject?
    private var extractedArchiveDir: URL?
    private var loadedRecursively: Bool = false
    private var watcherRescanTask: Task<Void, Never>? = nil
    private var scanTask: Task<Void, Never>? = nil
    private var scanGeneration: UInt64 = 0
    var folderTreeChangeTick: Int = 0
    private(set) var lastRemovedFolder: URL? = nil

    var userError: String? { lastError ?? trash.lastError }

    func clearUserError() {
        lastError = nil
        trash.lastError = nil
    }

    /// Everything Latent will pick up during a folder scan. Static images,
    /// animated images (GIF / APNG / animated HEIC etc.), and video formats
    /// AVFoundation can take a swing at. The actual playback decision is
    /// made later by `MediaTyping.detect` per file.
    static var imageExtensions: Set<String> { MediaTyping.allMediaExts }

    /// Where macOS saves screenshots. Reads the `com.apple.screencapture`
    /// `location` default that's set by ⌘⇧5 → Options → Save to. Falls
    /// back to `~/Desktop` (the system default). Used by the empty-state
    /// "Screenshots" quick-access button so triaging your screen capture
    /// pile is one click away.
    static var screenshotsFolderURL: URL {
        let defaults = UserDefaults(suiteName: "com.apple.screencapture")
        if let raw = defaults?.string(forKey: "location"), !raw.isEmpty {
            let expanded = NSString(string: raw).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    /// Open a folder/archive picker; on selection, scan (recursively) and
    /// watch the folder. Archive selections are extracted to a temp dir
    /// transparently.
    func openFolder() {
        let panel = NSOpenPanel()
        // Accept both folders and supported archive files in one panel.
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Open Folder or Archive of Photos"
        panel.message = "Choose a folder of photos or a .zip / .tar(.gz/.bz2/.xz) archive."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await openURL(url) }
    }

    /// Open an external URL from the panel, Finder, drag/drop, or future
    /// app delegate hooks. Directories and archives are first-class sources;
    /// individual files open their parent folder and jump selection to the
    /// file if it is part of the current media set.
    func openURL(_ url: URL) async {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if isDir || ArchiveExtractor.isArchive(url) {
            await loadFolder(url)
        } else {
            let parent = url.deletingLastPathComponent()
            if await loadFolder(parent) {
                select(url: url)
            }
        }
    }

    /// Open a folder.
    /// - Parameter setAsAnchor: When true (the default — used by the Open
    ///   dialog, Recents, drag-drop, and the right-click → Open With path),
    ///   pins this folder as the folder-tree's root so the tree shows from
    ///   here. When false (used by the folder-tree click handler itself),
    ///   only the active folder changes — the tree stays anchored.
    /// - Parameter recursive: When true, bulk-scan everything under the
    ///   folder. Default is FALSE — opening a parent of ~/Pictures used to
    ///   spin up a 100k-photo scan the user didn't ask for. The user opts
    ///   into recursion via the toolbar's "Include Subfolders" button (or
    ///   they navigate via the folder tree, which always loads
    ///   non-recursively).
    @discardableResult
    func loadFolder(_ url: URL, setAsAnchor: Bool = true, recursive: Bool = false) async -> Bool {
        scanGeneration &+= 1
        let generation = scanGeneration

        // Prevent the previous folder's watcher from committing into this load.
        stopWatching()

        // If a previous scan is still running (rare — user clicked a new
        // folder mid-scan), cancel it and wait for it to drain. The
        // generation bump above prevents that stale task from committing
        // into the new load.
        if let prev = scanTask {
            prev.cancel()
            await prev.value
        }
        guard generation == scanGeneration else { return false }
        scanTask = nil

        // Drop the old folder's prefetched images — the new folder's URLs
        // share no overlap, so cached entries are pure memory waste.
        prefetcher.clear()

        selectedIndex = nil
        lastError = nil
        if setAsAnchor { anchorFolder = url }

        // Clean up any previous extracted-archive dir so /tmp doesn't fill up
        // when the user opens several archives in a row.
        if let prev = extractedArchiveDir {
            try? FileManager.default.removeItem(at: prev)
            extractedArchiveDir = nil
        }

        // Resolve the folder we're going to scan: archive → extract first,
        // then treat the extraction dir as the source.
        let scanRoot: URL
        if ArchiveExtractor.isArchive(url) {
            loadPhase = .extracting(archiveName: url.lastPathComponent)
            do {
                let extractor = ArchiveExtractor()
                scanRoot = try await extractor.extract(url)
                guard generation == scanGeneration else {
                    try? FileManager.default.removeItem(at: scanRoot)
                    return false
                }
                extractedArchiveDir = scanRoot
            } catch {
                guard generation == scanGeneration else { return false }
                lastError = "\(error)"
                folder = nil
                imageURLs = []
                loadPhase = nil
                return false
            }
        } else {
            scanRoot = url
        }

        folder = scanRoot
        loadedRecursively = recursive
        // Push the user's ORIGINAL pick (which may be an archive file) to
        // the recents — re-opening from recents replays the same flow,
        // including extraction. Only push real, non-temp paths so cleaned-
        // up extraction dirs don't poison the list.
        recents.push(url)
        loadPhase = .scanning(folderName: scanRoot.lastPathComponent, photosFound: 0)

        // Walk on a background task we can cancel from `cancelScan()`.
        // `Task.isCancelled` checks inside the walk let the Stop button
        // bail out mid-enumeration on huge trees.
        let pathBase = scanRoot.path
        let folderName = scanRoot.lastPathComponent
        let recurse = recursive
        let sort = photoSort
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let raw = await Self.walkFolder(scanRoot, recursive: recurse) { [weak self] count in
                await MainActor.run { [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    guard self.scanTask?.isCancelled != true else { return }
                    self.loadPhase = .scanning(folderName: folderName, photosFound: count)
                }
            }
            // Sort off-main (10k+ paths or 10k+ stat lookups for mtime is
            // heavy enough that we never want to do it on main).
            let found = Self.sortPhotos(raw, by: sort, basePath: pathBase)
            // One atomic main-actor commit: imageURLs gets the full sorted
            // list (or partial, if cancelled), SwiftUI does ONE ForEach diff.
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.scanGeneration == generation else { return }
                self.imageURLs = found
                self.selectedIndex = found.isEmpty ? nil : 0
                self.loadPhase = nil
            }
        }
        scanTask = task
        await task.value
        guard generation == scanGeneration else { return false }
        scanTask = nil

        startWatching(scanRoot)
        return true
    }

    /// Cancel the in-flight folder scan. Whatever was found before cancel
    /// still commits — discarding partial results would punish the user
    /// for hitting Stop on a folder that already has plenty to look at.
    /// Clears `loadPhase` synchronously so the loader vanishes the
    /// instant Stop is clicked: the detached task is still draining
    /// (sorting partial results + main-actor commit), but the user
    /// shouldn't see the loader linger while that happens.
    func cancelScan() {
        scanTask?.cancel()
        loadPhase = nil
    }

    /// Navigate to the parent of the current folder. Re-roots the folder
    /// tree to the parent (setAsAnchor=true) — going up implies the user
    /// wants the tree to come along, otherwise they'd have just clicked
    /// elsewhere. No-op at filesystem root.
    func goUp() {
        guard let f = folder else { return }
        let parent = f.deletingLastPathComponent()
        // deletingLastPathComponent on "/" returns "/" — same path means
        // we're already at the top.
        guard parent.path != f.path else { return }
        Task { await loadFolder(parent, setAsAnchor: true, recursive: false) }
    }

    /// True when `goUp` would do something — there's a folder loaded and
    /// it has a real parent. Drives the toolbar button's enabled state.
    var canGoUp: Bool {
        guard let f = folder else { return false }
        return f.deletingLastPathComponent().path != f.path
    }

    /// Walk a directory, returning all matched image URLs. `onProgress` is
    /// called every ~64 files with the running count so the loader's "X
    /// photos found" can tick up live. Honors the calling task's
    /// cancellation: `Task.isCancelled` short-circuits the enumerator on
    /// large trees, which is how the Stop button bails out mid-walk.
    ///
    /// We prefetch contentModificationDate alongside isRegularFile so the
    /// mtime-sort path doesn't pay a per-URL stat after the walk. The
    /// resourceValues are cached on the returned URLs.
    private static func walkFolder(
        _ root: URL,
        recursive: Bool,
        onProgress: (@Sendable (Int) async -> Void)? = nil
    ) async -> [URL] {
        let imageExtensions = AppState.imageExtensions
        let fm = FileManager.default
        var found: [URL] = []

        if !recursive {
            // Cheap one-shot listing of the folder's direct contents. No
            // streaming — at worst this is a few hundred entries; the
            // scanner UI shouldn't bother flickering for it.
            let items = (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in items {
                if Task.isCancelled { break }
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if isFile && imageExtensions.contains(url.pathExtension.lowercased()) {
                    found.append(url)
                }
            }
            if let onProgress { await onProgress(found.count) }
            return found
        }

        // Recursive walk: depth-first via FileManager.enumerator. Skip
        // package descendants (kills .photoslibrary/.app interiors) and
        // hidden files. Periodic Task.isCancelled + onProgress hooks let
        // Stop be responsive even on huge trees.
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let tickEvery = 64
        var sinceTick = 0
        while let next = enumerator.nextObject() {
            if Task.isCancelled { break }
            guard let url = next as? URL else { continue }
            if url.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            guard isFile else { continue }
            guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
            found.append(url)
            sinceTick += 1
            if sinceTick >= tickEvery {
                sinceTick = 0
                if let onProgress { await onProgress(found.count) }
            }
        }
        return found
    }

    /// Sort image URLs by the user's chosen order. Path-relative comparison
    /// for name-asc; cached `contentModificationDate` for modified-desc
    /// (cached because walkFolder prefetched the value, so reading it back
    /// is free). Pure function — runs on whatever task the caller is on.
    nonisolated static func sortPhotos(_ urls: [URL], by sort: FolderSort, basePath: String) -> [URL] {
        switch sort {
        case .nameAscending:
            return urls.sorted { lhs, rhs in
                let l = lhs.path.hasPrefix(basePath) ? String(lhs.path.dropFirst(basePath.count)) : lhs.path
                let r = rhs.path.hasPrefix(basePath) ? String(rhs.path.dropFirst(basePath.count)) : rhs.path
                return l.localizedStandardCompare(r) == .orderedAscending
            }
        case .modifiedDescending:
            // Compute mtime once per URL into a side array, then sort the
            // pairs. Reading resourceValues inside the comparator would
            // hit it O(N log N) times even with caching.
            let withMtime = urls.map { url -> (URL, Date) in
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, m)
            }
            return withMtime.sorted { $0.1 > $1.1 }.map { $0.0 }
        }
    }

    /// File-watcher rescan path. Honors the load's recursive flag so a
    /// non-recursive folder doesn't trigger a full-tree walk on every fs
    /// event. Cancellable: the watcher cancels an in-flight rescan when a
    /// new event fires, so rapid-fire events coalesce.
    private static func walkAndSort(_ root: URL, recursive: Bool, sort: FolderSort) async -> [URL] {
        let basePath = root.path
        return await Task.detached(priority: .utility) {
            let all = await walkFolder(root, recursive: recursive)
            if Task.isCancelled { return all }
            return Self.sortPhotos(all, by: sort, basePath: basePath)
        }.value
    }

    private func startWatching(_ url: URL) {
        fileWatcher?.cancel()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: .main
        )
        // Watching only the root dir — we don't recurse-watch subfolders to
        // avoid blowing through file-descriptor limits on huge libraries.
        // Folder-level events still fire when files are added/removed at the
        // top level; if the user reorganizes a deep subdir while the app is
        // running they get inconsistent state until they reopen the folder.
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Cancel any rescan that's still chewing through the fs from a
            // previous event in this same burst. A bulk delete or trash
            // sweep typically fires several events; without coalescing we
            // ran one full recursive walk per event, which on a 50k-photo
            // folder hung the app.
            self.watcherRescanTask?.cancel()
            // Preserve the user's current selection across the rescan.
            let previousURL = self.selectedIndex.flatMap { idx in
                idx < self.imageURLs.count ? self.imageURLs[idx] : nil
            }
            let recursive = self.loadedRecursively
            let sort = self.photoSort
            self.watcherRescanTask = Task { @MainActor [weak self] in
                let urls = await Self.walkAndSort(url, recursive: recursive, sort: sort)
                guard let self else { return }
                if Task.isCancelled { return }
                guard self.folder == url else { return }
                self.imageURLs = urls
                self.selectedIndex = previousURL.flatMap { urls.firstIndex(of: $0) }
                                    ?? (urls.isEmpty ? nil : 0)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }

    // MARK: - Selection delegation

    func selectNext() { selection.selectNext() }
    func selectPrevious() { selection.selectPrevious() }
    func selectFirst() { selection.selectFirst() }
    func selectLast() { selection.selectLast() }
    func select(url: URL) { selection.select(url: url) }

    func stopWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
        watcherRescanTask?.cancel()
        watcherRescanTask = nil
    }

    // MARK: - Trash delegation

    func trashImage(at url: URL) { trash.trashImage(at: url) }
    func trashImages(_ urls: [URL]) { trash.trashImages(urls) }



    private func optimisticallyRemoveImages(_ urls: [URL]) {
        let trashedSet = Set(urls)
        let selectedURL = currentURL
        for url in trashedSet { prefetcher.evict(url: url) }
        imageURLs.removeAll { trashedSet.contains($0) }
        selection.adjustAfterRemoval(removedURLs: trashedSet, previousURL: selectedURL)
    }

    private func reinsertFailedTrashURLs(_ urls: [URL]) {
        guard let folder else { return }
        let basePath = folder.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let current = currentURL
        let toRestore = urls.filter { url in
            (url.path.hasPrefix(prefix) || url.path == folder.path) && !imageURLs.contains(url)
        }
        guard !toRestore.isEmpty else { return }

        imageURLs.append(contentsOf: toRestore)
        imageURLs = Self.sortPhotos(imageURLs, by: photoSort, basePath: basePath)
        if let current, let idx = imageURLs.firstIndex(of: current) {
            selectedIndex = idx
        }
    }

    /// Trash whatever's selected — the active multi-selection if any,
    /// otherwise the single primary photo. Bound to Backspace.
    func trashCurrentImage() {
        if !multiSelection.isEmpty {
            trash.trashImages(Array(multiSelection))
            return
        }
        guard let i = selectedIndex, i < imageURLs.count else { return }
        trash.trashImage(at: imageURLs[i])
    }

    func undoTrash() { trash.undoTrash() }
    var canUndoTrash: Bool { trash.canUndoTrash }

    /// Select every photo in the current folder. Bound to ⌘A.
    func selectAllPhotos() { selection.selectAll() }

    /// Drop the multi-selection back to single-select mode.
    func clearMultiSelection() { selection.clearMultiSelection() }

    /// Move a whole folder to the Trash. UI changes only after macOS confirms
    /// the filesystem operation succeeded.
    func trashFolder(at url: URL) {
        trash.trashFolder(at: url)
    }

    private func handleFolderTrashSuccess(_ url: URL) {
        let trashedPath = url.path
        let prefix = trashedPath.hasSuffix("/") ? trashedPath : trashedPath + "/"
        let beforeCount = imageURLs.count
        imageURLs.removeAll { $0.path.hasPrefix(prefix) }
        if imageURLs.count != beforeCount, let sel = selectedIndex {
            selectedIndex = imageURLs.isEmpty ? nil : min(sel, imageURLs.count - 1)
        }

        // Tell the folder tree which URL to drop (single DFS splice).
        lastRemovedFolder = url
        folderTreeChangeTick &+= 1

        if let currentFolder = folder,
           currentFolder.path == trashedPath || currentFolder.path.hasPrefix(prefix) {
            closeFolder()
        }
    }

    /// Close the current album: drop selection + URL list, swap back to the
    /// empty state. Called by the double-Escape shortcut. Doesn't clear
    /// recents — the folder stays in MRU so re-opening is one click away.
    func closeFolder() {
        scanGeneration &+= 1
        // Cancel any in-flight scan first so a slow recursive walk doesn't
        // keep churning fs reads after the user closes the folder.
        scanTask?.cancel()
        scanTask = nil
        stopWatching()
        if let prev = extractedArchiveDir {
            try? FileManager.default.removeItem(at: prev)
            extractedArchiveDir = nil
        }
        // The prefetch cache is folder-scoped — clear it so the new
        // (empty) state isn't holding ~480MB of decoded images that the
        // user can't see.
        prefetcher.clear()
        // Clear thumbnail cache — the new folder has no overlap.
        ThumbnailLoader.shared.clear()
        folder = nil
        anchorFolder = nil
        imageURLs = []
        selection.reset()
        loadPhase = nil
    }

    // Note: no deinit cancel of fileWatcher — main-actor isolation prevents
    // accessing it from a nonisolated deinit. The AppState lives for the
    // lifetime of the app in this minimal version, so OS cleans up at exit.
    // Call stopWatching() explicitly when migrating to a multi-window app.
}
