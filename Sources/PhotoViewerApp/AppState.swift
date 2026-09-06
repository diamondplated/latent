import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotoIO
import PhotoViewerCore

/// Holds the currently-selected folder and the list of image URLs in it.
/// Watches the folder for changes so adds/removes update the grid in near-real
/// time. A debounced FSEvents stream observes the subtree; direct browsing
/// still reconciles with a cheap, nonrecursive directory scan.
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
    ///
    /// Every commit — first load, watcher rescan, optimistic trash removal,
    /// re-sort, folder close — republishes the list to the phone. Hanging the
    /// sync off the property rather than off each call site means a commit
    /// added later cannot forget to do it. `syncSharedFolder` returns
    /// immediately when phone access is off, so the common case costs one
    /// no-op task.
    var imageURLs: [URL] = [] {
        didSet {
            // Re-sharing retires and re-mints every photo ID, so a no-op
            // assignment — a re-sort that changed nothing, a trash sweep that
            // matched nothing — must not trigger one.
            guard oldValue != imageURLs else { return }
            Task { await phoneAccess.syncSharedFolder() }
        }
    }

    /// Phone companion. Created on first touch — nothing listens on the
    /// network until the user turns it on in the pairing sheet.
    @ObservationIgnored
    lazy var phoneAccess = PhoneAccessController(state: self)

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
    /// Vim keymap state: marks, colour labels, picks, rejects. Lives here
    /// rather than on BrowserView because the keyboard is no longer the only
    /// input device — the phone companion dispatches the same `VimAction`
    /// values through `dispatch(_:)`. One owner, one writer.
    var vimKeymap = VimKeymap()
    /// A corrupt or newer on-disk state file is never replaced implicitly.
    /// Browsing remains available, but all culling mutations stay disabled
    /// until the user repairs the file or opens it with a compatible build.
    private(set) var isCullingPersistenceBlocked = false
    /// A v0.2/resource fallback that exists but cannot be tied to the current
    /// directory automatically. The UI offers an explicit, reversible choice:
    /// import it only when the user recognizes this as the original folder.
    private var pendingUnverifiedCullingFolder: URL?
    /// Keep the confirmation action coupled to its exact warning. The pending
    /// folder intentionally survives dismissal so a later culling attempt can
    /// offer the choice again, but an unrelated watcher/trash/save error must
    /// never inherit the "Use Saved Culls" button.
    var canUseUnverifiedCullingState: Bool {
        pendingUnverifiedCullingFolder != nil
            && userError == Self.unverifiedCullingStateMessage
    }

    /// Whether the enhancement side panel is visible. Default false: the app
    /// is primarily a viewer; enhancement is opt-in. Toolbar button toggles.
    var showEnhancementPanel: Bool = false
    /// Whether the folder-tree sidebar (far-left pane) is visible. Default
    /// false to keep the layout simple for new users; toolbar button toggles.
    var showFolderTree: Bool = false
    /// Grid filter is app state (rather than view-local) so window-level
    /// keyboard navigation can stay inside the same visible result set.
    var photoFilter: PhotoFilter = .all
    /// Ranked semantic-search result URLs, or nil when search is inactive.
    /// Kept here (rather than only in BrowserView) so window-level j/k and
    /// arrow navigation follow the same result set the grid displays.
    var searchResultURLs: [URL]? = nil
    /// The window-level key monitor must leave arrows, Space, Backspace and
    /// command editing shortcuts with the semantic-search TextField.
    var isSearchFieldFocused = false
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
                guard self.folderContinuityIsCurrent(at: currentFolder) else {
                    self.closeForFolderContinuityLoss(at: currentFolder)
                    return
                }
                let committedURLs = self.photoSort == sort
                    ? urls
                    : Self.sortPhotos(urls, by: self.photoSort, basePath: currentFolder.path)
                self.imageURLs = committedURLs
                self.selectedIndex = selectedURL.flatMap { committedURLs.firstIndex(of: $0) }
                    ?? (committedURLs.isEmpty ? nil : 0)
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

    private var folderChangeWatcher: RecursiveFolderWatcher?
    private var extractedArchiveDir: URL?
    /// Archive contents are previews backed by a temporary extraction tree.
    /// Mutating them would appear to work and then vanish on close, so the UI
    /// and action layer treat the tree as explicitly read-only.
    private(set) var isBrowsingArchive = false
    private(set) var archiveSourceURL: URL?
    private var loadedRecursively: Bool = false
    private var watcherRescanTask: Task<Void, Never>? = nil
    private var watcherRescanPending = false
    private var scanTask: Task<Void, Never>? = nil
    private var archiveExtractionTask: Task<URL, Error>? = nil
    private var scanGeneration: UInt64 = 0
    /// Snapshot of the directory incarnation accepted for the active load.
    /// Watch callbacks compare it before and after every suspended walk so a
    /// delete/recreate at the same pathname can never inherit the old browser
    /// or culling session.
    private var loadedFolderContinuity: FolderContinuity?
    /// Advances once per active, debounced filesystem batch, including content
    /// changes that leave `imageURLs` unchanged. Consumers use this to refresh
    /// folder-scoped derived data without treating the URL list as a change log.
    private(set) var folderContentsChangeTick: UInt64 = 0
    /// Advances only for filesystem activity that can affect the active grid.
    /// In nonrecursive mode, deeper subtree events still stale the recursive
    /// search index but do not churn thumbnails or launch a pointless rescan.
    private(set) var browserContentChangeTick: UInt64 = 0
    /// Advances at the start of every accepted folder load, including a
    /// same-URL switch between direct and recursive browsing.
    private(set) var folderLoadTick: UInt64 = 0
    /// Signals view-local search UI to retire its query when an external
    /// controller needs to select from the complete unfiltered folder.
    private(set) var browserFilterResetTick: UInt64 = 0
    /// Advances only when the selected media itself may have changed on disk.
    /// DetailView includes it in view/task identity so a same-URL overwrite
    /// reloads pixels, enhancement input, playback, and export state.
    private(set) var selectedMediaContentTick: UInt64 = 0
    var folderTreeChangeTick: Int = 0
    private(set) var lastRemovedFolder: URL? = nil

    private struct FolderContinuity: Equatable, Sendable {
        let resourceIdentity: String?
        let systemNumber: UInt64?
        let fileNumber: UInt64?
        let creationDate: Date?

        func identifiesSameDirectory(as other: FolderContinuity) -> Bool {
            var hasMatchingEvidence = false
            if let resourceIdentity, let otherIdentity = other.resourceIdentity {
                guard resourceIdentity == otherIdentity else { return false }
                hasMatchingEvidence = true
            }
            if let systemNumber, let fileNumber,
               let otherSystem = other.systemNumber,
               let otherFile = other.fileNumber {
                guard systemNumber == otherSystem, fileNumber == otherFile else {
                    return false
                }
                hasMatchingEvidence = true
            }
            if let creationDate, let otherCreationDate = other.creationDate {
                guard creationDate == otherCreationDate else { return false }
                hasMatchingEvidence = true
            }
            return hasMatchingEvidence
        }
    }

    var userError: String? {
        if let lastError { return lastError }
        if let trashError = trash.lastError { return trashError }
        if vimKeymap.lastPersistenceError != nil {
            return "Latent couldn’t save this folder’s picks, rejects, labels, or marks. Your latest culling changes may not survive a relaunch."
        }
        return nil
    }

    func clearUserError() {
        lastError = nil
        trash.lastError = nil
        vimKeymap.clearPersistenceError()
    }

    func clearBrowserFiltersForExternalSelection() {
        photoFilter = .all
        searchResultURLs = nil
        browserFilterResetTick &+= 1
    }

    func reportBlockedCullingEdit() {
        if pendingUnverifiedCullingFolder != nil {
            reportUnverifiedCullingState()
            return
        }
        lastError = "Saved culling state for this folder couldn’t be safely read or migrated. Picks, rejects, labels, and marks are disabled so Latent won’t overwrite that data. Reopen the folder with a compatible version or repair its saved state first."
    }

    private static let unverifiedCullingStateMessage = "Latent found older saved picks, rejects, labels, or marks, but this folder changed afterward and its identity can’t be proven. Choose Use Saved Culls only if this is the same folder; otherwise keep culling disabled so the older data remains untouched."

    private func reportUnverifiedCullingState() {
        lastError = Self.unverifiedCullingStateMessage
    }

    func useUnverifiedCullingState() {
        guard let pendingFolder = pendingUnverifiedCullingFolder,
              folder == pendingFolder,
              ensureActiveFolderContinuity() else { return }
        do {
            let loaded = try VimKeymap.load(
                folder: pendingFolder,
                allowUnverifiedMigration: true
            )
            vimKeymap = loaded
            pendingUnverifiedCullingFolder = nil
            isCullingPersistenceBlocked = loaded.hasUnpersistedChanges
                && loaded.lastPersistenceError != nil
            if isCullingPersistenceBlocked {
                reportBlockedCullingEdit()
            } else {
                lastError = nil
            }
        } catch {
            isCullingPersistenceBlocked = true
            reportUnverifiedCullingState()
        }
    }

    /// Everything Latent will pick up during a folder scan. Static images,
    /// animated images (GIF / APNG / animated HEIC etc.), and video formats
    /// AVFoundation can take a swing at. The actual playback decision is
    /// made later by `MediaTyping.detect` per file.
    nonisolated static var imageExtensions: Set<String> { MediaTyping.allMediaExts }

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
        // Foundation can report a POSIX directory symlink itself as neither a
        // regular file nor a directory. Probe the resolved target as well so
        // Finder/Open With and drag/drop open that folder instead of its
        // parent.
        let resolvedURL = url.resolvingSymlinksInPath().standardizedFileURL
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            || (try? resolvedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
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
        // Finish the latest in-memory culling snapshot before a same-folder
        // reload or folder switch can replace the keymap from disk. The writer
        // serializes this lifecycle flush with already queued background saves.
        guard flushCullingState() else { return false }
        folderLoadTick &+= 1
        searchResultURLs = nil
        scanGeneration &+= 1
        let generation = scanGeneration
        let openingArchive = ArchiveExtractor.isArchive(url)
        let existingExtraction = extractedArchiveDir
        let reusingExtraction = existingExtraction.map {
            Self.isSameOrDescendant(url, of: $0)
        } ?? false

        // Prevent the previous folder's watcher from committing into this load.
        stopWatching()
        loadedFolderContinuity = nil

        // If a previous scan is still running (rare — user clicked a new
        // folder mid-scan), cancel it and wait for it to drain. The
        // generation bump above prevents that stale task from committing
        // into the new load.
        if let prev = scanTask {
            prev.cancel()
            await prev.value
        }
        if let previousExtractionTask = archiveExtractionTask {
            previousExtractionTask.cancel()
            _ = try? await previousExtractionTask.value
        }
        guard generation == scanGeneration else { return false }
        scanTask = nil
        archiveExtractionTask = nil

        // Drop the old folder's prefetched images — the new folder's URLs
        // share no overlap, so cached entries are pure memory waste.
        prefetcher.clear()
        ThumbnailLoader.shared.clear()

        selection.reset()
        imageURLs = []
        photoFilter = .all
        pendingUnverifiedCullingFolder = nil
        lastError = nil

        // Archive extraction has no useful partial state. Clear the old folder
        // before starting it so pressing Stop cannot leave that folder shown
        // empty with its watcher already torn down.
        if openingArchive {
            folder = nil
            vimKeymap = VimKeymap()
            isCullingPersistenceBlocked = false
        }

        // Clean up any previous extracted-archive dir so /tmp doesn't fill up
        // when the user opens several archives in a row. A recursive reload
        // of the current extraction must keep that tree alive.
        if let prev = extractedArchiveDir, !reusingExtraction {
            extractedArchiveDir = nil
            isBrowsingArchive = false
            archiveSourceURL = nil
            Self.removeArchiveExtractionInBackground(prev)
        }

        // Resolve the folder we're going to scan: archive → extract first,
        // then treat the extraction dir as the source.
        let scanRoot: URL
        if openingArchive {
            loadPhase = .extracting(archiveName: url.lastPathComponent)
            do {
                let extractor = ArchiveExtractor()
                let extractionTask = Task { try await extractor.extract(url) }
                archiveExtractionTask = extractionTask
                scanRoot = try await extractionTask.value
                guard generation == scanGeneration else {
                    Self.removeArchiveExtractionInBackground(scanRoot)
                    return false
                }
                archiveExtractionTask = nil
                extractedArchiveDir = scanRoot
                isBrowsingArchive = true
                archiveSourceURL = url
            } catch {
                guard generation == scanGeneration else { return false }
                archiveExtractionTask = nil
                lastError = "\(error)"
                isBrowsingArchive = false
                archiveSourceURL = nil
                folder = nil
                imageURLs = []
                loadPhase = nil
                return false
            }
        } else {
            scanRoot = url
            if !reusingExtraction {
                isBrowsingArchive = false
                archiveSourceURL = nil
            }
        }

        guard let scanRootContinuity = Self.folderContinuity(for: scanRoot) else {
            if openingArchive {
                extractedArchiveDir = nil
                Self.removeArchiveExtractionInBackground(scanRoot)
            }
            folder = nil
            anchorFolder = nil
            imageURLs = []
            vimKeymap = VimKeymap()
            isCullingPersistenceBlocked = false
            isBrowsingArchive = false
            archiveSourceURL = nil
            loadPhase = nil
            lastError = "Latent couldn’t open that folder because it was moved, removed, or replaced during loading."
            return false
        }
        loadedFolderContinuity = scanRootContinuity

        // AppState owns culling state, so load it before publishing `folder`.
        // On the first folder opened (and after close/reopen), BrowserView is
        // created only after `folder` changes and therefore cannot rely on an
        // onChange hook to initialize this data. Loading here prevents stale
        // picks from the prior folder being written into the new folder.
        if isBrowsingArchive {
            vimKeymap = VimKeymap()
            isCullingPersistenceBlocked = false
            pendingUnverifiedCullingFolder = nil
        } else {
            do {
                let loadedKeymap = try VimKeymap.load(folder: scanRoot)
                vimKeymap = loadedKeymap
                pendingUnverifiedCullingFolder = nil
                isCullingPersistenceBlocked = loadedKeymap.hasUnpersistedChanges
                    && loadedKeymap.lastPersistenceError != nil
                if isCullingPersistenceBlocked { reportBlockedCullingEdit() }
            } catch VimKeymapError.folderContinuityUnverifiable {
                vimKeymap = VimKeymap()
                pendingUnverifiedCullingFolder = scanRoot
                isCullingPersistenceBlocked = true
                reportUnverifiedCullingState()
            } catch {
                vimKeymap = VimKeymap()
                pendingUnverifiedCullingFolder = nil
                isCullingPersistenceBlocked = true
                reportBlockedCullingEdit()
            }
        }
        guard Self.folderContinuity(for: scanRoot)?
            .identifiesSameDirectory(as: scanRootContinuity) == true else {
            if openingArchive {
                extractedArchiveDir = nil
                Self.removeArchiveExtractionInBackground(scanRoot)
            }
            loadedFolderContinuity = nil
            folder = nil
            anchorFolder = nil
            imageURLs = []
            vimKeymap = VimKeymap()
            isCullingPersistenceBlocked = false
            isBrowsingArchive = false
            archiveSourceURL = nil
            loadPhase = nil
            lastError = "Latent closed the folder because it was moved, removed, or replaced during loading."
            return false
        }
        folder = scanRoot
        if setAsAnchor { anchorFolder = scanRoot }
        loadedRecursively = recursive
        // Push the user's ORIGINAL pick (which may be an archive file) to
        // the recents — re-opening from recents replays the same flow,
        // including extraction. Only push real, non-temp paths so cleaned-
        // up extraction dirs don't poison the list.
        if !reusingExtraction { recents.push(url) }
        loadPhase = .scanning(folderName: scanRoot.lastPathComponent, photosFound: 0)

        // Install subtree monitoring BEFORE the initial walk. Any
        // event that lands while the walk is in progress is remembered and
        // causes one reconciliation afterward, so no change can hide in a
        // scan-then-start race. The same stream sees in-place content writes;
        // nonrecursive browsing still performs only a one-directory rescan.
        startWatching(
            scanRoot,
            recursive: recursive,
            generation: generation
        )

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
                guard self.folderContinuityIsCurrent(at: scanRoot) else {
                    self.closeForFolderContinuityLoss(at: scanRoot)
                    return
                }
                // The user can change sort order while this detached scan is
                // suspended. Reconcile the completed snapshot against the
                // currently selected order before the atomic commit.
                let committedURLs = self.photoSort == sort
                    ? found
                    : Self.sortPhotos(found, by: self.photoSort, basePath: pathBase)
                self.imageURLs = committedURLs
                self.selectedIndex = committedURLs.isEmpty ? nil : 0
                self.loadPhase = nil
            }
        }
        scanTask = task
        await task.value
        guard generation == scanGeneration else { return false }
        scanTask = nil

        if watcherRescanPending {
            watcherRescanPending = false
            scheduleWatcherRescan(
                root: scanRoot,
                recursive: recursive,
                generation: generation
            )
        }
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
        if let archiveExtractionTask {
            // Archive extraction has no partial result worth keeping. Cancel
            // its process and invalidate this load so it cannot open after the
            // user has dismissed the loading scene.
            scanGeneration &+= 1
            archiveExtractionTask.cancel()
            self.archiveExtractionTask = nil
        }
        scanTask?.cancel()
        loadPhase = nil
    }

    /// Navigate to the parent of the current folder. Re-roots the folder
    /// tree to the parent (setAsAnchor=true) — going up implies the user
    /// wants the tree to come along, otherwise they'd have just clicked
    /// elsewhere. No-op at filesystem root.
    func goUp() {
        guard !isBrowsingArchive else { return }
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
        guard !isBrowsingArchive else { return false }
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
    nonisolated private static func walkFolder(
        _ root: URL,
        recursive: Bool,
        onProgress: (@Sendable (Int) async -> Void)? = nil
    ) async -> [URL] {
        let imageExtensions = AppState.imageExtensions
        let fm = FileManager.default
        var found: [URL] = []
        let paths = FolderPathMapper(rootURL: root)
        // Enumerate a directory symlink through its resolved target. Rebase
        // every child onto the spelling Latent is actually browsing so
        // selection, restored culling URLs, search results, and watcher
        // rescans all share one identity (including /tmp ↔ /private/tmp).
        let enumerationRoot = paths.enumerationRootURL

        if !recursive {
            // Cheap one-shot listing of the folder's direct contents. No
            // streaming — at worst this is a few hundred entries; the
            // scanner UI shouldn't bother flickering for it.
            let items = (try? fm.contentsOfDirectory(
                at: enumerationRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for url in items {
                if Task.isCancelled { break }
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if isFile && imageExtensions.contains(url.pathExtension.lowercased()) {
                    found.append(paths.rebaseToRoot(url))
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
            at: enumerationRoot,
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
            found.append(paths.rebaseToRoot(url))
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

    /// Capture more than one filesystem signal. Foundation's opaque identity
    /// is strongest when available; POSIX device/inode plus creation date keep
    /// the same protection on volumes where bookmark resource identifiers are
    /// unavailable.
    private static func folderContinuity(for url: URL) -> FolderContinuity? {
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: canonicalURL.path
        ), attributes[.type] as? FileAttributeType == .typeDirectory else {
            return nil
        }
        return FolderContinuity(
            resourceIdentity: VimKeymap.folderIdentity(for: canonicalURL),
            systemNumber: (attributes[.systemNumber] as? NSNumber)?.uint64Value,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
            creationDate: attributes[.creationDate] as? Date
        )
    }

    private func folderContinuityIsCurrent(at root: URL) -> Bool {
        guard let loadedFolderContinuity,
              let current = Self.folderContinuity(for: root) else { return false }
        return current.identifiesSameDirectory(as: loadedFolderContinuity)
    }

    private func closeForFolderContinuityLoss(at root: URL) {
        guard folder == root else { return }
        closeFolder(persistCulling: false)
        lastError = "The open folder was moved, removed, or replaced. Latent closed it so saved culling state stays attached to the original folder. Reopen the folder at its current location."
    }

    /// File-watcher rescan path. Honors the load's recursive flag so a
    /// non-recursive folder doesn't trigger a full-tree walk on every fs
    /// event. Cancellable: the watcher cancels an in-flight rescan when a
    /// new event fires, so rapid-fire events coalesce.
    nonisolated private static func walkAndSort(_ root: URL, recursive: Bool, sort: FolderSort) async -> [URL] {
        let basePath = root.path
        let all = await walkFolder(root, recursive: recursive)
        if Task.isCancelled { return all }
        return Self.sortPhotos(all, by: sort, basePath: basePath)
    }

    private func startWatching(
        _ url: URL,
        recursive: Bool,
        generation: UInt64
    ) {
        folderChangeWatcher?.stop()
        folderChangeWatcher = nil

        let watcher = RecursiveFolderWatcher(rootURL: url) { [weak self] batch in
            Task { @MainActor [weak self] in
                self?.scheduleWatcherRescan(
                    root: url,
                    recursive: recursive,
                    generation: generation,
                    batch: batch
                )
            }
        }
        do {
            try watcher.start()
            folderChangeWatcher = watcher
        } catch {
            lastError = "This folder opened, but Latent couldn't monitor it for live changes: \(error.localizedDescription)"
        }
    }

    /// Coalesce filesystem activity into one cancellable background snapshot.
    /// The generation and mode checks reject callbacks already queued when a
    /// folder is closed, replaced, or reloaded with a different recursion mode.
    private func scheduleWatcherRescan(
        root: URL,
        recursive: Bool,
        generation: UInt64,
        batch: RecursiveFolderChangeBatch? = nil
    ) {
        guard scanGeneration == generation,
              folder == root,
              loadedRecursively == recursive else { return }
        guard folderContinuityIsCurrent(at: root) else {
            closeForFolderContinuityLoss(at: root)
            return
        }

        // This is intentionally independent of `imageURLs`: overwriting an
        // existing image produces a meaningful filesystem batch even though
        // the rescan ultimately yields the same ordered URL array.
        folderContentsChangeTick &+= 1
        let viewerBatch = batch.flatMap {
            viewerRelevantBatch($0, root: root, recursive: recursive)
        }
        if batch != nil, viewerBatch == nil { return }
        browserContentChangeTick &+= 1
        if let viewerBatch { invalidateMediaCaches(for: viewerBatch, root: root) }

        // A subtree event can arrive while the initial recursive snapshot is
        // still running. Let that snapshot finish, then reconcile once; racing
        // two walks could let the older result overwrite the newer one.
        if loadPhase != nil || scanTask != nil {
            watcherRescanPending = true
            return
        }

        watcherRescanTask?.cancel()
        let sort = photoSort
        watcherRescanTask = Task { @MainActor [weak self] in
            let urls = await Self.walkAndSort(root, recursive: recursive, sort: sort)
            guard let self, !Task.isCancelled else { return }
            guard self.scanGeneration == generation,
                  self.folder == root,
                  self.loadedRecursively == recursive else { return }
            guard self.folderContinuityIsCurrent(at: root) else {
                self.closeForFolderContinuityLoss(at: root)
                return
            }
            // Navigation can continue while the filesystem walk is suspended.
            // Remap the selection that is current *now*, rather than jumping
            // back to whatever happened to be selected when the rescan began.
            let latestURL = self.currentURL
            let committedURLs = self.photoSort == sort
                ? urls
                : Self.sortPhotos(urls, by: self.photoSort, basePath: root.path)
            let removedURLs = Set(self.imageURLs).subtracting(committedURLs)
            self.imageURLs = committedURLs
            self.selection.adjustAfterRemoval(
                removedURLs: removedURLs,
                previousURL: latestURL
            )
        }
    }

    /// FSEvents watches the whole subtree even when the grid is intentionally
    /// showing only direct children. Preserve those deeper events for search
    /// freshness, but narrow the expensive browser reconciliation to paths a
    /// nonrecursive directory listing could actually include.
    private func viewerRelevantBatch(
        _ batch: RecursiveFolderChangeBatch,
        root: URL,
        recursive: Bool
    ) -> RecursiveFolderChangeBatch? {
        if recursive || batch.requiresFullRescan { return batch }

        let paths = FolderPathMapper(rootURL: root)
        let normalizedRoot = paths.rootPath

        let changedURLs = batch.changedURLs.filter { url in
            let path = paths.pathRebasedToRoot(for: url)
            if path == normalizedRoot { return true }
            let candidate = URL(fileURLWithPath: path)
            guard candidate.deletingLastPathComponent().path == normalizedRoot else {
                return false
            }
            return Self.imageExtensions.contains(candidate.pathExtension.lowercased())
        }
        guard !changedURLs.isEmpty else { return nil }
        return RecursiveFolderChangeBatch(
            changedURLs: changedURLs,
            requiresFullRescan: false
        )
    }

    /// URL lists do not reveal same-path overwrites. Evict every cache entry
    /// named by the FSEvents batch (or the whole generation when events were
    /// coalesced/dropped) before SwiftUI restarts visible thumbnail/detail
    /// tasks with the new content revision.
    private func invalidateMediaCaches(
        for batch: RecursiveFolderChangeBatch,
        root: URL
    ) {
        // Large file-level batches make per-path prefix matching quadratic in
        // library size. Clearing bounded caches is both faster and safer; only
        // visible cells are decoded again after the revision changes.
        if batch.requiresFullRescan || batch.changedURLs.count > 32 {
            ThumbnailLoader.shared.clear()
            prefetcher.clear()
            selectedMediaContentTick &+= 1
            return
        }

        let paths = FolderPathMapper(rootURL: root)

        let changedPaths = Set(batch.changedURLs.map {
            paths.pathRebasedToRoot(for: $0)
        })
        let changedPrefixes = changedPaths.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let selectedPath = currentURL.map { paths.pathRebasedToRoot(for: $0) }
        var selectedWasAffected = false

        for url in imageURLs {
            let path = paths.pathRebasedToRoot(for: url)
            let affected = changedPaths.contains(path)
                || changedPrefixes.contains { path.hasPrefix($0) }
            guard affected else { continue }
            ThumbnailLoader.shared.evict(url: url)
            prefetcher.evict(url: url)
            if path == selectedPath { selectedWasAffected = true }
        }
        if selectedWasAffected { selectedMediaContentTick &+= 1 }
    }

    // MARK: - Selection delegation

    func selectNext() { selection.selectNext() }
    func selectPrevious() { selection.selectPrevious() }
    func selectFirst() { selection.selectFirst() }
    func selectLast() { selection.selectLast() }
    func select(url: URL) { selection.select(url: url) }

    /// Revalidate immediately before any user/phone interaction that may
    /// mutate or persist folder-scoped state. FSEvents is deliberately
    /// debounced, so the watcher alone cannot close the same-path replacement
    /// window quickly enough to protect a culling write.
    @discardableResult
    func ensureActiveFolderContinuity() -> Bool {
        guard let folder else { return false }
        guard folderContinuityIsCurrent(at: folder) else {
            closeForFolderContinuityLoss(at: folder)
            return false
        }
        return true
    }

    // MARK: - Vim action dispatch

    /// Apply one `VimAction`, whatever produced it. The keyboard produces
    /// these via `VimKeymap.handle`; the phone companion produces them from
    /// swipe gestures. Both land here, so picks, rejects, labels and the
    /// sidecar write happen in exactly one place.
    ///
    /// `VimKeymap` has already mutated its own state for the label/pick/
    /// reject/mark cases by the time we see the action — this method's job is
    /// navigation plus persistence.
    func dispatch(_ action: VimAction) {
        switch action {
        case .next:  selectNext()
        case .prev:  selectPrevious()
        case .first: selectFirst()
        case .last:  selectLast()
        case .jumpToMark(let c):
            if let url = vimKeymap.marks[c] { select(url: url) }
        case .setColorLabel, .togglePick, .toggleReject:
            guard ensureActiveFolderContinuity() else { return }
            guard !isCullingPersistenceBlocked else {
                reportBlockedCullingEdit()
                return
            }
            if let folder { vimKeymap.saveInBackground(folder: folder) }
            // Both writers land here — the keyboard via BrowserView, the phone
            // via PhoneAccessController.apply — and both have already mutated
            // the keymap and put the affected photo under `currentURL` by the
            // time dispatch runs. So this is the one place that knows a photo's
            // state changed, whoever changed it, which is why the phone is told
            // from here rather than from either caller.
            if let url = currentURL {
                let picked = vimKeymap.isPicked(url)
                let rejected = vimKeymap.isRejected(url)
                let label = vimKeymap.colorLabel(for: url)
                Task { await phoneAccess.publish(url: url, picked: picked, rejected: rejected, label: label) }
            }
        case .setMark:
            // Marks are Mac-only navigation; the phone has no concept of them.
            guard ensureActiveFolderContinuity() else { return }
            guard !isCullingPersistenceBlocked else {
                reportBlockedCullingEdit()
                return
            }
            if let folder { vimKeymap.saveInBackground(folder: folder) }
        case .none:
            break
        }
    }

    /// Persist the newest complete snapshot at lifecycle boundaries (folder
    /// switch/close and app termination). This shares the same revisioned
    /// serial writer as background edits, so an older queued write cannot land
    /// afterward and replace it.
    @discardableResult
    func flushCullingState() -> Bool {
        guard let folder,
              !isBrowsingArchive,
              !isCullingPersistenceBlocked else { return true }
        guard vimKeymap.hasUnpersistedChanges else { return true }
        guard folderContinuityIsCurrent(at: folder) else {
            // There is no safe destination for state tied to a folder that no
            // longer occupies this pathname. Close without resolving a new
            // bookmark, which is the critical guarantee: old culls must never
            // become the replacement folder's state.
            closeForFolderContinuityLoss(at: folder)
            return true
        }
        do {
            try vimKeymap.save(folder: folder)
            return true
        } catch {
            // Keep the current keymap alive. Folder switches and close actions
            // use this return value as a barrier so the only complete snapshot
            // is never discarded after a failed lifecycle save.
            return false
        }
    }

    func stopWatching() {
        folderChangeWatcher?.stop()
        folderChangeWatcher = nil
        watcherRescanPending = false
        watcherRescanTask?.cancel()
        watcherRescanTask = nil
    }

    // MARK: - Trash delegation

    func trashImage(at url: URL) {
        guard ensureWritableSource() else { return }
        trash.trashImage(at: url)
    }

    func trashImages(_ urls: [URL]) {
        guard ensureWritableSource() else { return }
        trash.trashImages(urls)
    }



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
        guard ensureWritableSource() else { return }
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
        guard ensureWritableSource() else { return }
        trash.trashFolder(at: url)
    }

    @discardableResult
    private func ensureWritableSource() -> Bool {
        guard !isBrowsingArchive else {
            lastError = "Archive previews are read-only. Extract the archive in Finder before editing or trashing its contents."
            return false
        }
        return true
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
            // The source no longer exists, so its already-queued snapshot is
            // the last meaningful one; a new identity lookup cannot help.
            closeFolder(persistCulling: false)
        }
    }

    /// Close the current album: drop selection + URL list, swap back to the
    /// empty state. Called by the double-Escape shortcut. Doesn't clear
    /// recents — the folder stays in MRU so re-opening is one click away.
    func closeFolder(persistCulling: Bool = true) {
        if persistCulling, !flushCullingState() { return }
        scanGeneration &+= 1
        // Cancel any in-flight scan first so a slow recursive walk doesn't
        // keep churning fs reads after the user closes the folder.
        scanTask?.cancel()
        scanTask = nil
        archiveExtractionTask?.cancel()
        archiveExtractionTask = nil
        stopWatching()
        loadedFolderContinuity = nil
        let extractionToRemove = extractedArchiveDir
        extractedArchiveDir = nil
        isBrowsingArchive = false
        archiveSourceURL = nil
        // The prefetch cache is folder-scoped — clear it so the new
        // (empty) state isn't holding ~480MB of decoded images that the
        // user can't see.
        prefetcher.clear()
        // Clear thumbnail cache — the new folder has no overlap.
        ThumbnailLoader.shared.clear()
        folder = nil
        anchorFolder = nil
        imageURLs = []
        vimKeymap = VimKeymap()
        isCullingPersistenceBlocked = false
        pendingUnverifiedCullingFolder = nil
        searchResultURLs = nil
        isSearchFieldFocused = false
        selection.reset()
        photoFilter = .all
        loadPhase = nil
        if let extractionToRemove {
            Self.removeArchiveExtractionInBackground(extractionToRemove)
        }
    }

    private static func isSameOrDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return candidatePath == directoryPath || candidatePath.hasPrefix(prefix)
    }

    /// Large archive previews can contain tens of thousands of entries. Once
    /// the main actor has severed every reference, delete that private tree on
    /// a utility task so closing or switching albums never freezes the window.
    nonisolated private static func removeArchiveExtractionInBackground(_ directory: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // Note: no deinit cancellation of the folder watchers — main-actor
    // isolation prevents accessing them from a nonisolated deinit. AppState
    // lives for the app's lifetime in this single-window version, so the OS
    // cleans up at exit. Call stopWatching() explicitly if that changes.
}
