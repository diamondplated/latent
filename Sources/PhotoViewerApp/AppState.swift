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
    internal(set) var isCullingPersistenceBlocked = false
    /// A v0.2/resource fallback that exists but cannot be tied to the current
    /// directory automatically. The UI offers an explicit, reversible choice:
    /// import it only when the user recognizes this as the original folder.
    var pendingUnverifiedCullingFolder: URL?
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

    var folderChangeWatcher: RecursiveFolderWatcher?
    var extractedArchiveDir: URL?
    /// Archive contents are previews backed by a temporary extraction tree.
    /// Mutating them would appear to work and then vanish on close, so the UI
    /// and action layer treat the tree as explicitly read-only.
    internal(set) var isBrowsingArchive = false
    internal(set) var archiveSourceURL: URL?
    var loadedRecursively: Bool = false
    var watcherRescanTask: Task<Void, Never>? = nil
    var watcherRescanPending = false
    var scanTask: Task<Void, Never>? = nil
    var archiveExtractionTask: Task<URL, Error>? = nil
    var scanGeneration: UInt64 = 0
    /// Snapshot of the directory incarnation accepted for the active load.
    /// Watch callbacks compare it before and after every suspended walk so a
    /// delete/recreate at the same pathname can never inherit the old browser
    /// or culling session.
    var loadedFolderContinuity: FolderContinuity?
    /// Advances once per active, debounced filesystem batch, including content
    /// changes that leave `imageURLs` unchanged. Consumers use this to refresh
    /// folder-scoped derived data without treating the URL list as a change log.
    internal(set) var folderContentsChangeTick: UInt64 = 0
    /// Advances only for filesystem activity that can affect the active grid.
    /// In nonrecursive mode, deeper subtree events still stale the recursive
    /// search index but do not churn thumbnails or launch a pointless rescan.
    internal(set) var browserContentChangeTick: UInt64 = 0
    /// Advances at the start of every accepted folder load, including a
    /// same-URL switch between direct and recursive browsing.
    internal(set) var folderLoadTick: UInt64 = 0
    /// Signals view-local search UI to retire its query when an external
    /// controller needs to select from the complete unfiltered folder.
    internal(set) var browserFilterResetTick: UInt64 = 0
    /// Advances only when the selected media itself may have changed on disk.
    /// DetailView includes it in view/task identity so a same-URL overwrite
    /// reloads pixels, enhancement input, playback, and export state.
    internal(set) var selectedMediaContentTick: UInt64 = 0
    var folderTreeChangeTick: Int = 0
    internal(set) var lastRemovedFolder: URL? = nil

    struct FolderContinuity: Equatable, Sendable {
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

    static let unverifiedCullingStateMessage = "Latent found older saved picks, rejects, labels, or marks, but this folder changed afterward and its identity can’t be proven. Choose Use Saved Culls only if this is the same folder; otherwise keep culling disabled so the older data remains untouched."

    func reportUnverifiedCullingState() {
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

    // Note: no deinit cancellation of the folder watchers — main-actor
    // isolation prevents accessing them from a nonisolated deinit. AppState
    // lives for the app's lifetime in this single-window version, so the OS
    // cleans up at exit. Call stopWatching() explicitly if that changes.
}
