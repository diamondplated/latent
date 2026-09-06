import XCTest
@testable import PhotoViewerCore

@MainActor
final class VimKeymapTests: XCTestCase {
    private let testFolder = URL(fileURLWithPath: "/tmp/vimkeymap-test-\(UUID().uuidString)")
    private let photoA = URL(fileURLWithPath: "/photos/a.jpg")
    private let photoB = URL(fileURLWithPath: "/photos/b.jpg")

    private func makeKeymap() -> VimKeymap {
        VimKeymap()
    }

    // MARK: - Single key navigation

    func testJKeyReturnsNext() {
        let km = makeKeymap()
        let action = km.handle(keyCharacter: "j", modifiers: [], currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(action, .next)
    }

    func testKKeyReturnsPrev() {
        let km = makeKeymap()
        let action = km.handle(keyCharacter: "k", modifiers: [], currentURL: photoA, currentIndex: 1, totalCount: 10)
        XCTAssertEqual(action, .prev)
    }

    func testCapitalGWithShiftReturnsLast() {
        let km = makeKeymap()
        let action = km.handle(keyCharacter: "G", modifiers: .shift, currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(action, .last)
    }

    func testCapitalGWithoutShiftReturnsNone() {
        let km = makeKeymap()
        let action = km.handle(keyCharacter: "G", modifiers: [], currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(action, .none)
    }

    // MARK: - Two-key chords

    func testGGChordReturnsFirst() {
        let km = makeKeymap()
        let first = km.handle(keyCharacter: "g", modifiers: [], currentURL: photoA, currentIndex: 5, totalCount: 10)
        XCTAssertEqual(first, .none, "first 'g' should buffer as chord prefix")
        XCTAssertEqual(km.pendingPrefix, "g")

        let second = km.handle(keyCharacter: "g", modifiers: [], currentURL: photoA, currentIndex: 5, totalCount: 10)
        XCTAssertEqual(second, .first)
        XCTAssertTrue(km.pendingPrefix.isEmpty)
    }

    func testGFollowedByNonGAborts() {
        let km = makeKeymap()
        _ = km.handle(keyCharacter: "g", modifiers: [], currentURL: photoA, currentIndex: 0, totalCount: 10)
        let result = km.handle(keyCharacter: "x", modifiers: [], currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(result, .none)
        XCTAssertTrue(km.pendingPrefix.isEmpty)
    }

    // MARK: - Marks

    func testSetMarkAndJump() {
        let km = makeKeymap()
        // m + a sets mark
        _ = km.handle(keyCharacter: "m", modifiers: [], currentURL: photoA, currentIndex: 0, totalCount: 10)
        let setResult = km.handle(keyCharacter: "a", modifiers: [], currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(setResult, .setMark("a"))
        XCTAssertEqual(km.marks["a"], photoA)

        // ' + a jumps to mark
        _ = km.handle(keyCharacter: "'", modifiers: [], currentURL: photoB, currentIndex: 1, totalCount: 10)
        let jumpResult = km.handle(keyCharacter: "a", modifiers: [], currentURL: photoB, currentIndex: 1, totalCount: 10)
        XCTAssertEqual(jumpResult, .jumpToMark("a"))
    }

    func testMarkWithNonLetterAborts() {
        let km = makeKeymap()
        _ = km.handle(keyCharacter: "m", modifiers: [], currentURL: photoA, currentIndex: 0, totalCount: 10)
        let result = km.handle(keyCharacter: "1", modifiers: [], currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(result, .none)
    }

    // MARK: - Color labels

    func testDigitSetsColorLabel() {
        let km = makeKeymap()
        let result = km.handle(keyCharacter: "3", modifiers: [], currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(result, .setColorLabel(3))
        XCTAssertEqual(km.colorLabel(for: photoA), 3)
    }

    func testDigitZeroClearsLabel() {
        let km = makeKeymap()
        _ = km.handle(keyCharacter: "5", modifiers: [], currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(km.colorLabel(for: photoA), 5)

        _ = km.handle(keyCharacter: "0", modifiers: [], currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(km.colorLabel(for: photoA), 0)
    }

    // MARK: - Pick / Reject

    func testTogglePick() {
        let km = makeKeymap()
        let result = km.handle(keyCharacter: "P", modifiers: .shift, currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(result, .togglePick)
        XCTAssertTrue(km.isPicked(photoA))

        // Second toggle removes
        let result2 = km.handle(keyCharacter: "P", modifiers: .shift, currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(result2, .togglePick)
        XCTAssertFalse(km.isPicked(photoA))
    }

    func testToggleReject() {
        let km = makeKeymap()
        let result = km.handle(keyCharacter: "X", modifiers: .shift, currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(result, .toggleReject)
        XCTAssertTrue(km.isRejected(photoA))
    }

    func testPickingClearsReject() {
        let km = makeKeymap()
        _ = km.handle(keyCharacter: "X", modifiers: .shift, currentURL: photoA, currentIndex: 0, totalCount: 10)
        _ = km.handle(keyCharacter: "P", modifiers: .shift, currentURL: photoA, currentIndex: 0, totalCount: 10)

        XCTAssertTrue(km.isPicked(photoA))
        XCTAssertFalse(km.isRejected(photoA))
    }

    func testRejectingClearsPick() {
        let km = makeKeymap()
        _ = km.handle(keyCharacter: "P", modifiers: .shift, currentURL: photoA, currentIndex: 0, totalCount: 10)
        _ = km.handle(keyCharacter: "X", modifiers: .shift, currentURL: photoA, currentIndex: 0, totalCount: 10)

        XCTAssertFalse(km.isPicked(photoA))
        XCTAssertTrue(km.isRejected(photoA))
    }

    func testPWithoutShiftIsIgnored() {
        let km = makeKeymap()
        let result = km.handle(keyCharacter: "P", modifiers: [], currentURL: photoA, currentIndex: 0, totalCount: 10)
        XCTAssertEqual(result, .none)
        XCTAssertFalse(km.isPicked(photoA))
    }

    // MARK: - Save/Load round-trip

    func testSaveLoadRoundTrip() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vim-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? VimKeymap.removePersistedState(for: folder)
            try? FileManager.default.removeItem(at: folder)
        }

        let photo1 = folder.appendingPathComponent("img1.jpg")
        let photo2 = folder.appendingPathComponent("img2.jpg")

        let original = VimKeymap()
        original.marks["a"] = photo1
        original.colorLabels[photo1] = 3
        original.picks.insert(photo1)
        original.rejects.insert(photo2)

        try original.save(folder: folder)
        let loaded = try VimKeymap.load(folder: folder)

        XCTAssertEqual(loaded.marks["a"], photo1)
        XCTAssertEqual(loaded.colorLabel(for: photo1), 3)
        XCTAssertTrue(loaded.isPicked(photo1))
        XCTAssertTrue(loaded.isRejected(photo2))
    }

    func testStateSurvivesFolderRename() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vim-rename-parent-\(UUID().uuidString)")
        let originalFolder = parent.appendingPathComponent("Before")
        let renamedFolder = parent.appendingPathComponent("After")
        try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        defer {
            try? VimKeymap.removePersistedState(for: renamedFolder)
            try? VimKeymap.removePersistedState(for: originalFolder)
            try? FileManager.default.removeItem(at: parent)
        }

        let originalPicked = originalFolder.appendingPathComponent("picked.jpg")
        let originalRejected = originalFolder.appendingPathComponent("rejected.jpg")
        let keymap = VimKeymap()
        keymap.marks["a"] = originalPicked
        keymap.colorLabels[originalPicked] = 4
        keymap.picks.insert(originalPicked)
        keymap.rejects.insert(originalRejected)
        try keymap.save(folder: originalFolder)

        let stateURLBeforeRename = try VimKeymap.stateFileURL(for: originalFolder)
        try FileManager.default.moveItem(at: originalFolder, to: renamedFolder)

        let stateURLAfterRename = try VimKeymap.stateFileURL(for: renamedFolder)
        XCTAssertEqual(stateURLAfterRename, stateURLBeforeRename)

        let renamedPicked = renamedFolder.appendingPathComponent("picked.jpg")
        let renamedRejected = renamedFolder.appendingPathComponent("rejected.jpg")
        let loaded = try VimKeymap.load(folder: renamedFolder)
        XCTAssertEqual(loaded.marks["a"], renamedPicked)
        XCTAssertEqual(loaded.colorLabel(for: renamedPicked), 4)
        XCTAssertTrue(loaded.isPicked(renamedPicked))
        XCTAssertTrue(loaded.isRejected(renamedRejected))
    }

    func testLegacyPathStateMigratesToStableIdentityBeforeRename() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vim-migration-parent-\(UUID().uuidString)")
        let folder = parent.appendingPathComponent("Legacy")
        let renamedFolder = parent.appendingPathComponent("Renamed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? VimKeymap.removePersistedState(for: renamedFolder)
            try? VimKeymap.removePersistedState(for: folder)
            try? FileManager.default.removeItem(at: parent)
        }

        let legacyURL = try VimKeymap.legacyStateFileURL(for: folder)
        let stableURL = try VimKeymap.stateFileURL(for: folder)
        defer {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        XCTAssertNotEqual(legacyURL, stableURL)

        let savedAt = ISO8601DateFormatter().string(from: Date())
        let legacyJSON = """
        {"version":1,"folderPath":"\(folder.path)","updatedAt":"\(savedAt)","marks":{"a":"picked.jpg"},"colorLabels":{"picked.jpg":6},"picks":["picked.jpg"],"rejects":["rejected.jpg"]}
        """
        try XCTUnwrap(legacyJSON.data(using: .utf8)).write(to: legacyURL, options: .atomic)

        XCTAssertThrowsError(try VimKeymap.load(folder: folder)) { error in
            guard case VimKeymapError.folderContinuityUnverifiable = error else {
                return XCTFail("Expected legacy migration confirmation, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        let migrated = try VimKeymap.load(
            folder: folder,
            allowUnverifiedMigration: true
        )
        XCTAssertTrue(migrated.isPicked(folder.appendingPathComponent("picked.jpg")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stableURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertNil(migrated.lastPersistenceError)

        let migratedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stableURL)) as? [String: Any]
        )
        XCTAssertEqual(migratedObject["version"] as? Int, VimKeymap.supportedVersion)
        XCTAssertNotNil(migratedObject["folderIdentity"] as? String)

        try FileManager.default.moveItem(at: folder, to: renamedFolder)
        let reloaded = try VimKeymap.load(folder: renamedFolder)
        let renamedPicked = renamedFolder.appendingPathComponent("picked.jpg")
        XCTAssertEqual(reloaded.marks["a"], renamedPicked)
        XCTAssertEqual(reloaded.colorLabel(for: renamedPicked), 6)
        XCTAssertTrue(reloaded.isPicked(renamedPicked))
        XCTAssertTrue(reloaded.isRejected(renamedFolder.appendingPathComponent("rejected.jpg")))
    }

    func testLegacyPathStateDoesNotLeakToReplacementFolder() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vim-legacy-replacement-\(UUID().uuidString)")
        let folder = parent.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacyURL = try VimKeymap.legacyStateFileURL(for: folder)
        defer {
            try? VimKeymap.removePersistedState(for: folder)
            try? FileManager.default.removeItem(at: legacyURL)
            try? FileManager.default.removeItem(at: parent)
        }

        let savedAt = ISO8601DateFormatter().string(from: Date())
        let legacyJSON = """
        {"version":1,"folderPath":"\(folder.path)","updatedAt":"\(savedAt)","marks":{},"colorLabels":{},"picks":["old.jpg"],"rejects":[]}
        """
        try XCTUnwrap(legacyJSON.data(using: .utf8)).write(to: legacyURL, options: .atomic)

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let replacement = try VimKeymap.load(folder: folder)
        XCTAssertTrue(replacement.marks.isEmpty)
        XCTAssertTrue(replacement.colorLabels.isEmpty)
        XCTAssertTrue(replacement.picks.isEmpty)
        XCTAssertTrue(replacement.rejects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        let newPick = folder.appendingPathComponent("new.jpg")
        replacement.picks.insert(newPick)
        try replacement.save(folder: folder)
        let reloadedReplacement = try VimKeymap.load(folder: folder)
        XCTAssertTrue(reloadedReplacement.isPicked(newPick))
        XCTAssertFalse(reloadedReplacement.isPicked(folder.appendingPathComponent("old.jpg")))
    }

    func testLegacyPathStateDoesNotLeakToUnrelatedMovedInFolder() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vim-legacy-movein-\(UUID().uuidString)")
        let folder = parent.appendingPathComponent("Photos")
        let unrelated = parent.appendingPathComponent("Unrelated")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let legacyURL = try VimKeymap.legacyStateFileURL(for: folder)
        defer {
            try? FileManager.default.removeItem(at: legacyURL)
            try? FileManager.default.removeItem(at: parent)
        }

        let savedAt = ISO8601DateFormatter().string(from: Date())
        let legacyJSON = """
        {"version":1,"folderPath":"\(folder.path)","updatedAt":"\(savedAt)","marks":{},"colorLabels":{},"picks":["old.jpg"],"rejects":[]}
        """
        try XCTUnwrap(legacyJSON.data(using: .utf8)).write(to: legacyURL, options: .atomic)

        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: unrelated, to: folder)

        XCTAssertThrowsError(try VimKeymap.load(folder: folder)) { error in
            guard case VimKeymapError.folderContinuityUnverifiable = error else {
                return XCTFail("Expected an unverifiable-continuity error, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        let explicitlyImported = try VimKeymap.load(
            folder: folder,
            allowUnverifiedMigration: true
        )
        XCTAssertTrue(explicitlyImported.isPicked(folder.appendingPathComponent("old.jpg")))
    }

    func testLoadedKeymapRefusesReplacementOnFirstSave() throws {
        let parent = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vim-bound-replacement-\(UUID().uuidString)")
        let folder = parent.appendingPathComponent("Photos")
        let unrelated = parent.appendingPathComponent("Unrelated")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer {
            try? VimKeymap.removePersistedState(for: folder)
            try? FileManager.default.removeItem(at: parent)
        }

        let loaded = try VimKeymap.load(folder: folder)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: unrelated, to: folder)
        loaded.picks.insert(folder.appendingPathComponent("stale.jpg"))

        XCTAssertThrowsError(try loaded.save(folder: folder)) { error in
            guard case VimKeymapError.folderContinuityMismatch = error else {
                return XCTFail("Expected a folder-continuity mismatch, got \(error)")
            }
        }
    }

    func testBackgroundSaveReportsAndClearsWriteFailure() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vim-write-failure-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? VimKeymap.removePersistedState(for: folder)
            try? FileManager.default.removeItem(at: root)
        }

        let stateURL = try VimKeymap.stateFileURL(for: folder)
        try FileManager.default.createDirectory(
            at: stateURL,
            withIntermediateDirectories: false
        )

        let keymap = VimKeymap()
        keymap.picks.insert(folder.appendingPathComponent("picked.jpg"))
        let failedSave = keymap.saveInBackground(folder: folder)
        await failedSave.value

        let failure = try XCTUnwrap(keymap.lastPersistenceError)
        XCTAssertEqual(failure.operation, .backgroundSave)
        XCTAssertEqual(failure.fileURL?.path, stateURL.path)
        XCTAssertFalse(failure.message.isEmpty)
        XCTAssertTrue(keymap.hasUnpersistedChanges)

        try FileManager.default.removeItem(at: stateURL)
        let successfulSave = keymap.saveInBackground(folder: folder)
        await successfulSave.value
        XCTAssertNil(keymap.lastPersistenceError)
        XCTAssertFalse(keymap.hasUnpersistedChanges)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testLoadNonexistentReturnsEmpty() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nonexistent-\(UUID().uuidString)")
        let loaded = try VimKeymap.load(folder: folder)
        XCTAssertTrue(loaded.marks.isEmpty)
        XCTAssertTrue(loaded.picks.isEmpty)
        XCTAssertTrue(loaded.colorLabels.isEmpty)
    }

    func testLoadNormalizesLegacyContradictoryFlagsAndInvalidLabels() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vim-legacy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? VimKeymap.removePersistedState(for: folder)
            try? FileManager.default.removeItem(at: folder)
        }

        let stateURL = try VimKeymap.stateFileURL(for: folder)
        let legacyJSON = """
        {"version":1,"folderPath":"\(folder.path)","updatedAt":"2026-01-01T00:00:00Z","marks":{},"colorLabels":{"both.jpg":42},"picks":["both.jpg"],"rejects":["both.jpg"]}
        """
        try XCTUnwrap(legacyJSON.data(using: .utf8)).write(to: stateURL, options: .atomic)

        let photo = folder.appendingPathComponent("both.jpg")
        let loaded = try VimKeymap.load(folder: folder)
        XCTAssertFalse(loaded.isPicked(photo))
        XCTAssertTrue(loaded.isRejected(photo))
        XCTAssertEqual(loaded.colorLabel(for: photo), 0)
    }

    func testFutureVersionThrows() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vim-version-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? VimKeymap.removePersistedState(for: folder)
            try? FileManager.default.removeItem(at: folder)
        }

        let url = try VimKeymap.stateFileURL(for: folder)
        // Write a future-version file
        let futureJSON = """
        {"version":999,"folderPath":"\(folder.path)","updatedAt":"2026-01-01T00:00:00Z","marks":{},"colorLabels":{},"picks":[],"rejects":[]}
        """
        try futureJSON.data(using: .utf8)!.write(to: url, options: .atomic)

        XCTAssertThrowsError(try VimKeymap.load(folder: folder)) { error in
            if case VimKeymapError.unsupportedVersion(let found, _) = error {
                XCTAssertEqual(found, 999)
            } else {
                XCTFail("Expected unsupportedVersion error, got \(error)")
            }
        }
    }

    func testLifecycleSaveSupersedesQueuedBackgroundSnapshot() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vim-write-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? VimKeymap.removePersistedState(for: folder)
            try? FileManager.default.removeItem(at: folder)
        }

        let first = folder.appendingPathComponent("first.jpg")
        let newest = folder.appendingPathComponent("newest.jpg")
        let keymap = VimKeymap()
        keymap.picks.insert(first)
        let olderWrite = keymap.saveInBackground(folder: folder)

        keymap.picks.remove(first)
        keymap.picks.insert(newest)
        try keymap.save(folder: folder)
        await olderWrite.value

        let loaded = try VimKeymap.load(folder: folder)
        XCTAssertFalse(loaded.isPicked(first))
        XCTAssertTrue(loaded.isPicked(newest))
    }

    func testOlderBackgroundCompletionCannotClearNewerSaveFailure() async throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vim-write-error-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? VimKeymap.removePersistedState(for: folder)
            try? FileManager.default.removeItem(at: folder)
        }

        let keymap = VimKeymap()
        keymap.picks.insert(folder.appendingPathComponent("picked.jpg"))
        let olderWrite = keymap.saveInBackground(folder: folder)
        let stateURL = try VimKeymap.stateFileURL(for: folder)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)

        XCTAssertThrowsError(try keymap.save(folder: folder))
        await olderWrite.value

        XCTAssertEqual(keymap.lastPersistenceError?.operation, .save)
        XCTAssertTrue(keymap.hasUnpersistedChanges)
    }
}
