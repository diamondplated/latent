import Foundation
import PhotoViewerCore

// Verifications for the vim-style keymap dispatcher. Each function is
// self-contained — builds its own VimKeymap, exercises one behavior, asserts
// via the shared `require(_:_:)` / `VerifyError` helpers from main.swift.
//
// VimKeymap is `@MainActor`, so each verification is also `@MainActor`. They
// remain assignable to the `() async throws -> Void` signature consumed by
// `runVerification` because actor-isolated async closures can be awaited
// from any context.

@MainActor
public func vimJourneyNextFromZero() async throws {
    let keymap = VimKeymap()
    let folder = URL(fileURLWithPath: "/tmp/photos")
    let urls = (0..<5).map { folder.appendingPathComponent("p\($0).jpg") }

    let action = keymap.handle(
        keyCharacter: "j",
        modifiers: [],
        currentURL: urls[0],
        currentIndex: 0,
        totalCount: urls.count
    )
    try require(action == .next, "expected .next from j at index 0, got \(action)")
    try require(keymap.pendingPrefix.isEmpty, "j should not leave a pending prefix; got \(keymap.pendingPrefix)")
}

@MainActor
public func vimGGTwoChord() async throws {
    let keymap = VimKeymap()
    let folder = URL(fileURLWithPath: "/tmp/photos")
    let url = folder.appendingPathComponent("p0.jpg")

    let first = keymap.handle(
        keyCharacter: "g",
        modifiers: [],
        currentURL: url,
        currentIndex: 0,
        totalCount: 5
    )
    try require(first == .none, "first g should return .none (chord pending), got \(first)")
    try require(keymap.pendingPrefix == "g", "first g should set pendingPrefix=g, got \(keymap.pendingPrefix)")

    let second = keymap.handle(
        keyCharacter: "g",
        modifiers: [],
        currentURL: url,
        currentIndex: 0,
        totalCount: 5
    )
    try require(second == .first, "second g should return .first, got \(second)")
    try require(keymap.pendingPrefix.isEmpty, "second g should clear pendingPrefix, got \(keymap.pendingPrefix)")
}

@MainActor
public func vimMarkRoundtrip() async throws {
    let keymap = VimKeymap()
    let folder = URL(fileURLWithPath: "/tmp/photos")
    let url = folder.appendingPathComponent("p3.jpg")

    // Set: m, then a
    let m = keymap.handle(
        keyCharacter: "m",
        modifiers: [],
        currentURL: url,
        currentIndex: 3,
        totalCount: 5
    )
    try require(m == .none, "m alone should return .none, got \(m)")
    try require(keymap.pendingPrefix == "m", "m should set pendingPrefix=m, got \(keymap.pendingPrefix)")

    let a = keymap.handle(
        keyCharacter: "a",
        modifiers: [],
        currentURL: url,
        currentIndex: 3,
        totalCount: 5
    )
    try require(a == .setMark("a"), "expected .setMark(a), got \(a)")
    try require(keymap.marks[Character("a")] == url, "mark a should map to current URL, got \(String(describing: keymap.marks[Character("a")]))")

    // Jump: ', then a
    let quote = keymap.handle(
        keyCharacter: "'",
        modifiers: [],
        currentURL: url,
        currentIndex: 3,
        totalCount: 5
    )
    try require(quote == .none, "' alone should return .none, got \(quote)")
    try require(keymap.pendingPrefix == "'", "' should set pendingPrefix=', got \(keymap.pendingPrefix)")

    let jump = keymap.handle(
        keyCharacter: "a",
        modifiers: [],
        currentURL: url,
        currentIndex: 3,
        totalCount: 5
    )
    try require(jump == .jumpToMark("a"), "expected .jumpToMark(a), got \(jump)")
}

@MainActor
public func vimDigitSetsColorLabel() async throws {
    let keymap = VimKeymap()
    let folder = URL(fileURLWithPath: "/tmp/photos")
    let url = folder.appendingPathComponent("p2.jpg")

    let action = keymap.handle(
        keyCharacter: "5",
        modifiers: [],
        currentURL: url,
        currentIndex: 2,
        totalCount: 5
    )
    try require(action == .setColorLabel(5), "expected .setColorLabel(5), got \(action)")
    try require(keymap.colorLabel(for: url) == 5, "expected stored label 5, got \(keymap.colorLabel(for: url))")

    // 0 clears.
    let clear = keymap.handle(
        keyCharacter: "0",
        modifiers: [],
        currentURL: url,
        currentIndex: 2,
        totalCount: 5
    )
    try require(clear == .setColorLabel(0), "expected .setColorLabel(0), got \(clear)")
    try require(keymap.colorLabel(for: url) == 0, "0 should clear label, got \(keymap.colorLabel(for: url))")
}

@MainActor
public func vimShiftPTogglesPick() async throws {
    let keymap = VimKeymap()
    let folder = URL(fileURLWithPath: "/tmp/photos")
    let url = folder.appendingPathComponent("p1.jpg")

    let action = keymap.handle(
        keyCharacter: "P",
        modifiers: [.shift],
        currentURL: url,
        currentIndex: 1,
        totalCount: 5
    )
    try require(action == .togglePick, "expected .togglePick, got \(action)")
    try require(keymap.isPicked(url), "P should mark url as picked")

    // Toggling again unpicks.
    let again = keymap.handle(
        keyCharacter: "P",
        modifiers: [.shift],
        currentURL: url,
        currentIndex: 1,
        totalCount: 5
    )
    try require(again == .togglePick, "second P should still return .togglePick, got \(again)")
    try require(!keymap.isPicked(url), "second P should unpick url")
}

@MainActor
public func vimSaveLoadRoundtrip() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: folder)
        if let stateFile = try? VimKeymap.stateFileURL(for: folder) {
            try? FileManager.default.removeItem(at: stateFile)
        }
    }

    let urlA = folder.appendingPathComponent("a.jpg")
    let urlB = folder.appendingPathComponent("sub/b.jpg")
    let urlC = folder.appendingPathComponent("c.jpg")

    let keymap = VimKeymap()
    // Mark a -> urlA via m+a chord
    _ = keymap.handle(keyCharacter: "m", modifiers: [], currentURL: urlA, currentIndex: 0, totalCount: 3)
    _ = keymap.handle(keyCharacter: "a", modifiers: [], currentURL: urlA, currentIndex: 0, totalCount: 3)
    // Color label 3 on urlB
    _ = keymap.handle(keyCharacter: "3", modifiers: [], currentURL: urlB, currentIndex: 1, totalCount: 3)
    // Pick urlA, reject urlC
    _ = keymap.handle(keyCharacter: "P", modifiers: [.shift], currentURL: urlA, currentIndex: 0, totalCount: 3)
    _ = keymap.handle(keyCharacter: "X", modifiers: [.shift], currentURL: urlC, currentIndex: 2, totalCount: 3)

    try keymap.save(folder: folder)

    let reloaded = try VimKeymap.load(folder: folder)
    try require(reloaded.marks[Character("a")] == urlA,
                "mark a lost in roundtrip: got \(String(describing: reloaded.marks[Character("a")]))")
    try require(reloaded.colorLabel(for: urlB) == 3,
                "color label on urlB lost: got \(reloaded.colorLabel(for: urlB))")
    try require(reloaded.isPicked(urlA), "pick on urlA lost in roundtrip")
    try require(!reloaded.isPicked(urlB), "urlB should not be picked")
    try require(reloaded.isRejected(urlC), "reject on urlC lost in roundtrip")
    try require(!reloaded.isRejected(urlA), "urlA should not be rejected")
}
