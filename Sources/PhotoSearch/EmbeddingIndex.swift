import Foundation
import CryptoKit

public enum EmbeddingIndexError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidEmbeddingDimension(relativePath: String, actual: Int)
    case nonFiniteEmbedding(relativePath: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This search index uses unsupported format version \(version). Rebuild it with this version of Latent."
        case .invalidEmbeddingDimension(let relativePath, let actual):
            return "The saved search vector for \(relativePath) has \(actual) values; expected \(EmbeddingVector.clipDimension). Rebuild this folder's index."
        case .nonFiniteEmbedding(let relativePath):
            return "The saved search vector for \(relativePath) contains an invalid number. Rebuild this folder's index."
        }
    }
}

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

/// Metadata for an allowlisted file that could not be decoded or embedded
/// during the most recent complete indexing pass. Persisting this separately
/// lets freshness inspection distinguish a known skipped file from a new file
/// that has never been considered, without exposing it to similarity queries.
public struct SkippedIndexedPhoto: Sendable, Codable, Equatable {
    public let relativePath: String
    public let fileSize: Int
    public let modifiedAt: Date

    public init(relativePath: String, fileSize: Int, modifiedAt: Date) {
        self.relativePath = relativePath
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
    private static let supportedVersion = 2

    public let folderURL: URL
    private var entries: [String: IndexedPhoto] = [:]  // keyed by relativePath
    private var skippedEntries: [String: SkippedIndexedPhoto] = [:]
    private var dirty: Bool = false

    public init(folderURL: URL) {
        self.folderURL = folderURL
    }

    public var count: Int { entries.count }

    public var allEntries: [IndexedPhoto] { Array(entries.values) }

    public var allSkippedEntries: [SkippedIndexedPhoto] { Array(skippedEntries.values) }

    public func entry(forRelativePath path: String) -> IndexedPhoto? {
        entries[path]
    }

    public func upsert(_ entry: IndexedPhoto) {
        entries[entry.relativePath] = entry
        skippedEntries.removeValue(forKey: entry.relativePath)
        dirty = true
    }

    public func remove(relativePath: String) {
        let removedEntry = entries.removeValue(forKey: relativePath) != nil
        let removedSkipped = skippedEntries.removeValue(forKey: relativePath) != nil
        if removedEntry || removedSkipped {
            dirty = true
        }
    }

    public func clear() {
        entries.removeAll()
        skippedEntries.removeAll()
        dirty = true
    }

    /// Top-K most similar entries to a query vector by cosine similarity.
    /// Linear scan — fine up to ~50k entries; for larger libraries we'd
    /// want HNSW or similar (different milestone).
    public func topK(_ k: Int, similarTo query: EmbeddingVector) -> [(IndexedPhoto, Float)] {
        guard k > 0,
              query.dimension == EmbeddingVector.clipDimension,
              query.values.allSatisfy(\.isFinite) else { return [] }
        let q = query.normalized()
        // Loaded and persisted entries are validated, but keep this scan
        // total even if a caller temporarily upserts a malformed vector.
        let scored = entries.values.compactMap { entry -> (IndexedPhoto, Float)? in
            guard entry.embedding.dimension == EmbeddingVector.clipDimension,
                  entry.embedding.values.allSatisfy(\.isFinite) else { return nil }
            return (entry, entry.embedding.cosineSimilarity(q))
        }
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
        let header = try JSONDecoder().decode(IndexHeader.self, from: data)
        guard (1...Self.supportedVersion).contains(header.version) else {
            throw EmbeddingIndexError.unsupportedVersion(header.version)
        }
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        // Version 2 stores precise epoch seconds. Continue accepting version 1
        // ISO-8601 strings so indexes made by Latent 0.2 remain readable.
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            if let date = Self.decodeLegacyDate(value) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected epoch seconds or an ISO-8601 date string."
            )
        }
        let payload = try decoder.decode(IndexFile.self, from: data)
        guard payload.folderPath == folderURL.path else {
            // Hash collision (astronomically unlikely) or path moved — start fresh.
            return
        }
        try Self.validate(payload.entries)
        entries.removeAll()
        for entry in payload.entries {
            entries[entry.relativePath] = entry
        }
        skippedEntries.removeAll()
        for entry in payload.skippedEntries ?? [] {
            skippedEntries[entry.relativePath] = entry
        }
        dirty = false
    }

    public func save() throws {
        guard dirty else { return }
        try Self.write(
            entries: Array(entries.values),
            skippedEntries: Array(skippedEntries.values),
            folderURL: folderURL
        )
        dirty = false
    }

    /// Transactional refresh used by SearchEngine. The replacement is encoded
    /// and atomically written before becoming visible in memory, so a failed
    /// write leaves both the persisted and live index on the previous complete
    /// snapshot rather than a mixture of old and new entries.
    public func replaceAllAndSave(
        _ replacement: [IndexedPhoto],
        skipped replacementSkipped: [SkippedIndexedPhoto] = []
    ) throws {
        try Task.checkCancellation()
        try Self.write(
            entries: replacement,
            skippedEntries: replacementSkipped,
            folderURL: folderURL
        )
        entries = Dictionary(
            replacement.map { ($0.relativePath, $0) },
            uniquingKeysWith: { newest, _ in newest }
        )
        skippedEntries = Dictionary(
            replacementSkipped.map { ($0.relativePath, $0) },
            uniquingKeysWith: { newest, _ in newest }
        )
        dirty = false
    }

    private static func write(
        entries: [IndexedPhoto],
        skippedEntries: [SkippedIndexedPhoto],
        folderURL: URL
    ) throws {
        try Task.checkCancellation()
        try validate(entries)
        let url = try indexFileURL(for: folderURL)
        let payload = IndexFile(
            version: supportedVersion,
            folderPath: folderURL.path,
            updatedAt: Date(),
            entries: entries,
            skippedEntries: skippedEntries
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Epoch seconds preserve the sub-second filesystem timestamp used for
        // exact freshness checks; Foundation's ISO-8601 encoder does not.
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(payload)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }

    private static func validate(_ entries: [IndexedPhoto]) throws {
        for entry in entries {
            guard entry.embedding.dimension == EmbeddingVector.clipDimension else {
                throw EmbeddingIndexError.invalidEmbeddingDimension(
                    relativePath: entry.relativePath,
                    actual: entry.embedding.dimension
                )
            }
            guard entry.embedding.values.allSatisfy(\.isFinite) else {
                throw EmbeddingIndexError.nonFiniteEmbedding(
                    relativePath: entry.relativePath
                )
            }
        }
    }

    private static func decodeLegacyDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        if let date = wholeSeconds.date(from: value) { return date }

        // A short-lived development build emitted fractional UTC timestamps
        // without an explicit zone. Accept those local caches as UTC too.
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    private struct IndexHeader: Decodable {
        let version: Int
    }

    private struct IndexFile: Codable {
        let version: Int
        let folderPath: String
        let updatedAt: Date
        let entries: [IndexedPhoto]
        let skippedEntries: [SkippedIndexedPhoto]?
    }
}
