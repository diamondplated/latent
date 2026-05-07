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
        refreshExistence()
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
        refreshExistence()
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

    /// Re-stat each entry on disk; flag any whose folder is gone. Cheap (one
    /// stat per entry) and only runs when the empty-state surface is visible.
    func refreshExistence() {
        var missing = Set<URL>()
        let fm = FileManager.default
        for url in entries {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
            if !exists || !isDir.boolValue { missing.insert(url) }
        }
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
