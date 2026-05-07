import Foundation
import CryptoKit

/// One entry in a per-folder embedding index.
public struct IndexedPhoto: Sendable, Codable {
    public let relativePath: String   // relative to the folder root for portability
    public let embedding: EmbeddingVector
    public let fileSize: Int           // for staleness detection
    public let modifiedAt: Date

    public init(relativePath: String, embedding: EmbeddingVector, fileSize: Int, modifiedAt: Date) {
        self.relativePath = relativePath
        self.embedding = embedding
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }
}

/// Persistent embedding index for one folder.
///
/// Stored at `~/Library/Application Support/photo-viewer/SearchIndices/<sha>.json`
/// where `<sha>` is a hash of the folder URL. Hash so the index file lives
/// outside the user's photo folder (don't pollute their library) but is still
/// addressable per folder.
///
/// Thread-safe via actor isolation. Reads/writes happen on the actor's
/// executor; concurrent search queries are safe.
public actor EmbeddingIndex {
    public let folderURL: URL
    private var entries: [String: IndexedPhoto] = [:]  // keyed by relativePath
    private var dirty: Bool = false

    public init(folderURL: URL) {
        self.folderURL = folderURL
    }

    public var count: Int { entries.count }

    public var allEntries: [IndexedPhoto] { Array(entries.values) }

    public func entry(forRelativePath path: String) -> IndexedPhoto? {
        entries[path]
    }

    public func upsert(_ entry: IndexedPhoto) {
        entries[entry.relativePath] = entry
        dirty = true
    }

    public func remove(relativePath: String) {
        if entries.removeValue(forKey: relativePath) != nil {
            dirty = true
        }
    }

    public func clear() {
        entries.removeAll()
        dirty = true
    }

    /// Top-K most similar entries to a query vector by cosine similarity.
    /// Linear scan — fine up to ~50k entries; for larger libraries we'd
    /// want HNSW or similar (different milestone).
    public func topK(_ k: Int, similarTo query: EmbeddingVector) -> [(IndexedPhoto, Float)] {
        let q = query.normalized()
        let scored = entries.values.map { ($0, $0.embedding.cosineSimilarity(q)) }
        return Array(scored.sorted { $0.1 > $1.1 }.prefix(k))
    }

    // MARK: - Persistence

    public static func indexFileURL(for folderURL: URL) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("photo-viewer/SearchIndices", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sha = SHA256.hash(data: Data(folderURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return base.appendingPathComponent("\(sha).json")
    }

    public func load() throws {
        let url = try Self.indexFileURL(for: folderURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(IndexFile.self, from: data)
        guard payload.folderPath == folderURL.path else {
            // Hash collision (astronomically unlikely) or path moved — start fresh.
            return
        }
        entries.removeAll()
        for entry in payload.entries {
            entries[entry.relativePath] = entry
        }
        dirty = false
    }

    public func save() throws {
        guard dirty else { return }
        let url = try Self.indexFileURL(for: folderURL)
        let payload = IndexFile(
            version: 1,
            folderPath: folderURL.path,
            updatedAt: Date(),
            entries: Array(entries.values)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
        dirty = false
    }

    private struct IndexFile: Codable {
        let version: Int
        let folderPath: String
        let updatedAt: Date
        let entries: [IndexedPhoto]
    }
}
