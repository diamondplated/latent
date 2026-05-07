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
    /// Index of the currently-selected image (if any).
    var selectedIndex: Int? = nil
    /// True while the folder is being scanned. Computed from `loadPhase` so
    /// every loading-related field stays in lockstep — no chance of
    /// `isLoading=true` with a stale `loadPhase=nil` or vice versa.
    var isLoading: Bool { loadPhase != nil }
    /// Structured "what's happening right now" so the loader UI can render a
    /// rich, contextual scene instead of a plain spinner.
    var loadPhase: LoadPhase? = nil
    /// Last error surface (extraction failed, etc.) — UI can show in a toast.
    var lastError: String? = nil

    /// What stage the folder/archive open is in. Used to drive the loader UI.
    enum LoadPhase: Equatable {
        /// We're shelling out to /usr/bin/unzip or /usr/bin/tar.
        case extracting(archiveName: String)
        /// We're recursively walking the (possibly archive-extracted) folder.
        /// `photosFound` updates live as the AsyncStream yields batches.
        case scanning(folderName: String, photosFound: Int)
    }

    private var fileWatcher: DispatchSourceFileSystemObject?
    /// When the active folder was produced by archive extraction, hold on to
    /// the temp dir URL so we can clean it up when the user opens something
    /// else (or when the app quits).
    private var extractedArchiveDir: URL?

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "webp", "avif", "jxl", "gif", "bmp",
    ]

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
        Task { await loadFolder(url) }
    }

    func loadFolder(_ url: URL) async {
        selectedIndex = nil
        lastError = nil
        defer { loadPhase = nil }

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
                extractedArchiveDir = scanRoot
            } catch {
                lastError = "\(error)"
                folder = nil
                imageURLs = []
                return
            }
        } else {
            scanRoot = url
        }

        folder = scanRoot
        loadPhase = .scanning(folderName: scanRoot.lastPathComponent, photosFound: 0)
        // Drain the streaming scan, appending batches as they arrive so the
        // UI fills in live. For huge folders this is the difference between
        // "is this stuck?" and "X photos found, scanning…"
        imageURLs = []
        for await batch in Self.scanFolderStream(scanRoot) {
            imageURLs.append(contentsOf: batch)
            loadPhase = .scanning(folderName: scanRoot.lastPathComponent, photosFound: imageURLs.count)
        }
        // Final sort once the walk is done — sorting per-batch would be
        // O(N log N) per batch and force the LazyVGrid to keep diffing.
        let basePath = scanRoot.path
        imageURLs.sort { lhs, rhs in
            let l = lhs.path.hasPrefix(basePath) ? String(lhs.path.dropFirst(basePath.count)) : lhs.path
            let r = rhs.path.hasPrefix(basePath) ? String(rhs.path.dropFirst(basePath.count)) : rhs.path
            return l.localizedStandardCompare(r) == .orderedAscending
        }
        if !imageURLs.isEmpty { selectedIndex = 0 }

        startWatching(scanRoot)
    }

    /// Recursively walk a folder, yielding batches of image URLs as they're
    /// discovered. Streaming so `loadFolder` can show "Found X photos…"
    /// during a multi-second scan instead of looking frozen.
    private static func scanFolderStream(_ root: URL) -> AsyncStream<[URL]> {
        let imageExtensions = AppState.imageExtensions
        // Local-let the batch size so the detached task captures a value
        // (not a MainActor-isolated static).
        let batchSize = 64
        return AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                guard let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    continuation.finish()
                    return
                }
                var batch: [URL] = []
                // nextObject() works in async/detached contexts; the Sequence
                // form (`for-in`) is marked unavailable.
                while let next = enumerator.nextObject() {
                    guard let url = next as? URL else { continue }
                    if url.lastPathComponent == "__MACOSX" {
                        enumerator.skipDescendants()
                        continue
                    }
                    let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                    guard isFile else { continue }
                    guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                    batch.append(url)
                    if batch.count >= batchSize {
                        continuation.yield(batch)
                        batch = []
                    }
                }
                if !batch.isEmpty { continuation.yield(batch) }
                continuation.finish()
            }
        }
    }

    /// Synchronous version used by the file watcher's rescan path. Kept
    /// non-streaming because watchers fire on tiny diffs where a one-shot
    /// scan + replace is cheaper than re-streaming.
    private static func scanFolderRecursive(_ root: URL) async -> [URL] {
        var all: [URL] = []
        for await batch in scanFolderStream(root) { all.append(contentsOf: batch) }
        let basePath = root.path
        return all.sorted { lhs, rhs in
            let l = lhs.path.hasPrefix(basePath) ? String(lhs.path.dropFirst(basePath.count)) : lhs.path
            let r = rhs.path.hasPrefix(basePath) ? String(rhs.path.dropFirst(basePath.count)) : rhs.path
            return l.localizedStandardCompare(r) == .orderedAscending
        }
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
            // Preserve the user's current selection across the rescan.
            let previousURL = self.selectedIndex.flatMap { idx in
                idx < self.imageURLs.count ? self.imageURLs[idx] : nil
            }
            Task { @MainActor in
                let urls = await Self.scanFolderRecursive(url)
                self.imageURLs = urls
                self.selectedIndex = previousURL.flatMap { urls.firstIndex(of: $0) } ?? (urls.isEmpty ? nil : 0)
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
    }

    // Note: no deinit cancel of fileWatcher — main-actor isolation prevents
    // accessing it from a nonisolated deinit. The AppState lives for the
    // lifetime of the app in this minimal version, so OS cleans up at exit.
    // Call stopWatching() explicitly when migrating to a multi-window app.
}
