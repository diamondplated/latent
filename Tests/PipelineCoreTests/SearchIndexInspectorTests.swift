import Foundation
import XCTest
@testable import PhotoSearch

final class SearchIndexInspectorTests: XCTestCase {
    func testDiscoveryKeepsTmpAndSymlinkRootPathsPortable() throws {
        let suffix = UUID().uuidString
        let target = URL(
            fileURLWithPath: "/tmp/latent-search-target-\(suffix)",
            isDirectory: true
        )
        let link = URL(
            fileURLWithPath: "/tmp/latent-search-link-\(suffix)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }

        let nested = target.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1]).write(to: target.appendingPathComponent("direct.jpg"))
        try Data([2]).write(to: nested.appendingPathComponent("deep.png"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let targetPaths = Set(
            try SearchEngine.discoverIndexableFiles(in: target).map(\.relativePath)
        )
        let linkPaths = Set(
            try SearchEngine.discoverIndexableFiles(in: link).map(\.relativePath)
        )
        let expected: Set<String> = ["direct.jpg", "nested/deep.png"]

        XCTAssertEqual(targetPaths, expected)
        XCTAssertEqual(linkPaths, expected)
        XCTAssertTrue(targetPaths.allSatisfy { !$0.hasPrefix("/") })
        XCTAssertTrue(linkPaths.allSatisfy { !$0.hasPrefix("/") })
    }

    func testOnlyPerImageBridgeFailuresAreSafeToSkipWhileIndexing() {
        let fixtureError = NSError(domain: "SearchIndexInspectorTests", code: 1)
        XCTAssertTrue(SearchEngine.isSkippableImageEncodingFailure(
            CLIPImageEncoderError.bridgeError(fixtureError)
        ))
        XCTAssertFalse(SearchEngine.isSkippableImageEncodingFailure(
            CLIPImageEncoderError.predictionFailed(fixtureError)
        ))
        XCTAssertFalse(SearchEngine.isSkippableImageEncodingFailure(
            CLIPImageEncoderError.unexpectedOutputShape([1, 7])
        ))
        XCTAssertFalse(SearchEngine.isSkippableImageEncodingFailure(
            CLIPImageEncoderError.modelNotAvailable
        ))
    }

    func testLegacyIndexLoadsAndFutureVersionIsRejected() async throws {
        let folder = try makeFolder(prefix: "search-version")
        defer { cleanup(folder) }
        let indexURL = try EmbeddingIndex.indexFileURL(for: folder)

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
        XCTAssertEqual(loaded?.fileSize, 42)

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
            XCTFail("future search-index format unexpectedly loaded")
        } catch let error as EmbeddingIndexError {
            XCTAssertEqual(error, .unsupportedVersion(999))
        }
    }

    func testMalformedEmbeddingCachesAreRejectedBeforeTheyReachSearch() async throws {
        let folder = try makeFolder(prefix: "search-malformed")
        defer { cleanup(folder) }
        let indexURL = try EmbeddingIndex.indexFileURL(for: folder)

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
            XCTFail("wrong-width search vector unexpectedly loaded")
        } catch let error as EmbeddingIndexError {
            XCTAssertEqual(
                error,
                .invalidEmbeddingDimension(
                    relativePath: "bad.jpg",
                    actual: EmbeddingVector.clipDimension - 1
                )
            )
        }
        let wrongDimensionCount = await wrongDimension.count
        XCTAssertEqual(wrongDimensionCount, 0)

        var nonFiniteValues: [Any] = Array(
            repeating: 0.25,
            count: EmbeddingVector.clipDimension
        )
        nonFiniteValues[17] = "NaN"
        try writeCache(values: nonFiniteValues)
        let nonFinite = EmbeddingIndex(folderURL: folder)
        do {
            try await nonFinite.load()
            XCTFail("non-finite search vector unexpectedly loaded")
        } catch let error as EmbeddingIndexError {
            XCTAssertEqual(error, .nonFiniteEmbedding(relativePath: "bad.jpg"))
        }
        let nonFiniteCount = await nonFinite.count
        XCTAssertEqual(nonFiniteCount, 0)

        // Public mutation APIs cannot make a later query abort the process,
        // even before the invalid entry is rejected by save().
        let inMemory = EmbeddingIndex(folderURL: folder)
        await inMemory.upsert(IndexedPhoto(
            relativePath: "bad.jpg",
            embedding: EmbeddingVector([1, 0, 0]),
            fileSize: 42,
            modifiedAt: .distantPast
        ))
        let results = await inMemory.topK(
            10,
            similarTo: clipVector(axis: 0)
        )
        XCTAssertTrue(results.isEmpty)
    }

    func testInspectorTracksMissingCurrentAndStaleAcrossSupportedFormats() async throws {
        let folder = try makeFolder(prefix: "search-status")
        defer { cleanup(folder) }

        let missing = try await SearchIndexInspector.inspect(folderURL: folder)
        XCTAssertEqual(missing, .missing)

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
            await index.upsert(try fixture(for: url, under: folder))
        }
        try await index.save()
        let current = try await SearchIndexInspector.inspect(folderURL: folder)
        XCTAssertEqual(current, .current(indexedCount: files.count, skippedCount: 0))

        try Data(repeating: 7, count: 19).write(to: files[0], options: .atomic)
        let stale = try await SearchIndexInspector.inspect(folderURL: folder)
        XCTAssertEqual(
            stale,
            .stale(indexedCount: files.count, skippedCount: 0, discoveredCount: files.count)
        )

        await index.upsert(try fixture(for: files[0], under: folder))
        try await index.save()
        let refreshed = try await SearchIndexInspector.inspect(folderURL: folder)
        XCTAssertEqual(refreshed, .current(indexedCount: files.count, skippedCount: 0))

        let rawFixture = try fixture(for: files[2], under: folder)
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
        XCTAssertEqual(
            currentWithSkip,
            .current(indexedCount: files.count - 1, skippedCount: 1)
        )
    }

    func testCancelledReplacementPreservesPreviousPersistedSnapshot() async throws {
        let folder = try makeFolder(prefix: "search-cancel")
        defer { cleanup(folder) }

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

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await index.replaceAllAndSave([replacement])
        }
        do {
            try await task.value
            XCTFail("cancelled replacement unexpectedly succeeded")
        } catch is CancellationError {
            // Expected.
        }

        let reloaded = EmbeddingIndex(folderURL: folder)
        try await reloaded.load()
        let persistedOriginal = await reloaded.entry(forRelativePath: original.relativePath)
        let persistedReplacement = await reloaded.entry(forRelativePath: replacement.relativePath)
        XCTAssertNotNil(persistedOriginal)
        XCTAssertNil(persistedReplacement)
    }

    private func makeFolder(prefix: String) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("latent-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func cleanup(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
        if let indexURL = try? EmbeddingIndex.indexFileURL(for: folder) {
            try? FileManager.default.removeItem(at: indexURL)
        }
    }

    private func fixture(for url: URL, under folder: URL) throws -> IndexedPhoto {
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
}
