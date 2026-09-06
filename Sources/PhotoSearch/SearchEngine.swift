import Foundation
import os
import PipelineCore
import PhotoIO
import PhotoML

public enum SearchError: Error, CustomStringConvertible {
    case folderNotADirectory(URL)
    case readError(URL, any Error)
    case encoderError(any Error)
    case textNotAvailable

    public var description: String {
        switch self {
        case .folderNotADirectory(let url): return "Not a directory: \(url.path)"
        case .readError(let url, let err): return "Failed to read \(url.lastPathComponent): \(err)"
        case .encoderError(let err): return "CLIP encoder failed: \(err)"
        case .textNotAvailable:
            return "Text-query search needs the OpenCLIP text encoder + BPE merges file. Run scripts/convert_openclip.py."
        }
    }
}

public struct SearchResult: Sendable {
    public let entry: IndexedPhoto
    public let similarity: Float

    public init(entry: IndexedPhoto, similarity: Float) {
        self.entry = entry
        self.similarity = similarity
    }
}

public protocol SearchProgress: Sendable {
    func indexing(_ relativePath: String, current: Int, total: Int) async
}

public struct NoopSearchProgress: SearchProgress {
    public init() {}
    public func indexing(_ relativePath: String, current: Int, total: Int) async {}
}

public struct SearchIndexingReport: Sendable, Equatable {
    public let indexedCount: Int
    public let skippedCount: Int

    public init(indexedCount: Int, skippedCount: Int) {
        self.indexedCount = indexedCount
        self.skippedCount = skippedCount
    }
}

/// High-level search API. Holds an `EmbeddingIndex` for one folder; provides
/// methods to (re)index the folder and query by image or text.
///
/// Indexing strategy:
/// - On `index(progress:)`, walk the folder for image files
/// - For each file, check the existing index entry for staleness (file size
///   + mtime). If unchanged, skip. Otherwise encode and upsert.
/// - Remove entries whose file no longer exists.
/// - Persist to disk at the end.
public actor SearchEngine {
    public let folderURL: URL
    public let index: EmbeddingIndex
    private let imageEncoder: CLIPImageEncoder
    private let textEncoder: CLIPTextEncoder

    /// - Parameter recoverInvalidIndex: An explicit rebuild can recover from a
    ///   corrupt cache file by staging a fresh empty index. The corrupt file is
    ///   not replaced until `indexFolder` completes successfully.
    public init(folderURL: URL, recoverInvalidIndex: Bool = false) async throws {
        let paths = FolderPathMapper(rootURL: folderURL)
        let isDir = (try? paths.enumerationRootURL.resourceValues(
            forKeys: [.isDirectoryKey]
        ).isDirectory) ?? false
        guard isDir else { throw SearchError.folderNotADirectory(folderURL) }

        self.folderURL = folderURL
        self.index = EmbeddingIndex(folderURL: folderURL)
        do {
            self.imageEncoder = try await CLIPImageEncoder()
        } catch {
            throw SearchError.encoderError(error)
        }
        self.textEncoder = await CLIPTextEncoder()

        do {
            try await index.load()
        } catch {
            guard recoverInvalidIndex else { throw error }
            await index.clear()
        }
    }

    /// Walk the folder, encode new/changed images, drop missing files.
    /// Persists at the end.
    @discardableResult
    public func indexFolder(
        progress: any SearchProgress = NoopSearchProgress()
    ) async throws -> SearchIndexingReport {
        try Task.checkCancellation()
        let files = try Self.discoverIndexableFiles(in: folderURL)
        let total = files.count
        let reader = ImageReader()

        // Stage the whole refresh off-index and commit once. Cancellation can
        // therefore never leave `index` holding a dirty, partially-refreshed
        // set that a later query or retry might accidentally save.
        var refreshedByPath = Dictionary(
            uniqueKeysWithValues: await index.allEntries.map { ($0.relativePath, $0) }
        )
        var skippedByPath = Dictionary(
            uniqueKeysWithValues: await index.allSkippedEntries.map { ($0.relativePath, $0) }
        )
        var seenRelative = Set<String>()
        for (i, file) in files.enumerated() {
            try Task.checkCancellation()
            let url = file.url
            let rel = file.relativePath
            seenRelative.insert(rel)

            if let existing = refreshedByPath[rel],
               Self.indexEntry(existing, matches: file) {
                skippedByPath.removeValue(forKey: rel)
                await progress.indexing(rel, current: i + 1, total: total)
                continue
            }

            let buffer: ImageBuffer
            do {
                buffer = try reader.read(url: url).0
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A corrupt or undecodable photo is a per-file failure. Keep
                // indexing the folder and remember the exact failed snapshot
                // so freshness inspection doesn't create a retry loop.
                refreshedByPath.removeValue(forKey: rel)
                skippedByPath[rel] = file.skippedEntry
                Logger(subsystem: "com.latent.photo-viewer", category: "search")
                    .error("Failed to decode \(rel, privacy: .public): \(error)")
                await progress.indexing(rel, current: i + 1, total: total)
                continue
            }

            try Task.checkCancellation()
            let embedding: EmbeddingVector
            do {
                embedding = try await imageEncoder.encode(buffer)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error where Self.isSkippableImageEncodingFailure(error) {
                // Preprocessing can still expose an image-specific bridge
                // failure after decode. Treat that like an unreadable file.
                refreshedByPath.removeValue(forKey: rel)
                skippedByPath[rel] = file.skippedEntry
                Logger(subsystem: "com.latent.photo-viewer", category: "search")
                    .error("Failed to prepare \(rel, privacy: .public) for indexing: \(error)")
                await progress.indexing(rel, current: i + 1, total: total)
                continue
            } catch {
                // Model availability, prediction, and output-contract failures
                // affect the whole refresh. Abort before the transactional
                // commit so the previous complete index remains authoritative.
                throw SearchError.encoderError(error)
            }

            try Task.checkCancellation()
            let entry = IndexedPhoto(
                relativePath: rel,
                embedding: embedding,
                fileSize: file.fileSize,
                modifiedAt: file.modifiedAt
            )
            refreshedByPath[rel] = entry
            skippedByPath.removeValue(forKey: rel)
            await progress.indexing(rel, current: i + 1, total: total)
        }

        try Task.checkCancellation()
        // Drop entries for files that no longer exist.
        let obsoletePaths = refreshedByPath.keys.filter { !seenRelative.contains($0) }
        for path in obsoletePaths {
            try Task.checkCancellation()
            refreshedByPath.removeValue(forKey: path)
        }
        let obsoleteSkippedPaths = skippedByPath.keys.filter { !seenRelative.contains($0) }
        for path in obsoleteSkippedPaths {
            try Task.checkCancellation()
            skippedByPath.removeValue(forKey: path)
        }

        try Task.checkCancellation()
        // Also writes a valid zero-entry index for an empty folder, so the UI
        // can distinguish "indexed and empty" from "never indexed".
        try await index.replaceAllAndSave(
            Array(refreshedByPath.values),
            skipped: Array(skippedByPath.values)
        )
        return SearchIndexingReport(
            indexedCount: refreshedByPath.count,
            skippedCount: skippedByPath.count
        )
    }

    /// Find images in the index most similar to a query image.
    public func search(similarTo queryImage: ImageBuffer, k: Int = 20) async throws -> [SearchResult] {
        let q: EmbeddingVector
        do {
            q = try await imageEncoder.encode(queryImage)
        } catch {
            throw SearchError.encoderError(error)
        }
        let scored = await index.topK(k, similarTo: q)
        return scored.map { SearchResult(entry: $0.0, similarity: $0.1) }
    }

    /// Natural-language query via OpenCLIP text encoder + BPE tokenizer.
    /// Throws if either the text encoder model or the tokenizer vocab file
    /// isn't available (`scripts/convert_openclip.py` produces both).
    public func search(text: String, k: Int = 20) async throws -> [SearchResult] {
        guard await textEncoder.isAvailable else { throw SearchError.textNotAvailable }
        let q: EmbeddingVector
        do {
            q = try await textEncoder.encode(text)
        } catch {
            throw SearchError.encoderError(error)
        }
        let scored = await index.topK(k, similarTo: q)
        return scored.map { SearchResult(entry: $0.0, similarity: $0.1) }
    }

    // MARK: - Folder discovery

    nonisolated static let indexableImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "webp", "avif", "jxl", "gif", "bmp",
        // RAW formats supported by the viewer through ImageIO previews.
        "cr2", "cr3", "nef", "arw", "raf", "dng", "orf", "rw2",
    ]

    /// One filesystem snapshot used by both indexing and the model-free
    /// freshness inspector. Keeping discovery in one place prevents the UI
    /// from claiming an index is current for a different set of files than
    /// `indexFolder` would actually process.
    nonisolated static func discoverIndexableFiles(in folderURL: URL) throws -> [SearchFileSnapshot] {
        let fm = FileManager.default
        let paths = FolderPathMapper(rootURL: folderURL)
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        guard let enumerator = fm.enumerator(
            at: paths.enumerationRootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var files: [SearchFileSnapshot] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let ext = url.pathExtension.lowercased()
            guard Self.indexableImageExtensions.contains(ext) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            files.append(SearchFileSnapshot(
                url: url,
                relativePath: paths.relativePath(of: url) ?? url.standardizedFileURL.path,
                fileSize: values.fileSize ?? 0,
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }
        return files
    }

    nonisolated static func relativePath(_ url: URL, base: URL) -> String {
        FolderPathMapper(rootURL: base).relativePath(of: url)
            ?? url.standardizedFileURL.path
    }

    /// Legacy index files used Foundation's whole-second ISO-8601 encoder.
    /// Version 2 retains precise epoch seconds, but accept a sub-second
    /// mismatch when the stored value has no fraction so existing indexes do
    /// not look permanently stale after every launch.
    nonisolated static func indexEntry(_ entry: IndexedPhoto, matches file: SearchFileSnapshot) -> Bool {
        metadataMatches(
            fileSize: entry.fileSize,
            modifiedAt: entry.modifiedAt,
            file: file
        )
    }

    nonisolated static func skippedEntry(
        _ entry: SkippedIndexedPhoto,
        matches file: SearchFileSnapshot
    ) -> Bool {
        metadataMatches(
            fileSize: entry.fileSize,
            modifiedAt: entry.modifiedAt,
            file: file
        )
    }

    /// Only image-specific preprocessing failures are safe to downgrade to a
    /// skipped file. A prediction or model-contract failure is systemic and
    /// must abort the transactional refresh.
    nonisolated static func isSkippableImageEncodingFailure(_ error: any Error) -> Bool {
        guard let encoderError = error as? CLIPImageEncoderError else { return false }
        if case .bridgeError = encoderError { return true }
        return false
    }

    nonisolated private static func metadataMatches(
        fileSize: Int,
        modifiedAt: Date,
        file: SearchFileSnapshot
    ) -> Bool {
        guard fileSize == file.fileSize else { return false }
        let difference = abs(modifiedAt.timeIntervalSince(file.modifiedAt))
        if difference < 0.001_1 { return true }

        let storedSeconds = modifiedAt.timeIntervalSince1970
        let storedFraction = abs(storedSeconds - storedSeconds.rounded(.towardZero))
        return storedFraction < 0.000_001
            && Int64(storedSeconds.rounded(.down)) == Int64(file.modifiedAt.timeIntervalSince1970.rounded(.down))
    }
}

struct SearchFileSnapshot: Sendable {
    let url: URL
    let relativePath: String
    let fileSize: Int
    let modifiedAt: Date

    var skippedEntry: SkippedIndexedPhoto {
        SkippedIndexedPhoto(
            relativePath: relativePath,
            fileSize: fileSize,
            modifiedAt: modifiedAt
        )
    }
}
