import Foundation

public typealias SharedFolderID = String

public struct SharedFolderSummary: Sendable, Equatable {
    public let id: SharedFolderID
    public let name: String
    public let photoCount: Int
}

public struct PhotoEntry: Sendable, Equatable {
    public let id: String
    public let name: String
}

/// The set of folders a paired phone may see, and the only place a client
/// identifier becomes a filesystem path.
///
/// IDs are random and issued at share time. The client never sends a path, so
/// traversal is not filtered — it is unrepresentable. An ID that was never
/// issued resolves to nil no matter what it looks like, and unsharing drops
/// every ID it issued.
public actor SharedFolders {
    private struct Entry {
        let url: URL
        let folderID: SharedFolderID
    }

    private var folderOrder: [SharedFolderID] = []
    private var folderRoots: [SharedFolderID: URL] = [:]
    private var folderPhotoIDs: [SharedFolderID: [String]] = [:]
    private var entries: [String: Entry] = [:]

    public init() {}

    /// Share `folder`, exposing exactly `photos`. Re-sharing a folder that is
    /// already shared replaces its photo list and retires the old IDs, which
    /// is what the file watcher wants after a rescan.
    @discardableResult
    public func share(folder: URL, photos: [URL]) -> SharedFolderID {
        let existing = folderRoots.first(where: { $0.value == folder })?.key
        let folderID = existing ?? UUID().uuidString
        if existing != nil { retirePhotoIDs(of: folderID) } else { folderOrder.append(folderID) }

        folderRoots[folderID] = folder
        var ids: [String] = []
        ids.reserveCapacity(photos.count)
        for url in photos {
            let id = UUID().uuidString
            entries[id] = Entry(url: url, folderID: folderID)
            ids.append(id)
        }
        folderPhotoIDs[folderID] = ids
        return folderID
    }

    public func unshare(_ folderID: SharedFolderID) {
        retirePhotoIDs(of: folderID)
        folderPhotoIDs.removeValue(forKey: folderID)
        folderRoots.removeValue(forKey: folderID)
        folderOrder.removeAll { $0 == folderID }
    }

    public func unshareAll() {
        entries.removeAll()
        folderPhotoIDs.removeAll()
        folderRoots.removeAll()
        folderOrder.removeAll()
    }

    public func folders() -> [SharedFolderSummary] {
        folderOrder.compactMap { id in
            guard let root = folderRoots[id] else { return nil }
            return SharedFolderSummary(
                id: id,
                name: root.lastPathComponent,
                photoCount: folderPhotoIDs[id]?.count ?? 0
            )
        }
    }

    public func photos(in folderID: SharedFolderID) -> [PhotoEntry] {
        (folderPhotoIDs[folderID] ?? []).compactMap { id in
            guard let entry = entries[id] else { return nil }
            return PhotoEntry(id: id, name: entry.url.lastPathComponent)
        }
    }

    public func photoURL(forID id: String) -> URL? {
        entries[id]?.url
    }

    public func photoID(for url: URL) -> String? {
        entries.first(where: { $0.value.url == url })?.key
    }

    private func retirePhotoIDs(of folderID: SharedFolderID) {
        for id in folderPhotoIDs[folderID] ?? [] {
            entries.removeValue(forKey: id)
        }
    }
}
