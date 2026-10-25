import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotoIO
import PhotoViewerCore

// Opening folders and archives, loading and cancelling scans, navigating up.

@MainActor
extension AppState {
    // MARK: - Opening and loading folders

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
}
