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
    /// Folder currently being browsed.
    var folder: URL? = nil
    /// Image URLs in `folder`, sorted by name.
    var imageURLs: [URL] = []
    /// Index of the currently-selected image (if any).
    var selectedIndex: Int? = nil
    /// True while the folder is being scanned.
    var isLoading: Bool = false

    private var fileWatcher: DispatchSourceFileSystemObject?

    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "webp", "avif", "jxl", "gif",
    ]

    /// Open a folder picker; on selection, scan and watch the folder.
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Open Folder of Photos"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await loadFolder(url) }
    }

    func loadFolder(_ url: URL) async {
        folder = url
        selectedIndex = nil
        isLoading = true
        defer { isLoading = false }

        let urls = scanFolder(url)
        imageURLs = urls
        if !urls.isEmpty { selectedIndex = 0 }

        startWatching(url)
    }

    private func scanFolder(_ url: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return items
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Folder changed — rescan. Preserve the user's current selection
            // by remembering its URL and re-finding it post-scan.
            let previousURL = self.selectedIndex.flatMap { idx in
                idx < self.imageURLs.count ? self.imageURLs[idx] : nil
            }
            let urls = self.scanFolder(url)
            self.imageURLs = urls
            self.selectedIndex = previousURL.flatMap { urls.firstIndex(of: $0) } ?? (urls.isEmpty ? nil : 0)
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
