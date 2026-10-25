import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotoIO
import PhotoViewerCore

// Directory walks, photo sorting, folder-continuity checks and the
// filesystem watcher that keeps the grid live.

@MainActor
extension AppState {
    // MARK: - Walking, sorting and watching

    /// Walk a directory, returning all matched image URLs. `onProgress` is
    /// called every ~64 files with the running count so the loader's "X
    /// photos found" can tick up live. Honors the calling task's
    /// cancellation: `Task.isCancelled` short-circuits the enumerator on
    /// large trees, which is how the Stop button bails out mid-walk.
    ///
    /// We prefetch contentModificationDate alongside isRegularFile so the
    /// mtime-sort path doesn't pay a per-URL stat after the walk. The
    /// resourceValues are cached on the returned URLs.
    nonisolated static func walkFolder(
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
    static func folderContinuity(for url: URL) -> FolderContinuity? {
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

    func folderContinuityIsCurrent(at root: URL) -> Bool {
        guard let loadedFolderContinuity,
              let current = Self.folderContinuity(for: root) else { return false }
        return current.identifiesSameDirectory(as: loadedFolderContinuity)
    }

    func closeForFolderContinuityLoss(at root: URL) {
        guard folder == root else { return }
        closeFolder(persistCulling: false)
        lastError = "The open folder was moved, removed, or replaced. Latent closed it so saved culling state stays attached to the original folder. Reopen the folder at its current location."
    }

    /// File-watcher rescan path. Honors the load's recursive flag so a
    /// non-recursive folder doesn't trigger a full-tree walk on every fs
    /// event. Cancellable: the watcher cancels an in-flight rescan when a
    /// new event fires, so rapid-fire events coalesce.
    nonisolated static func walkAndSort(_ root: URL, recursive: Bool, sort: FolderSort) async -> [URL] {
        let basePath = root.path
        let all = await walkFolder(root, recursive: recursive)
        if Task.isCancelled { return all }
        return Self.sortPhotos(all, by: sort, basePath: basePath)
    }

    func startWatching(
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
    func scheduleWatcherRescan(
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
    func viewerRelevantBatch(
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
    func invalidateMediaCaches(
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
}
