import Foundation
import PipelineCore
import PhotoIO
import PhotoML

public enum SearchError: Error, CustomStringConvertible {
    case folderNotADirectory(URL)
    case readError(URL, any Error)
    case encoderError(any Error)
    case textNotImplemented

    public var description: String {
        switch self {
        case .folderNotADirectory(let url): "Not a directory: \(url.path)"
        case .readError(let url, let err): "Failed to read \(url.lastPathComponent): \(err)"
        case .encoderError(let err): "CLIP encoder failed: \(err)"
        case .textNotImplemented: "Text-query search needs the BPE tokenizer (not yet shipped)"
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

    public init(folderURL: URL) async throws {
        let isDir = (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDir else { throw SearchError.folderNotADirectory(folderURL) }

        self.folderURL = folderURL
        self.index = EmbeddingIndex(folderURL: folderURL)
        do {
            self.imageEncoder = try await CLIPImageEncoder()
        } catch {
            throw SearchError.encoderError(error)
        }
        self.textEncoder = await CLIPTextEncoder()

        try await index.load()
    }

    /// Walk the folder, encode new/changed images, drop missing files.
    /// Persists at the end.
    public func indexFolder(progress: any SearchProgress = NoopSearchProgress()) async throws {
        let urls = try discoverImageURLs()
        let total = urls.count
        let reader = ImageReader()

        var seenRelative = Set<String>()
        for (i, url) in urls.enumerated() {
            let rel = relativePath(url, base: folderURL)
            seenRelative.insert(rel)

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attrs?[.size] as? Int) ?? 0
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast

            if let existing = await index.entry(forRelativePath: rel),
               existing.fileSize == fileSize,
               existing.modifiedAt == mtime {
                await progress.indexing(rel, current: i + 1, total: total)
                continue
            }

            do {
                let (buffer, _) = try reader.read(url: url)
                let embedding = try await imageEncoder.encode(buffer)
                let entry = IndexedPhoto(
                    relativePath: rel,
                    embedding: embedding,
                    fileSize: fileSize,
                    modifiedAt: mtime
                )
                await index.upsert(entry)
            } catch {
                // Don't fail the whole index for one bad file — log and skip.
                print("photo-search: failed to index \(rel): \(error)")
            }
            await progress.indexing(rel, current: i + 1, total: total)
        }

        // Drop entries for files that no longer exist.
        let existing = await index.allEntries.map(\.relativePath)
        for path in existing where !seenRelative.contains(path) {
            await index.remove(relativePath: path)
        }

        try await index.save()
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

    /// Natural-language query. **Currently throws** — needs the BPE tokenizer.
    public func search(text: String, k: Int = 20) async throws -> [SearchResult] {
        guard await textEncoder.isAvailable else { throw SearchError.textNotImplemented }
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

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "webp", "avif", "jxl", "gif",
    ]

    private func discoverImageURLs() throws -> [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
        guard let enumerator = fm.enumerator(
            at: folderURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard Self.imageExtensions.contains(ext) else { continue }
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            if isFile {
                urls.append(url)
            }
        }
        return urls
    }

    private func relativePath(_ url: URL, base: URL) -> String {
        let basePath = base.path
        let urlPath = url.path
        if urlPath.hasPrefix(basePath + "/") {
            return String(urlPath.dropFirst(basePath.count + 1))
        }
        return urlPath
    }
}
