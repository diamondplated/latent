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
        defer { try? FileManager.default.removeItem(at: folder) }

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

        // Cleanup state file
        let stateURL = try VimKeymap.stateFileURL(for: folder)
        try? FileManager.default.removeItem(at: stateURL)
    }

    func testLoadNonexistentReturnsEmpty() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nonexistent-\(UUID().uuidString)")
        let loaded = try VimKeymap.load(folder: folder)
        XCTAssertTrue(loaded.marks.isEmpty)
        XCTAssertTrue(loaded.picks.isEmpty)
        XCTAssertTrue(loaded.colorLabels.isEmpty)
    }

    func testFutureVersionThrows() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vim-version-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

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

        try? FileManager.default.removeItem(at: url)
    }
}
