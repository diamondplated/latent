import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotoIO
import PhotoViewerCore

// Selection, vim-action dispatch and trash, delegated to the sub-objects.

@MainActor
extension AppState {
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



    func optimisticallyRemoveImages(_ urls: [URL]) {
        let trashedSet = Set(urls)
        let selectedURL = currentURL
        for url in trashedSet { prefetcher.evict(url: url) }
        imageURLs.removeAll { trashedSet.contains($0) }
        selection.adjustAfterRemoval(removedURLs: trashedSet, previousURL: selectedURL)
    }

    func reinsertFailedTrashURLs(_ urls: [URL]) {
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
    func ensureWritableSource() -> Bool {
        guard !isBrowsingArchive else {
            lastError = "Archive previews are read-only. Extract the archive in Finder before editing or trashing its contents."
            return false
        }
        return true
    }

    func handleFolderTrashSuccess(_ url: URL) {
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

    static func isSameOrDescendant(_ candidate: URL, of directory: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return candidatePath == directoryPath || candidatePath.hasPrefix(prefix)
    }

    /// Large archive previews can contain tens of thousands of entries. Once
    /// the main actor has severed every reference, delete that private tree on
    /// a utility task so closing or switching albums never freezes the window.
    nonisolated static func removeArchiveExtractionInBackground(_ directory: URL) {
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
