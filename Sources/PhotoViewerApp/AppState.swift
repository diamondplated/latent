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
    /// MRU list of opened folders — drives the empty-state Recent panel.
    /// Shared singleton so the empty state and any future "Open Recent" menu
    /// stay in sync.
    let recents = RecentFolders()
    /// Whether the enhancement side panel is visible. Default false: the app
    /// is primarily a viewer; enhancement is opt-in. Toolbar button toggles.
    var showEnhancementPanel: Bool = false
    /// Whether the folder-tree sidebar (far-left pane) is visible. Default
    /// false to keep the layout simple for new users; toolbar button toggles.
    var showFolderTree: Bool = false
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
    /// When the active folder was produced by archive extraction, hold on to
    /// the temp dir URL so we can clean it up when the user opens something
    /// else (or when the app quits).
    private var extractedArchiveDir: URL?

    /// Everything Latent will pick up during a folder scan. Static images,
    /// animated images (GIF / APNG / animated HEIC etc.), and video formats
    /// AVFoundation can take a swing at. The actual playback decision is
    /// made later by `MediaTyping.detect` per file.
    static var imageExtensions: Set<String> { MediaTyping.allMediaExts }

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

    /// Open a folder.
    /// - Parameter setAsAnchor: When true (the default — used by the Open
    ///   dialog, Recents, drag-drop, and the right-click → Open With path),
    ///   pins this folder as the folder-tree's root so the tree shows from
    ///   here. When false (used by the folder-tree click handler itself),
    ///   only the active folder changes — the tree stays anchored.
    /// - Parameter recursive: When true (the default — used by the Open
    ///   dialog and friends), bulk-scan everything under the folder.
    ///   When false (used by the folder-tree drill path), scan only this
    ///   folder's direct contents — the tree IS the navigation, recursing
    ///   into subfolders would defeat the point.
    func loadFolder(_ url: URL, setAsAnchor: Bool = true, recursive: Bool = true) async {
        selectedIndex = nil
        lastError = nil
        defer { loadPhase = nil }
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
        // Push the user's ORIGINAL pick (which may be an archive file) to
        // the recents — re-opening from recents replays the same flow,
        // including extraction. Only push real, non-temp paths so cleaned-
        // up extraction dirs don't poison the list.
        if extractedArchiveDir == nil {
            recents.push(url)
        } else {
            recents.push(url)  // archives are pushed as the .zip path
        }
        loadPhase = .scanning(folderName: scanRoot.lastPathComponent, photosFound: 0)
        // Stream-collect on a background task so SwiftUI doesn't see imageURLs
        // grow batch-by-batch (each batch update was forcing the toolbar /
        // grid to diff a growing N-item array, multiplying main-thread work
        // by O(batches) on huge folders). Live count comes from loadPhase
        // alone; imageURLs is set once at the end.
        let pathBase = scanRoot.path
        let stream = Self.scanFolderStream(scanRoot, recursive: recursive)
        let folderName = scanRoot.lastPathComponent
        let collected: [URL] = await Task.detached(priority: .userInitiated) { [weak self] in
            var found: [URL] = []
            for await batch in stream {
                found.append(contentsOf: batch)
                let count = found.count
                // Hop to the main actor only for the live count update —
                // not the imageURLs append. This makes the loader's count
                // tick smoothly without paying the ForEach diff cost on
                // every batch.
                await MainActor.run { [weak self] in
                    self?.loadPhase = .scanning(folderName: folderName, photosFound: count)
                }
            }
            // Sort happens on the same background task before we hand the
            // array to SwiftUI. localizedStandardCompare on N=10k+ paths
            // is the kind of work that absolutely must not be on main.
            found.sort { lhs, rhs in
                let l = lhs.path.hasPrefix(pathBase) ? String(lhs.path.dropFirst(pathBase.count)) : lhs.path
                let r = rhs.path.hasPrefix(pathBase) ? String(rhs.path.dropFirst(pathBase.count)) : rhs.path
                return l.localizedStandardCompare(r) == .orderedAscending
            }
            return found
        }.value

        // One atomic update: imageURLs gets the full sorted list, SwiftUI
        // does ONE diff (against the empty starting state).
        imageURLs = collected
        if !imageURLs.isEmpty { selectedIndex = 0 }

        startWatching(scanRoot)
    }

    /// Recursively walk a folder, yielding batches of image URLs as they're
    /// discovered. Streaming so `loadFolder` can show "Found X photos…"
    /// during a multi-second scan instead of looking frozen.
    private static func scanFolderStream(_ root: URL, recursive: Bool) -> AsyncStream<[URL]> {
        let imageExtensions = AppState.imageExtensions
        let batchSize = 64
        return AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                let fm = FileManager.default

                // For non-recursive scans (folder-tree drill path), use
                // contentsOfDirectory and yield in one shot. Cheap, finite,
                // doesn't fight with the recursive enumerator's depth-first
                // walk.
                if !recursive {
                    let items = (try? fm.contentsOfDirectory(
                        at: root,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    let photos = items.filter { url in
                        let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                        return isFile && imageExtensions.contains(url.pathExtension.lowercased())
                    }
                    if !photos.isEmpty { continuation.yield(photos) }
                    continuation.finish()
                    return
                }

                // Recursive path: streaming enumerator + batch yields so the
                // loader can show "Found X photos…" tick up live.
                guard let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else {
                    continuation.finish()
                    return
                }
                var batch: [URL] = []
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
        for await batch in scanFolderStream(root, recursive: true) {
            all.append(contentsOf: batch)
        }
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

    /// Close the current album: drop selection + URL list, swap back to the
    /// empty state. Called by the double-Escape shortcut. Doesn't clear
    /// recents — the folder stays in MRU so re-opening is one click away.
    func closeFolder() {
        stopWatching()
        if let prev = extractedArchiveDir {
            try? FileManager.default.removeItem(at: prev)
            extractedArchiveDir = nil
        }
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
