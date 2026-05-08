import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotoIO

/// Holds the currently-selected folder and the list of image URLs in it.
/// Watches the folder for changes via DispatchSource so adds/removes update
/// the grid in near-real-time.
@MainActor
@Observable
final class AppState {
    /// Folder currently being browsed (or the temp dir produced by archive
    /// extraction when the user opened an archive).
    var folder: URL? = nil
    /// Image URLs in `folder` and any subfolders, sorted by relative path.
    var imageURLs: [URL] = []
    /// Index of the currently-selected image (if any). The "primary" focus —
    /// what the detail view shows. In multi-select mode this is the most
    /// recent click + the anchor for shift-click range extension.
    var selectedIndex: Int? = nil
    /// Multi-selection set. Empty when in single-select mode (the typical
    /// case). When non-empty, Backspace trashes ALL of these instead of
    /// just the primary, and the toolbar shows a "N selected" pill.
    /// Shift-click extends from `selectedIndex` anchor; ⌘-click toggles;
    /// plain click clears + sets singleton; ⌘A selects all; Esc clears.
    var multiSelection: Set<URL> = []
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

    /// One trash operation, undoable as a unit. Bulk trashes hold many
    /// entries; folder trashes hold one (the folder root). `trashURL` is
    /// the post-trash location (`~/.Trash/photo.jpg` typically) — undo
    /// moves the file from there back to `originalURL`.
    struct TrashRecord {
        let id: UUID
        let entries: [Entry]
        let isFolder: Bool
        var isPending: Bool = false
        var undoRequested: Bool = false

        struct Entry {
            let originalURL: URL
            /// Where the OS landed the trashed item. nil if we couldn't
            /// capture it (older API path); undo skips these entries.
            let trashURL: URL?
        }
    }

    private var fileWatcher: DispatchSourceFileSystemObject?
    /// When the active folder was produced by archive extraction, hold on to
    /// the temp dir URL so we can clean it up when the user opens something
    /// else (or when the app quits).
    private var extractedArchiveDir: URL?
    /// Whether the active folder was loaded recursively. The file watcher
    /// uses this so a non-recursive load doesn't trigger an O(deep tree)
    /// rescan on every fs event — that combo was hanging the app when the
    /// user trashed photos in a folder whose subtree was huge.
    private var loadedRecursively: Bool = false
    /// In-flight watcher-driven rescan. Cancelled and replaced when a new
    /// fs event fires, so rapid-fire events (a deletion sometimes triggers
    /// half a dozen) coalesce into a single rescan instead of stacking.
    private var watcherRescanTask: Task<Void, Never>? = nil
    /// In-flight folder-walk task. Cancelled by `cancelScan()` (the Stop
    /// button in the loading scene) or when a new `loadFolder` starts before
    /// the previous one finishes. Whatever was found before cancel is still
    /// committed — partial results are usually what the user wanted.
    private var scanTask: Task<Void, Never>? = nil
    /// Monotonic token for folder loads. Starting a new load, or closing the
    /// current folder, invalidates any older async extract/scan task so stale
    /// work cannot repopulate the UI after the user has moved on.
    private var scanGeneration: UInt64 = 0
    /// Bumped every time disk state diverges from the folder tree's cached
    /// view — currently after a folder trash. Paired with `lastRemovedFolder`
    /// so the tree can splice the dead node out by URL instead of running a
    /// recursive re-stat (the recursive re-stat was hanging the app for
    /// seconds on deeply-expanded trees).
    var folderTreeChangeTick: Int = 0
    /// URL of the most recently trashed folder. The folder tree's
    /// `.onChange(of: folderTreeChangeTick)` listener uses this to find
    /// and remove the dead node in a single DFS pass — no fs work.
    private(set) var lastRemovedFolder: URL? = nil
    /// Ring of recent trash operations, newest at the end. ⌘Z pops the
    /// last one and tries to restore each entry from `~/.Trash`. Capped
    /// so a long session doesn't accumulate unbounded history.
    private(set) var trashHistory: [TrashRecord] = []
    private let trashHistoryCap = 20
    /// True when there's a trash op available to undo. Drives the
    /// optional toolbar/menu disabled state.
    var canUndoTrash: Bool { trashHistory.contains { !$0.undoRequested } }

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
                self.imageURLs = urls
                self.selectedIndex = previousURL.flatMap { urls.firstIndex(of: $0) }
                                    ?? (urls.isEmpty ? nil : 0)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }

    func selectNext() {
        guard !imageURLs.isEmpty else { return }
        selectedIndex = min((selectedIndex ?? -1) + 1, imageURLs.count - 1)
    }

    func selectPrevious() {
        guard !imageURLs.isEmpty else { return }
        selectedIndex = max((selectedIndex ?? imageURLs.count) - 1, 0)
    }

    func selectFirst() {
        selectedIndex = imageURLs.isEmpty ? nil : 0
    }

    func selectLast() {
        selectedIndex = imageURLs.isEmpty ? nil : imageURLs.count - 1
    }

    /// Jump to a specific URL (no-op if it's not in the current folder).
    /// Used by vim mark-jump and map-cluster selection.
    func select(url: URL) {
        if let i = imageURLs.firstIndex(of: url) {
            selectedIndex = i
        }
    }

    var currentURL: URL? {
        guard let i = selectedIndex, i < imageURLs.count else { return nil }
        return imageURLs[i]
    }

    func stopWatching() {
        fileWatcher?.cancel()
        fileWatcher = nil
        watcherRescanTask?.cancel()
        watcherRescanTask = nil
    }

    /// Move a single image to the user's Trash. Reversible via ⌘Z —
    /// `trashItem`'s resultingItemURL is captured into the trash history
    /// so undo can move the file back from `~/.Trash`. Updates
    /// `imageURLs` + `selectedIndex` optimistically.
    func trashImage(at url: URL) {
        trashImages([url])
    }

    /// Bulk trash. Each file is trashed individually (so a single failure
    /// doesn't take down the whole batch) but the resulting entries land
    /// in ONE TrashRecord, so ⌘Z restores them all together. Used when the
    /// user has built up a `multiSelection` and hits Backspace.
    func trashImages(_ urls: [URL]) {
        let ordered = uniqueURLs(urls)
        guard !ordered.isEmpty else { return }

        let recordID = UUID()
        pushTrashRecord(TrashRecord(
            id: recordID,
            entries: ordered.map { .init(originalURL: $0, trashURL: nil) },
            isFolder: false,
            isPending: true
        ))

        // Drop requested photos from the visible list before Finder's Trash
        // machinery runs. `trashItem` can stall on large or remote folders;
        // the UI should feel instant and the async result can reconcile
        // undo/error state when it lands.
        optimisticallyRemoveImages(ordered)

        Task.detached(priority: .userInitiated) { [weak self] in
            var entries: [TrashRecord.Entry] = []
            var failed: [URL] = []
            for url in ordered {
                var resultURL: NSURL?
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
                    entries.append(.init(originalURL: url, trashURL: resultURL as URL?))
                } catch {
                    failed.append(url)
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.completeTrashRecord(id: recordID, trashedEntries: entries, failedURLs: failed)
            }
        }
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var out: [URL] = []
        for url in urls where !seen.contains(url) {
            seen.insert(url)
            out.append(url)
        }
        return out
    }

    private func optimisticallyRemoveImages(_ urls: [URL]) {
        let trashedSet = Set(urls)
        let selectedURL = currentURL
        let firstRemovedIdx = imageURLs.firstIndex { trashedSet.contains($0) }
        for url in trashedSet { prefetcher.evict(url: url) }
        imageURLs.removeAll { trashedSet.contains($0) }
        multiSelection.subtract(trashedSet)

        if imageURLs.isEmpty {
            selectedIndex = nil
        } else if let selectedURL, let newIdx = imageURLs.firstIndex(of: selectedURL) {
            selectedIndex = newIdx
        } else if let firstRemovedIdx {
            selectedIndex = min(firstRemovedIdx, imageURLs.count - 1)
        } else {
            selectedIndex = min(selectedIndex ?? 0, imageURLs.count - 1)
        }
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
            trashImages(Array(multiSelection))
            return
        }
        guard let i = selectedIndex, i < imageURLs.count else { return }
        trashImage(at: imageURLs[i])
    }

    /// Add a record to the history ring, dropping the oldest if we'd
    /// exceed the cap. ⌘Z pulls from the END (most recent first).
    private func pushTrashRecord(_ record: TrashRecord) {
        trashHistory.append(record)
        if trashHistory.count > trashHistoryCap {
            let overflow = trashHistory.count - trashHistoryCap
            for _ in 0..<overflow {
                if let idx = trashHistory.firstIndex(where: { !$0.isPending }) {
                    trashHistory.remove(at: idx)
                }
            }
        }
    }

    private func completeTrashRecord(id: UUID, trashedEntries: [TrashRecord.Entry], failedURLs: [URL]) {
        if !failedURLs.isEmpty {
            lastError = "Couldn't trash: \(failedURLs.prefix(3).map(\.lastPathComponent).joined(separator: ", "))"
                + (failedURLs.count > 3 ? " (+\(failedURLs.count - 3) more)" : "")
            reinsertFailedTrashURLs(failedURLs)
        }

        guard let idx = trashHistory.firstIndex(where: { $0.id == id }) else { return }

        let completedByURL = Dictionary(uniqueKeysWithValues: trashedEntries.map { ($0.originalURL, $0) })
        var record = trashHistory[idx]
        record = TrashRecord(
            id: record.id,
            entries: record.entries.compactMap { completedByURL[$0.originalURL] },
            isFolder: record.isFolder,
            isPending: false,
            undoRequested: record.undoRequested
        )

        if record.entries.isEmpty {
            trashHistory.remove(at: idx)
            return
        }

        if record.undoRequested {
            trashHistory.remove(at: idx)
            restoreTrashRecord(record)
        } else {
            trashHistory[idx] = record
        }
    }

    /// Undo the most recent trash operation. Moves each entry back from
    /// its trash URL to its original location. Files where the move
    /// fails (rare — usually means the original path now has a fresh
    /// file, or the trash got emptied) get reported in `lastError` and
    /// the rest of the batch still restores.
    func undoTrash() {
        guard let idx = trashHistory.indices.last(where: { !trashHistory[$0].undoRequested }) else { return }
        if trashHistory[idx].isPending {
            trashHistory[idx].undoRequested = true
            lastError = "Trash is still finishing; restore will run as soon as macOS gives us the Trash URL."
            return
        }
        let record = trashHistory.remove(at: idx)
        restoreTrashRecord(record)
    }

    private func restoreTrashRecord(_ record: TrashRecord) {
        var restored: [URL] = []
        var failed: [String] = []
        let fm = FileManager.default
        for entry in record.entries {
            guard let trashURL = entry.trashURL else {
                failed.append(entry.originalURL.lastPathComponent)
                continue
            }
            do {
                try fm.moveItem(at: trashURL, to: entry.originalURL)
                restored.append(entry.originalURL)
            } catch {
                failed.append(entry.originalURL.lastPathComponent)
            }
        }
        if !failed.isEmpty {
            lastError = "Couldn't restore: \(failed.prefix(3).joined(separator: ", "))"
                + (failed.count > 3 ? " (+\(failed.count - 3) more)" : "")
        }

        // Optimistic UI: re-add restored items that belong in the active
        // folder. The file watcher will eventually arrive at the same
        // state, but the user gets immediate feedback.
        guard let folder, !restored.isEmpty else { return }
        let basePath = folder.path
        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        let belongsHere = restored.filter { $0.path.hasPrefix(prefix) || $0.path == folder.path }
        // Folder undo: a whole subtree just came back. Walk it ourselves
        // for any photos to inject — the watcher only catches root-level
        // additions in the recursive case.
        if record.isFolder, let restoredFolder = restored.first {
            Task {
                let urls = await Self.walkAndSort(restoredFolder, recursive: loadedRecursively, sort: photoSort)
                let newPhotos = urls.filter { !imageURLs.contains($0) }
                guard !newPhotos.isEmpty else { return }
                imageURLs.append(contentsOf: newPhotos)
                imageURLs = Self.sortPhotos(imageURLs, by: photoSort, basePath: basePath)
            }
            return
        }
        let newURLs = belongsHere.filter { !imageURLs.contains($0) }
        if newURLs.isEmpty { return }
        imageURLs.append(contentsOf: newURLs)
        imageURLs = Self.sortPhotos(imageURLs, by: photoSort, basePath: basePath)
    }

    /// Select every photo in the current folder. Bound to ⌘A.
    func selectAllPhotos() {
        guard !imageURLs.isEmpty else { return }
        multiSelection = Set(imageURLs)
    }

    /// Drop the multi-selection back to single-select mode. Bound to Esc
    /// (when multi is non-empty); falls through to the existing close-
    /// folder double-tap behavior otherwise.
    func clearMultiSelection() {
        multiSelection.removeAll()
    }

    /// Move a whole folder to the Trash. UI flow is optimistic: every
    /// visible-state mutation happens synchronously here on main, BEFORE
    /// `trashItem` runs, so the folder visibly disappears the instant the
    /// menu item is clicked. The actual `trashItem` syscall (which on big
    /// folders can take seconds — Finder XPC call for the trash sound +
    /// folder size accounting) is fire-and-forget on a background task.
    /// On failure we surface the error and the user can refresh; the
    /// alternative (block until trashItem returns, then update UI) was
    /// what made folder delete feel hung.
    func trashFolder(at url: URL) {
        let recordID = UUID()
        pushTrashRecord(TrashRecord(
            id: recordID,
            entries: [.init(originalURL: url, trashURL: nil)],
            isFolder: true,
            isPending: true
        ))

        // Optimistic UI updates — all sync on main:
        if url == folder { closeFolder() }
        recents.remove(url)

        // Optimistic prune of imageURLs.
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

        // Now do the actual filesystem trashItem on a background task,
        // capturing the resultingItemURL so ⌘Z can move the folder back.
        // If it fails, surface the error on main; the UI is already
        // cleaned up so we just leave it that way (the user can hit
        // refresh if they think the folder is still there).
        Task.detached(priority: .userInitiated) { [weak self] in
            var resultURL: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultURL)
            } catch {
                await MainActor.run { [weak self] in
                    self?.completeTrashRecord(id: recordID, trashedEntries: [], failedURLs: [url])
                    self?.lastError = "Couldn't move folder to Trash: \(error.localizedDescription)"
                }
                return
            }
            let trashedAt = resultURL as URL?
            await MainActor.run { [weak self] in
                self?.completeTrashRecord(
                    id: recordID,
                    trashedEntries: [.init(originalURL: url, trashURL: trashedAt)],
                    failedURLs: []
                )
            }
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
        folder = nil
        anchorFolder = nil
        imageURLs = []
        selectedIndex = nil
        loadPhase = nil
    }

    // Note: no deinit cancel of fileWatcher — main-actor isolation prevents
    // accessing it from a nonisolated deinit. The AppState lives for the
    // lifetime of the app in this minimal version, so OS cleans up at exit.
    // Call stopWatching() explicitly when migrating to a multi-window app.
}
