import Foundation
import PhotoIO

/// Model-free state of a folder's persisted semantic-search index.
/// Inspection performs filesystem reads only; it never loads Core ML assets,
/// starts indexing, or makes a network request.
public enum SearchIndexStatus: Sendable, Equatable {
    case missing
    case current(indexedCount: Int, skippedCount: Int)
    case stale(indexedCount: Int, skippedCount: Int, discoveredCount: Int)
}

public enum SearchIndexInspector {
    public static func inspect(folderURL: URL) async throws -> SearchIndexStatus {
        let paths = FolderPathMapper(rootURL: folderURL)
        let isDirectory = (try? paths.enumerationRootURL.resourceValues(
            forKeys: [.isDirectoryKey]
        ).isDirectory) ?? false
        guard isDirectory else { throw SearchError.folderNotADirectory(folderURL) }

        let indexURL = try EmbeddingIndex.indexFileURL(for: folderURL)
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            return .missing
        }

        let discoveryTask = Task.detached(priority: .utility) {
            try SearchEngine.discoverIndexableFiles(in: folderURL)
        }

        return try await withTaskCancellationHandler {
            do {
                let index = EmbeddingIndex(folderURL: folderURL)
                try await index.load()
                let entries = await index.allEntries
                let skippedEntries = await index.allSkippedEntries
                let files = try await discoveryTask.value
                try Task.checkCancellation()

                let indexedByPath = Dictionary(
                    entries.map { ($0.relativePath, $0) },
                    uniquingKeysWith: { newest, _ in newest }
                )
                let skippedByPath = Dictionary(
                    skippedEntries
                        .filter { indexedByPath[$0.relativePath] == nil }
                        .map { ($0.relativePath, $0) },
                    uniquingKeysWith: { newest, _ in newest }
                )
                let trackedCount = indexedByPath.count + skippedByPath.count
                let isCurrent = trackedCount == files.count && files.allSatisfy { file in
                    if let entry = indexedByPath[file.relativePath] {
                        return SearchEngine.indexEntry(entry, matches: file)
                    }
                    if let skipped = skippedByPath[file.relativePath] {
                        return SearchEngine.skippedEntry(skipped, matches: file)
                    }
                    return false
                }

                return isCurrent
                    ? .current(
                        indexedCount: indexedByPath.count,
                        skippedCount: skippedByPath.count
                    )
                    : .stale(
                        indexedCount: indexedByPath.count,
                        skippedCount: skippedByPath.count,
                        discoveredCount: files.count
                    )
            } catch {
                discoveryTask.cancel()
                throw error
            }
        } onCancel: {
            // Folder switches and closing search must not leave a detached
            // metadata walk chewing through a large library in the background.
            discoveryTask.cancel()
        }
    }
}
