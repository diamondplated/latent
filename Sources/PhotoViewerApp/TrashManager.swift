import Foundation

/// Trash and undo logic extracted from AppState. Manages the trash history
/// ring, optimistic UI removal, bulk/folder trash, and ⌘Z undo.
///
/// Communicates back to the parent (AppState) through closures so it
/// doesn't need to own imageURLs, prefetcher, etc. directly.
@MainActor
@Observable
final class TrashManager {
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

    /// Ring of recent trash operations, newest at the end. ⌘Z pops the
    /// last one and tries to restore each entry from `~/.Trash`. Capped
    /// so a long session doesn't accumulate unbounded history.
    private(set) var trashHistory: [TrashRecord] = []
    private let trashHistoryCap = 20

    /// Last error from trash/undo operations.
    var lastError: String? = nil

    /// True when there's a trash op available to undo.
    var canUndoTrash: Bool { trashHistory.contains { !$0.undoRequested } }

    // MARK: - Callbacks (set by AppState at init)

    /// Called to optimistically remove images from the URL list before the
    /// async trash completes. Takes the ordered URLs to remove.
    var onOptimisticRemove: (([URL]) -> Void)?

    /// Called to re-insert URLs that failed to trash (or were restored).
    var onReinsertURLs: (([URL]) -> Void)?

    /// Called to evict URLs from the prefetch cache.
    var onEvictPrefetch: ((URL) -> Void)?

    /// Called when a folder is trashed and needs to close.
    var onFolderTrashed: ((URL) -> Void)?

    /// Called to remove a folder from recents.
    var onRemoveRecent: ((URL) -> Void)?

    /// Called to walk and re-add photos from a restored folder.
    var onRestoreFolder: ((URL) -> Void)?

    // MARK: - Image Trash

    /// Move a single image to the user's Trash.
    func trashImage(at url: URL) {
        trashImages([url])
    }

    /// Bulk trash. Each file is trashed individually (so a single failure
    /// doesn't take down the whole batch) but the resulting entries land
    /// in ONE TrashRecord, so ⌘Z restores them all together.
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

        for url in ordered { onEvictPrefetch?(url) }
        onOptimisticRemove?(ordered)

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

    /// Move a whole folder to the Trash.
    func trashFolder(at url: URL, currentFolder: URL?) {
        let recordID = UUID()
        pushTrashRecord(TrashRecord(
            id: recordID,
            entries: [.init(originalURL: url, trashURL: nil)],
            isFolder: true,
            isPending: true
        ))

        if url == currentFolder { onFolderTrashed?(url) }
        onRemoveRecent?(url)

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

    /// Undo the most recent trash operation.
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

    // MARK: - Private

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        var out: [URL] = []
        for url in urls where !seen.contains(url) {
            seen.insert(url)
            out.append(url)
        }
        return out
    }

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
            onReinsertURLs?(failedURLs)
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

        if record.isFolder, let restoredFolder = restored.first {
            onRestoreFolder?(restoredFolder)
            return
        }

        if !restored.isEmpty {
            onReinsertURLs?(restored)
        }
    }
}
