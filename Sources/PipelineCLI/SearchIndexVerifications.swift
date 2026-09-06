import Foundation
import PhotoSearch

/// Version 2 fixes sub-second timestamp precision while retaining indexes
/// made by 0.2. Future payloads must fail closed instead of being silently
/// reinterpreted by an older build.
public func embeddingIndexVersionCompatibility() async throws {
    let fileManager = FileManager.default
    let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("pv-search-version-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let indexURL = try EmbeddingIndex.indexFileURL(for: folder)
    defer {
        try? fileManager.removeItem(at: folder)
        try? fileManager.removeItem(at: indexURL)
    }

    let legacy: [String: Any] = [
        "version": 1,
        "folderPath": folder.path,
        "updatedAt": "2026-01-02T03:04:05Z",
        "entries": [[
            "relativePath": "legacy.jpg",
            "embedding": ["values": Array(repeating: 0.25, count: EmbeddingVector.clipDimension)],
            "fileSize": 42,
            "modifiedAt": "2026-01-02T03:04:05Z",
        ]],
    ]
    try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        .write(to: indexURL, options: .atomic)

    let legacyIndex = EmbeddingIndex(folderURL: folder)
    try await legacyIndex.load()
    let loaded = await legacyIndex.entry(forRelativePath: "legacy.jpg")
    try require(loaded?.fileSize == 42, "version-1 search entry did not load")

    let future: [String: Any] = [
        "version": 999,
        "folderPath": folder.path,
        "updatedAt": 0,
        "entries": [],
    ]
    try JSONSerialization.data(withJSONObject: future, options: [.sortedKeys])
        .write(to: indexURL, options: .atomic)

    let futureIndex = EmbeddingIndex(folderURL: folder)
    do {
        try await futureIndex.load()
        throw VerifyError(message: "future search-index format unexpectedly loaded")
    } catch let error as EmbeddingIndexError {
        try require(
            error == .unsupportedVersion(999),
            "wrong future-version error: \(error)"
        )
    }
}

/// Treat the search index as untrusted local input. Wrong-width and
/// non-finite vectors must be rejected before `topK` can compare them with a
/// model-produced 512-value query.
public func malformedSearchEmbeddingsAreRejected() async throws {
    let fileManager = FileManager.default
    let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("pv-search-malformed-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let indexURL = try EmbeddingIndex.indexFileURL(for: folder)
    defer {
        try? fileManager.removeItem(at: folder)
        try? fileManager.removeItem(at: indexURL)
    }

    func writeCache(values: [Any]) throws {
        let payload: [String: Any] = [
            "version": 2,
            "folderPath": folder.path,
            "updatedAt": 1_700_000_000.0,
            "entries": [[
                "relativePath": "bad.jpg",
                "embedding": ["values": values],
                "fileSize": 42,
                "modifiedAt": 1_700_000_000.0,
            ]],
            "skippedEntries": [],
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: indexURL, options: .atomic)
    }

    try writeCache(values: Array(
        repeating: 0.25,
        count: EmbeddingVector.clipDimension - 1
    ))
    let wrongDimension = EmbeddingIndex(folderURL: folder)
    do {
        try await wrongDimension.load()
        throw VerifyError(message: "wrong-width search vector unexpectedly loaded")
    } catch let error as EmbeddingIndexError {
        try require(
            error == .invalidEmbeddingDimension(
                relativePath: "bad.jpg",
                actual: EmbeddingVector.clipDimension - 1
            ),
            "wrong dimension-validation error: \(error)"
        )
    }
    let wrongDimensionCount = await wrongDimension.count
    try require(wrongDimensionCount == 0, "wrong-width cache partially loaded")

    var nonFiniteValues: [Any] = Array(
        repeating: 0.25,
        count: EmbeddingVector.clipDimension
    )
    nonFiniteValues[17] = "NaN"
    try writeCache(values: nonFiniteValues)
    let nonFinite = EmbeddingIndex(folderURL: folder)
    do {
        try await nonFinite.load()
        throw VerifyError(message: "non-finite search vector unexpectedly loaded")
    } catch let error as EmbeddingIndexError {
        try require(
            error == .nonFiniteEmbedding(relativePath: "bad.jpg"),
            "wrong non-finite validation error: \(error)"
        )
    }
    let nonFiniteCount = await nonFinite.count
    try require(nonFiniteCount == 0, "non-finite cache partially loaded")

    let inMemory = EmbeddingIndex(folderURL: folder)
    await inMemory.upsert(IndexedPhoto(
        relativePath: "bad.jpg",
        embedding: EmbeddingVector([1, 0, 0]),
        fileSize: 42,
        modifiedAt: .distantPast
    ))
    let results = await inMemory.topK(10, similarTo: clipVector(axis: 0))
    try require(results.isEmpty, "topK did not safely ignore an invalid in-memory vector")
}

/// The desktop search bar relies on this model-free inspector before it ever
/// loads Core ML. Pin the full missing -> current -> stale -> current journey,
/// including formats that used to be omitted from semantic search.
public func searchIndexInspectorTracksFolderFreshness() async throws {
    let fileManager = FileManager.default
    let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("pv-search-status-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: folder)
        if let indexURL = try? EmbeddingIndex.indexFileURL(for: folder) {
            try? fileManager.removeItem(at: indexURL)
        }
    }

    let missing = try await SearchIndexInspector.inspect(folderURL: folder)
    try require(missing == .missing, "new folder should have no search index, got \(missing)")

    let files = [
        folder.appendingPathComponent("photo.jpg"),
        folder.appendingPathComponent("preview.bmp"),
        folder.appendingPathComponent("capture.dng"),
    ]
    for (offset, url) in files.enumerated() {
        try Data(repeating: UInt8(offset + 1), count: offset + 3).write(to: url)
    }

    let index = EmbeddingIndex(folderURL: folder)
    for url in files {
        await index.upsert(try indexedFixture(for: url, under: folder))
    }
    try await index.save()

    let current = try await SearchIndexInspector.inspect(folderURL: folder)
    try require(
        current == .current(indexedCount: files.count, skippedCount: 0),
        "fresh JPEG/BMP/RAW index should be current, got \(current)"
    )

    // Size changes make this deterministic even on filesystems with coarse
    // modification timestamps.
    try Data(repeating: 9, count: 17).write(to: files[0], options: .atomic)
    let stale = try await SearchIndexInspector.inspect(folderURL: folder)
    try require(
        stale == .stale(
            indexedCount: files.count,
            skippedCount: 0,
            discoveredCount: files.count
        ),
        "modified photo should make the index stale, got \(stale)"
    )

    await index.upsert(try indexedFixture(for: files[0], under: folder))
    try await index.save()
    let refreshed = try await SearchIndexInspector.inspect(folderURL: folder)
    try require(
        refreshed == .current(indexedCount: files.count, skippedCount: 0),
        "refreshed index should return to current, got \(refreshed)"
    )

    // A decoder failure recorded by a completed indexing pass is known, not
    // stale. It stays out of similarity results while avoiding an endless
    // Refresh loop that can never make the corrupt file decodable.
    let rawFixture = try indexedFixture(for: files[2], under: folder)
    let readableEntries = await index.allEntries.filter {
        $0.relativePath != rawFixture.relativePath
    }
    try await index.replaceAllAndSave(
        readableEntries,
        skipped: [SkippedIndexedPhoto(
            relativePath: rawFixture.relativePath,
            fileSize: rawFixture.fileSize,
            modifiedAt: rawFixture.modifiedAt
        )]
    )
    let currentWithSkip = try await SearchIndexInspector.inspect(folderURL: folder)
    try require(
        currentWithSkip == .current(indexedCount: files.count - 1, skippedCount: 1),
        "a known unreadable file should be current-but-skipped, got \(currentWithSkip)"
    )
}

/// Search discovery must use the same root mapping as the browser. Otherwise
/// `/tmp` indexes can persist absolute `/private/tmp/...` keys, and directory
/// symlink roots can look empty even while the grid contains photos.
public func searchIndexInspectorHandlesAliasesAndSymlinkRoots() async throws {
    let fileManager = FileManager.default
    let suffix = UUID().uuidString
    let target = URL(
        fileURLWithPath: "/tmp/pv-search-root-\(suffix)",
        isDirectory: true
    )
    let privateTarget = URL(
        fileURLWithPath: "/private" + target.path,
        isDirectory: true
    )
    let link = URL(
        fileURLWithPath: "/tmp/pv-search-link-\(suffix)",
        isDirectory: true
    )
    let roots = [target, privateTarget, link]
    defer {
        try? fileManager.removeItem(at: link)
        try? fileManager.removeItem(at: target)
        for root in roots {
            if let indexURL = try? EmbeddingIndex.indexFileURL(for: root) {
                try? fileManager.removeItem(at: indexURL)
            }
        }
    }

    let nested = target.appendingPathComponent("nested", isDirectory: true)
    try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
    let direct = target.appendingPathComponent("direct.jpg")
    let deep = nested.appendingPathComponent("deep.png")
    try Data([1, 2, 3]).write(to: direct)
    try Data([4, 5, 6, 7]).write(to: deep)
    try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

    let entries = [
        try indexedFixture(for: direct, under: target),
        try indexedFixture(for: deep, under: target),
    ]
    for root in roots {
        let index = EmbeddingIndex(folderURL: root)
        try await index.replaceAllAndSave(entries)
        let status = try await SearchIndexInspector.inspect(folderURL: root)
        try require(
            status == .current(indexedCount: 2, skippedCount: 0),
            "search index under \(root.path) did not match portable discovered paths: \(status)"
        )
    }
}

/// A cancelled transactional replacement must leave both the actor snapshot
/// and its persisted JSON on the last complete generation.
public func cancelledSearchIndexReplacementPreservesPreviousSnapshot() async throws {
    let fileManager = FileManager.default
    let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("pv-search-cancel-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        try? fileManager.removeItem(at: folder)
        if let indexURL = try? EmbeddingIndex.indexFileURL(for: folder) {
            try? fileManager.removeItem(at: indexURL)
        }
    }

    let original = IndexedPhoto(
        relativePath: "original.jpg",
        embedding: clipVector(axis: 0),
        fileSize: 3,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000.125)
    )
    let replacement = IndexedPhoto(
        relativePath: "replacement.jpg",
        embedding: clipVector(axis: 1),
        fileSize: 4,
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_100.875)
    )
    let index = EmbeddingIndex(folderURL: folder)
    await index.upsert(original)
    try await index.save()

    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await index.replaceAllAndSave([replacement])
    }
    do {
        try await cancelled.value
        throw VerifyError(message: "cancelled index replacement unexpectedly succeeded")
    } catch is CancellationError {
        // Expected.
    }

    let reloaded = EmbeddingIndex(folderURL: folder)
    try await reloaded.load()
    let persistedOriginal = await reloaded.entry(forRelativePath: original.relativePath)
    let persistedReplacement = await reloaded.entry(forRelativePath: replacement.relativePath)
    try require(
        persistedOriginal != nil,
        "cancelled replacement removed the previous complete index entry"
    )
    try require(
        persistedReplacement == nil,
        "cancelled replacement persisted its staged entry"
    )
}

private func indexedFixture(for url: URL, under folder: URL) throws -> IndexedPhoto {
    // Recreate the URL so a fixture taken after an atomic replacement does
    // not reuse Foundation's cached resource values from the old inode.
    let freshURL = URL(fileURLWithPath: url.path)
    let values = try freshURL.resourceValues(forKeys: [
        .fileSizeKey,
        .contentModificationDateKey,
    ])
    let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
    let relativePath = freshURL.path.hasPrefix(prefix)
        ? String(freshURL.path.dropFirst(prefix.count))
        : freshURL.lastPathComponent
    return IndexedPhoto(
        relativePath: relativePath,
        embedding: clipVector(axis: 0),
        fileSize: values.fileSize ?? 0,
        modifiedAt: values.contentModificationDate ?? .distantPast
    )
}

private func clipVector(axis: Int) -> EmbeddingVector {
    var values = Array(repeating: Float.zero, count: EmbeddingVector.clipDimension)
    values[axis] = 1
    return EmbeddingVector(values)
}
