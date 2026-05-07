import Foundation
import SwiftUI

/// Persisted MRU list of folders the user has opened. Stored as plain paths
/// in UserDefaults — when we ship as a sandboxed Mac App Store app, swap to
/// security-scoped bookmarks so we still have read access to user-picked
/// folders across launches.
@MainActor
@Observable
final class RecentFolders {
    /// Most-recent first. Capped at `maxEntries`.
    private(set) var entries: [URL] = []
    /// Cached file-existence flag per entry so a stale row (folder moved /
    /// deleted) renders dimmed without doing fs work in the view body. Recomputed
    /// in `refreshExistence()` whenever the list mutates or the empty state
    /// becomes visible.
    private(set) var stale: Set<URL> = []

    private let maxEntries = 12
    private let defaultsKey = "Latent.RecentFolders"

    init() {
        load()
        // Defer the existence check off the main actor — it's a stat-per-
        // entry loop that we don't want blocking app launch. The list
        // renders immediately with everything assumed-fresh, and the
        // `stale` set populates a beat later when the background pass
        // returns. Worst case: a user clicks a row 10ms before we know
        // it's stale, and AppState's loadFolder surfaces a clean error.
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.refreshExistence()
        }
    }

    /// Push a freshly-opened folder to the front of the list. Idempotent
    /// against duplicates — re-opening a folder moves it to the top.
    func push(_ url: URL) {
        let canonical = url.standardizedFileURL
        entries.removeAll { $0.standardizedFileURL == canonical }
        entries.insert(canonical, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        save()
        // Pushed entry is by definition fresh (we just opened it), so drop
        // it from `stale` if it was there. Skip the full re-scan — it'll
        // happen lazily next time the empty state shows.
        stale.remove(canonical)
    }

    /// Drop a single entry. Used by the X button on each row.
    func remove(_ url: URL) {
        let canonical = url.standardizedFileURL
        entries.removeAll { $0.standardizedFileURL == canonical }
        save()
    }

    /// Drop everything. Hooked to a "Clear" button in the recents list header.
    func removeAll() {
        entries.removeAll()
        save()
    }

    /// Re-stat each entry on disk; flag any whose folder is gone. Run off
    /// the main actor so the iteration over recents doesn't block. Results
    /// are applied back on main when done, which @Observable picks up and
    /// propagates to the view.
    func refreshExistence() async {
        let urls = entries
        let missing = await Task.detached(priority: .utility) {
            var found = Set<URL>()
            let fm = FileManager.default
            for url in urls {
                var isDir: ObjCBool = false
                let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
                if !exists || !isDir.boolValue { found.insert(url) }
            }
            return found
        }.value
        stale = missing
    }

    // MARK: - Persistence

    private func load() {
        let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [String] ?? []
        entries = raw.compactMap { path in
            guard !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
    }

    private func save() {
        UserDefaults.standard.set(entries.map(\.path), forKey: defaultsKey)
    }
}
