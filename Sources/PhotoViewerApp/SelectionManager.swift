import Foundation

/// Focused selection state extracted from AppState. Manages single-select,
/// multi-select (⌘-click toggle, shift-click range, ⌘A select-all), and
/// navigation (next/prev/first/last/jump-to-URL).
///
/// Operates on a reference to the parent's `imageURLs` array via a closure
/// so the selection stays in sync without duplicating the URL list.
@MainActor
@Observable
final class SelectionManager {
    /// Index of the currently-selected image (if any). The "primary" focus —
    /// what the detail view shows. In multi-select mode this is the most
    /// recent click + the anchor for shift-click range extension.
    var selectedIndex: Int? = nil

    /// Multi-selection set. Empty when in single-select mode (the typical
    /// case). When non-empty, Backspace trashes ALL of these instead of
    /// just the primary, and the toolbar shows a "N selected" pill.
    var multiSelection: Set<URL> = []

    /// Closure that returns the current image URL list. Avoids duplicating
    /// the array while keeping selection logic decoupled from AppState.
    var imageURLs: () -> [URL] = { [] }

    /// Convenience: the currently-selected URL, if valid.
    var currentURL: URL? {
        guard let i = selectedIndex else { return nil }
        let urls = imageURLs()
        guard i < urls.count else { return nil }
        return urls[i]
    }

    // MARK: - Navigation

    func selectNext() {
        let urls = imageURLs()
        guard !urls.isEmpty else { return }
        selectedIndex = min((selectedIndex ?? -1) + 1, urls.count - 1)
    }

    func selectPrevious() {
        let urls = imageURLs()
        guard !urls.isEmpty else { return }
        selectedIndex = max((selectedIndex ?? urls.count) - 1, 0)
    }

    func selectFirst() {
        selectedIndex = imageURLs().isEmpty ? nil : 0
    }

    func selectLast() {
        let urls = imageURLs()
        selectedIndex = urls.isEmpty ? nil : urls.count - 1
    }

    /// Jump to a specific URL (no-op if it's not in the current folder).
    /// Used by vim mark-jump and map-cluster selection.
    func select(url: URL) {
        if let i = imageURLs().firstIndex(of: url) {
            selectedIndex = i
        }
    }

    // MARK: - Multi-selection

    /// Toggle a single URL in the multi-selection (⌘-click handler).
    /// Also makes this URL the primary so subsequent shift-clicks anchor
    /// from here.
    func toggleMultiSelect(url: URL) {
        guard imageURLs().contains(url) else { return }
        if multiSelection.contains(url) {
            multiSelection.remove(url)
        } else {
            multiSelection.insert(url)
        }
        select(url: url)
    }

    /// Range-select from the current primary (selectedIndex) through the
    /// target URL. Replaces the current multi-selection.
    func extendMultiSelect(to url: URL) {
        let urls = imageURLs()
        guard let idx = urls.firstIndex(of: url) else { return }
        let anchor = selectedIndex ?? idx
        let lo = min(anchor, idx)
        let hi = max(anchor, idx)
        multiSelection = Set(urls[lo...hi])
        selectedIndex = idx
    }

    /// Select every photo. Bound to ⌘A.
    func selectAll() {
        let urls = imageURLs()
        guard !urls.isEmpty else { return }
        multiSelection = Set(urls)
    }

    /// Drop the multi-selection back to single-select mode.
    func clearMultiSelection() {
        multiSelection.removeAll()
    }

    // MARK: - Maintenance

    /// Called after images are removed (trash, rescan) to keep the
    /// selection valid. Tries to preserve the selected URL; falls back
    /// to the position or clamps.
    func adjustAfterRemoval(removedURLs: Set<URL>, previousURL: URL?) {
        let urls = imageURLs()
        multiSelection.subtract(removedURLs)
        if urls.isEmpty {
            selectedIndex = nil
        } else if let previousURL, let newIdx = urls.firstIndex(of: previousURL) {
            selectedIndex = newIdx
        } else {
            selectedIndex = min(selectedIndex ?? 0, urls.count - 1)
        }
    }

    /// Reset everything. Called on folder close/change.
    func reset() {
        selectedIndex = nil
        multiSelection.removeAll()
    }
}
