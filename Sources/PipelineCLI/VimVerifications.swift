import Foundation
import CryptoKit
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

/// A folder whose state file cannot be read must install an *empty* keymap,
/// never keep the previous folder's. `AppState.loadFolder` owns that boundary;
/// keeping the old keymap would let the next pick re-save the previous
/// folder's state into the newly opened folder.
@MainActor
public func vimLoadFailureYieldsAnEmptyKeymap() async throws {
    let previous = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_prev_\(UUID().uuidString)")
    let corrupt = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_future_\(UUID().uuidString)")
    for folder in [previous, corrupt] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    _ = try [previous, corrupt].map(VimKeymap.stateFileURL(for:))
    defer {
        for folder in [previous, corrupt] {
            try? VimKeymap.removePersistedState(for: folder)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // The folder the user is leaving, with real cull state on it.
    let previousPhoto = previous.appendingPathComponent("kept.jpg")
    var keymap = VimKeymap()
    _ = keymap.handle(keyCharacter: "P", modifiers: [.shift], currentURL: previousPhoto, currentIndex: 0, totalCount: 1)
    _ = keymap.handle(keyCharacter: "4", modifiers: [], currentURL: previousPhoto, currentIndex: 0, totalCount: 1)
    try require(keymap.isPicked(previousPhoto), "fixture should start with a pick")

    // Both ways the load can fail: a future schema version, and bytes that are
    // not JSON at all.
    let future = """
    {"version": 999, "folderPath": "\(corrupt.path)", "updatedAt": "2030-01-01T00:00:00Z",
     "marks": {}, "colorLabels": {}, "picks": [], "rejects": []}
    """
    for bytes in [Data(future.utf8), Data("not json".utf8)] {
        try bytes.write(to: try VimKeymap.stateFileURL(for: corrupt), options: .atomic)
        var threw = false
        do { _ = try VimKeymap.load(folder: corrupt) } catch { threw = true }
        try require(threw, "load must throw on an unreadable state file")

        keymap = (try? VimKeymap.load(folder: corrupt)) ?? VimKeymap()
        try require(!keymap.isPicked(previousPhoto), "the previous folder's pick survived a failed load")
        try require(keymap.picks.isEmpty && keymap.rejects.isEmpty && keymap.colorLabels.isEmpty && keymap.marks.isEmpty,
                    "a failed load must install an empty keymap, got \(keymap.picks.count) picks / \(keymap.colorLabels.count) labels")
    }
}

@MainActor
public func vimSaveLoadRoundtrip() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        try? VimKeymap.removePersistedState(for: folder)
        try? FileManager.default.removeItem(at: folder)
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

/// The state lookup key follows an existing directory through a real
/// same-volume rename, and relative photo paths rehydrate under its new URL.
@MainActor
public func vimStateSurvivesFolderRename() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_rename_\(UUID().uuidString)")
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

    let stateFile = try VimKeymap.stateFileURL(for: originalFolder)

    try FileManager.default.moveItem(at: originalFolder, to: renamedFolder)
    let renamedStateFile = try VimKeymap.stateFileURL(for: renamedFolder)
    try require(
        renamedStateFile == stateFile,
        "folder rename changed state identity from \(stateFile.lastPathComponent) to \(renamedStateFile.lastPathComponent)"
    )

    let renamedPicked = renamedFolder.appendingPathComponent("picked.jpg")
    let renamedRejected = renamedFolder.appendingPathComponent("rejected.jpg")
    let loaded = try VimKeymap.load(folder: renamedFolder)
    try require(loaded.marks["a"] == renamedPicked, "mark did not follow renamed folder")
    try require(loaded.colorLabel(for: renamedPicked) == 4, "label did not follow renamed folder")
    try require(loaded.isPicked(renamedPicked), "pick did not follow renamed folder")
    try require(loaded.isRejected(renamedRejected), "reject did not follow renamed folder")
}

/// A stale bookmark is never allowed to attach an old shoot's culls to a new
/// directory that happens to be created later at the same pathname.
@MainActor
public func vimStateDoesNotLeakToReplacementFolder() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_replacement_\(UUID().uuidString)")
    let folder = parent.appendingPathComponent("Photos")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let oldPhoto = folder.appendingPathComponent("old.jpg")
    let keymap = VimKeymap()
    keymap.picks.insert(oldPhoto)
    try keymap.save(folder: folder)

    try FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let loadedReplacement = try VimKeymap.load(folder: folder)
    try require(
        loadedReplacement.picks.isEmpty
            && loadedReplacement.rejects.isEmpty
            && loadedReplacement.colorLabels.isEmpty
            && loadedReplacement.marks.isEmpty,
        "stale bookmark leaked the deleted folder's culling state into its replacement"
    )
}

/// The pre-bookmark path-keyed compatibility file is also isolated from a
/// later directory created at the same pathname. Its own mtime is the precise
/// boundary, so even a rapid delete/recreate cannot import the old culls.
@MainActor
public func vimLegacyStateDoesNotLeakToReplacementFolder() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_legacy_replacement_\(UUID().uuidString)")
    let folder = parent.appendingPathComponent("Photos")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    // `stateFileURL` gives us the isolated verifier's state directory; the
    // compatibility name itself is the original path hash.
    let stateDirectory = try VimKeymap.stateFileURL(for: folder)
        .deletingLastPathComponent()
    let legacyDigest = SHA256.hash(data: Data(folder.path.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let legacyFile = stateDirectory.appendingPathComponent("\(legacyDigest).json")
    let savedAt = ISO8601DateFormatter().string(from: Date())
    let legacyJSON = """
    {"version":1,"folderPath":"\(folder.path)","updatedAt":"\(savedAt)","marks":{},"colorLabels":{},"picks":["old.jpg"],"rejects":[]}
    """
    try Data(legacyJSON.utf8).write(to: legacyFile, options: .atomic)

    try FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    let replacement = try VimKeymap.load(folder: folder)
    try require(
        replacement.picks.isEmpty
            && replacement.rejects.isEmpty
            && replacement.colorLabels.isEmpty
            && replacement.marks.isEmpty,
        "legacy path state leaked into a replacement directory"
    )
    try require(
        FileManager.default.fileExists(atPath: legacyFile.path),
        "a rejected legacy snapshot should remain available to its original folder"
    )

    let newPick = folder.appendingPathComponent("new.jpg")
    replacement.picks.insert(newPick)
    try replacement.save(folder: folder)
    let reloadedReplacement = try VimKeymap.load(folder: folder)
    try require(reloadedReplacement.isPicked(newPick), "replacement culls did not reload")
    try require(
        !reloadedReplacement.isPicked(folder.appendingPathComponent("old.jpg")),
        "the ignored legacy snapshot hid or contaminated replacement culls"
    )
}

/// Creation time alone is insufficient: an unrelated older directory can be
/// renamed into the legacy pathname after the snapshot. Directory ctime makes
/// that move visible and must prevent the old state from being imported.
@MainActor
public func vimLegacyStateDoesNotLeakToMovedInFolder() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_legacy_movein_\(UUID().uuidString)")
    let folder = parent.appendingPathComponent("Photos")
    let unrelated = parent.appendingPathComponent("Unrelated")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    let stateDirectory = try VimKeymap.stateFileURL(for: folder)
        .deletingLastPathComponent()
    let legacyDigest = SHA256.hash(data: Data(folder.path.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let legacyFile = stateDirectory.appendingPathComponent("\(legacyDigest).json")
    let savedAt = ISO8601DateFormatter().string(from: Date())
    let legacyJSON = """
    {"version":1,"folderPath":"\(folder.path)","updatedAt":"\(savedAt)","marks":{},"colorLabels":{},"picks":["old.jpg"],"rejects":[]}
    """
    try Data(legacyJSON.utf8).write(to: legacyFile, options: .atomic)

    try FileManager.default.removeItem(at: folder)
    try FileManager.default.moveItem(at: unrelated, to: folder)

    var refusedAmbiguousMigration = false
    do {
        _ = try VimKeymap.load(folder: folder)
    } catch VimKeymapError.folderContinuityUnverifiable {
        refusedAmbiguousMigration = true
    }
    try require(refusedAmbiguousMigration, "an unrelated moved-in folder was not refused")
    try require(
        FileManager.default.fileExists(atPath: legacyFile.path),
        "a rejected moved-in legacy snapshot should remain untouched"
    )

    let explicitlyImported = try VimKeymap.load(
        folder: folder,
        allowUnverifiedMigration: true
    )
    try require(
        explicitlyImported.isPicked(folder.appendingPathComponent("old.jpg")),
        "explicit confirmation did not import ambiguous legacy state"
    )
}

/// A bookmark that still names this pathname but cannot be resolved and has
/// no creation-date proof is ambiguous. An opaque resource id alone is not a
/// durable identity. Loading and saving must refuse it instead of creating a
/// second reference that hides the original state.
@MainActor
public func vimUnverifiableBookmarkDoesNotForkState() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_unverifiable_reference_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let keymap = VimKeymap()
    keymap.picks.insert(folder.appendingPathComponent("kept.jpg"))
    try keymap.save(folder: folder)
    let stateFile = try VimKeymap.stateFileURL(for: folder)
    let validStateData = try Data(contentsOf: stateFile)
    let registryURL = stateFile.deletingLastPathComponent()
        .appendingPathComponent("folder-references.json")

    guard var registry = try JSONSerialization.jsonObject(
        with: Data(contentsOf: registryURL)
    ) as? [String: Any],
          var references = registry["references"] as? [Any] else {
        throw VerifyError(message: "bookmark registry was not a JSON object with references")
    }
    let referenceCount = references.count
    guard let index = references.firstIndex(where: { value in
        (value as? [String: Any])?["lastKnownPath"] as? String == folder.path
    }), var reference = references[index] as? [String: Any] else {
        throw VerifyError(message: "saved folder reference was not present")
    }
    reference["bookmarkData"] = Data("not-a-bookmark".utf8).base64EncodedString()
    reference.removeValue(forKey: "creationDate")
    references[index] = reference
    registry["references"] = references
    try JSONSerialization.data(withJSONObject: registry, options: [.prettyPrinted, .sortedKeys])
        .write(to: registryURL, options: .atomic)
    let unverifiedRegistryData = try Data(contentsOf: registryURL)

    var loadWasRefused = false
    do {
        _ = try VimKeymap.load(folder: folder)
    } catch VimKeymapError.folderContinuityUnverifiable {
        loadWasRefused = true
    }
    try require(loadWasRefused, "load treated an unverifiable bookmark as missing")

    // Confirmation authorizes a specific ambiguous association; it must not
    // mutate that association until the candidate bytes themselves validate.
    try Data("not-json".utf8).write(to: stateFile, options: .atomic)
    var corruptStateWasRefused = false
    do {
        _ = try VimKeymap.load(folder: folder, allowUnverifiedMigration: true)
    } catch {
        corruptStateWasRefused = true
    }
    try require(corruptStateWasRefused, "confirmation accepted corrupt bookmark state")
    let registryAfterCorruptState = try Data(contentsOf: registryURL)
    try require(
        registryAfterCorruptState == unverifiedRegistryData,
        "corrupt confirmed state changed the folder-reference registry"
    )

    guard var futureObject = try JSONSerialization.jsonObject(
        with: validStateData
    ) as? [String: Any] else {
        throw VerifyError(message: "saved bookmark state was not a JSON object")
    }
    futureObject["version"] = VimKeymap.supportedVersion + 1
    try JSONSerialization.data(withJSONObject: futureObject, options: [.sortedKeys])
        .write(to: stateFile, options: .atomic)
    var futureStateWasRefused = false
    do {
        _ = try VimKeymap.load(folder: folder, allowUnverifiedMigration: true)
    } catch VimKeymapError.unsupportedVersion {
        futureStateWasRefused = true
    }
    try require(futureStateWasRefused, "confirmation accepted future-version bookmark state")
    let registryAfterFutureState = try Data(contentsOf: registryURL)
    try require(
        registryAfterFutureState == unverifiedRegistryData,
        "future-version confirmed state changed the folder-reference registry"
    )

    guard var mismatchedObject = try JSONSerialization.jsonObject(
        with: validStateData
    ) as? [String: Any] else {
        throw VerifyError(message: "saved bookmark state was not a JSON object")
    }
    mismatchedObject["folderCreationTimestamp"] = 0
    try JSONSerialization.data(withJSONObject: mismatchedObject, options: [.sortedKeys])
        .write(to: stateFile, options: .atomic)
    var mismatchedStateWasRefused = false
    do {
        _ = try VimKeymap.load(folder: folder, allowUnverifiedMigration: true)
    } catch VimKeymapError.folderContinuityMismatch {
        mismatchedStateWasRefused = true
    }
    try require(
        mismatchedStateWasRefused,
        "confirmation overrode a conclusive bookmark payload mismatch"
    )
    let registryAfterMismatchedState = try Data(contentsOf: registryURL)
    try require(
        registryAfterMismatchedState == unverifiedRegistryData,
        "mismatched confirmed state changed the folder-reference registry"
    )
    try validStateData.write(to: stateFile, options: .atomic)

    let replacementKeymap = VimKeymap()
    replacementKeymap.picks.insert(folder.appendingPathComponent("replacement.jpg"))
    var saveWasRefused = false
    do {
        try replacementKeymap.save(folder: folder)
    } catch VimKeymapError.folderContinuityUnverifiable {
        saveWasRefused = true
    }
    try require(saveWasRefused, "save forked an unverifiable bookmark reference")
    guard let finalRegistry = try JSONSerialization.jsonObject(
        with: Data(contentsOf: registryURL)
    ) as? [String: Any],
          let finalReferences = finalRegistry["references"] as? [Any] else {
        throw VerifyError(message: "bookmark registry became unreadable")
    }
    try require(
        finalReferences.count == referenceCount,
        "unverifiable reference forked from \(referenceCount) records to \(finalReferences.count)"
    )

    let explicitlyImported = try VimKeymap.load(
        folder: folder,
        allowUnverifiedMigration: true
    )
    try require(
        explicitlyImported.isPicked(folder.appendingPathComponent("kept.jpg")),
        "explicit confirmation did not recover the unverifiable bookmark state"
    )
    guard let confirmedRegistry = try JSONSerialization.jsonObject(
        with: Data(contentsOf: registryURL)
    ) as? [String: Any],
          let confirmedReferences = confirmedRegistry["references"] as? [Any] else {
        throw VerifyError(message: "bookmark registry became unreadable after confirmation")
    }
    try require(
        confirmedReferences.count == referenceCount,
        "explicit confirmation forked the bookmark reference"
    )
}

/// A path-keyed v0.2 snapshot may have been written through a symlink. If the
/// symlink is later retargeted, importing automatically would attach the old
/// culls to a different folder; only an explicit user confirmation may do so.
@MainActor
public func vimLegacySymlinkRetargetRequiresConfirmation() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_legacy_symlink_\(UUID().uuidString)")
    let originalTarget = parent.appendingPathComponent("Original")
    let replacementTarget = parent.appendingPathComponent("Replacement")
    let link = parent.appendingPathComponent("Photos")
    try FileManager.default.createDirectory(at: originalTarget, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: replacementTarget, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: originalTarget)
    defer {
        try? VimKeymap.removePersistedState(for: link)
        try? VimKeymap.removePersistedState(for: originalTarget)
        try? FileManager.default.removeItem(at: parent)
    }

    let stateDirectory = try VimKeymap.stateFileURL(for: link)
        .deletingLastPathComponent()
    let legacyDigest = SHA256.hash(data: Data(link.path.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let legacyFile = stateDirectory.appendingPathComponent("\(legacyDigest).json")
    let savedAt = ISO8601DateFormatter().string(from: Date())
    let legacyJSON = """
    {"version":1,"folderPath":"\(link.path)","updatedAt":"\(savedAt)","marks":{},"colorLabels":{},"picks":["old.jpg"],"rejects":[]}
    """
    try Data(legacyJSON.utf8).write(to: legacyFile, options: .atomic)
    try await Task.sleep(nanoseconds: 20_000_000)

    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacementTarget)

    var refusedRetarget = false
    do {
        _ = try VimKeymap.load(folder: link)
    } catch VimKeymapError.folderContinuityUnverifiable {
        refusedRetarget = true
    }
    try require(refusedRetarget, "a retargeted legacy symlink was imported automatically")
    try require(
        FileManager.default.fileExists(atPath: legacyFile.path),
        "a refused symlink snapshot should remain untouched"
    )

    let explicitlyImported = try VimKeymap.load(
        folder: link,
        allowUnverifiedMigration: true
    )
    try require(
        explicitlyImported.isPicked(link.appendingPathComponent("old.jpg")),
        "explicit confirmation did not import the retargeted symlink state"
    )
}

/// The same protection must cover symlinks above the selected directory. The
/// final `Photos` entry is an ordinary pre-existing directory in both trees,
/// so checking only that final entry would silently attach A's state to B.
@MainActor
public func vimLegacyAncestorSymlinkRetargetRequiresConfirmation() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_legacy_ancestor_symlink_\(UUID().uuidString)")
    let originalRoot = parent.appendingPathComponent("Original")
    let replacementRoot = parent.appendingPathComponent("Replacement")
    let originalFolder = originalRoot.appendingPathComponent("Photos")
    let replacementFolder = replacementRoot.appendingPathComponent("Photos")
    let ancestorLink = parent.appendingPathComponent("Current")
    let openedFolder = ancestorLink.appendingPathComponent("Photos")
    try FileManager.default.createDirectory(at: originalFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: replacementFolder, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: originalRoot)
    defer {
        try? VimKeymap.removePersistedState(for: openedFolder)
        try? VimKeymap.removePersistedState(for: originalFolder)
        try? FileManager.default.removeItem(at: parent)
    }

    let stateDirectory = try VimKeymap.stateFileURL(for: openedFolder)
        .deletingLastPathComponent()
    let legacyDigest = SHA256.hash(data: Data(openedFolder.path.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let legacyFile = stateDirectory.appendingPathComponent("\(legacyDigest).json")
    let savedAt = ISO8601DateFormatter().string(from: Date())
    let legacyJSON = """
    {"version":1,"folderPath":"\(openedFolder.path)","updatedAt":"\(savedAt)","marks":{},"colorLabels":{},"picks":["old.jpg"],"rejects":[]}
    """
    try Data(legacyJSON.utf8).write(to: legacyFile, options: .atomic)
    try await Task.sleep(nanoseconds: 20_000_000)

    try FileManager.default.removeItem(at: ancestorLink)
    try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: replacementRoot)

    var refusedRetarget = false
    do {
        _ = try VimKeymap.load(folder: openedFolder)
    } catch VimKeymapError.folderContinuityUnverifiable {
        refusedRetarget = true
    }
    try require(refusedRetarget, "a retargeted ancestor symlink was imported automatically")
    try require(
        FileManager.default.fileExists(atPath: legacyFile.path),
        "a refused ancestor-symlink snapshot should remain untouched"
    )

    let explicitlyImported = try VimKeymap.load(
        folder: openedFolder,
        allowUnverifiedMigration: true
    )
    try require(
        explicitlyImported.isPicked(openedFolder.appendingPathComponent("old.jpg")),
        "explicit confirmation did not import ancestor-symlink state"
    )
}

/// Version-2 resource-identity files are stronger than path-only v1 files: an
/// exact live identity proves a same-volume rename is still the same folder,
/// even though the rename necessarily advanced directory ctime.
@MainActor
public func vimResourceIdentityStateSurvivesRenameMigration() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_resource_rename_\(UUID().uuidString)")
    let original = parent.appendingPathComponent("Before")
    let renamed = parent.appendingPathComponent("After")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    defer {
        try? VimKeymap.removePersistedState(for: renamed)
        try? VimKeymap.removePersistedState(for: original)
        try? FileManager.default.removeItem(at: parent)
    }

    let stateDirectory = try VimKeymap.stateFileURL(for: original)
        .deletingLastPathComponent()
    guard let identity = VimKeymap.folderIdentity(for: original) else {
        throw VerifyError(message: "test folder did not expose a resource identity")
    }
    let resourceFile = stateDirectory.appendingPathComponent("folder-\(identity).json")
    let savedAt = ISO8601DateFormatter().string(from: Date())
    let resourceJSON = """
    {"version":2,"folderPath":"\(original.path)","folderIdentity":"\(identity)","updatedAt":"\(savedAt)","marks":{},"colorLabels":{},"picks":["kept.jpg"],"rejects":[]}
    """
    try Data(resourceJSON.utf8).write(to: resourceFile, options: .atomic)

    try FileManager.default.moveItem(at: original, to: renamed)
    let loaded = try VimKeymap.load(folder: renamed)
    try require(
        loaded.isPicked(renamed.appendingPathComponent("kept.jpg")),
        "resource-identity fallback did not survive a same-volume rename"
    )
    try require(
        !FileManager.default.fileExists(atPath: resourceFile.path),
        "resource-identity fallback was not retired after bookmark migration"
    )
}

/// A version-1 path-hash file is rewritten under the durable bookmark key and
/// remains discoverable after a subsequent rename.
@MainActor
public func vimLegacyPathStateMigratesToStableIdentity() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_migrate_\(UUID().uuidString)")
    let folder = parent.appendingPathComponent("Legacy")
    let renamedFolder = parent.appendingPathComponent("Renamed")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        try? VimKeymap.removePersistedState(for: renamedFolder)
        try? VimKeymap.removePersistedState(for: folder)
        try? FileManager.default.removeItem(at: parent)
    }

    let stableFile = try VimKeymap.stateFileURL(for: folder)
    let legacyDigest = SHA256.hash(data: Data(folder.path.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let legacyFile = stableFile.deletingLastPathComponent()
        .appendingPathComponent("\(legacyDigest).json")
    defer {
        try? FileManager.default.removeItem(at: legacyFile)
    }
    try require(stableFile != legacyFile, "existing folder unexpectedly fell back to its path key")

    let savedAt = ISO8601DateFormatter().string(from: Date())
    let legacyJSON = """
    {"version":1,"folderPath":"\(folder.path)","updatedAt":"\(savedAt)","marks":{"a":"picked.jpg"},"colorLabels":{"picked.jpg":6},"picks":["picked.jpg"],"rejects":["rejected.jpg"]}
    """
    try Data(legacyJSON.utf8).write(to: legacyFile, options: .atomic)

    var requiredConfirmation = false
    do {
        _ = try VimKeymap.load(folder: folder)
    } catch VimKeymapError.folderContinuityUnverifiable {
        requiredConfirmation = true
    }
    try require(requiredConfirmation, "path-only legacy state migrated without confirmation")
    try require(
        FileManager.default.fileExists(atPath: legacyFile.path),
        "legacy state changed before confirmation"
    )

    let migrated = try VimKeymap.load(folder: folder, allowUnverifiedMigration: true)
    try require(migrated.isPicked(folder.appendingPathComponent("picked.jpg")), "legacy pick was not loaded")
    try require(FileManager.default.fileExists(atPath: stableFile.path), "stable state file was not created")
    try require(!FileManager.default.fileExists(atPath: legacyFile.path), "legacy state file was not retired")
    try require(migrated.lastPersistenceError == nil, "migration reported \(String(describing: migrated.lastPersistenceError))")

    try FileManager.default.moveItem(at: folder, to: renamedFolder)
    let reloaded = try VimKeymap.load(folder: renamedFolder)
    let renamedPicked = renamedFolder.appendingPathComponent("picked.jpg")
    try require(reloaded.marks["a"] == renamedPicked, "migrated mark did not follow rename")
    try require(reloaded.colorLabel(for: renamedPicked) == 6, "migrated label did not follow rename")
    try require(reloaded.isPicked(renamedPicked), "migrated pick did not follow rename")
    try require(
        reloaded.isRejected(renamedFolder.appendingPathComponent("rejected.jpg")),
        "migrated reject did not follow rename"
    )
}

/// If a compatibility writer updates state during migration, both the durable
/// destination and old source may exist. Neither priority order nor user
/// confirmation is safe: every later load must stay blocked until reconciled.
@MainActor
public func vimConflictingStateSourcesFailClosed() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_conflicting_sources_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        try? VimKeymap.removePersistedState(for: folder)
        try? FileManager.default.removeItem(at: folder)
    }

    let durable = VimKeymap()
    durable.picks.insert(folder.appendingPathComponent("durable.jpg"))
    try durable.save(folder: folder)
    let durableFile = try VimKeymap.stateFileURL(for: folder)
    let durableData = try Data(contentsOf: durableFile)

    let legacyDigest = SHA256.hash(data: Data(folder.path.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let legacyFile = durableFile.deletingLastPathComponent()
        .appendingPathComponent("\(legacyDigest).json")
    let savedAt = ISO8601DateFormatter().string(from: Date())
    let legacyJSON = """
    {"version":1,"folderPath":"\(folder.path)","updatedAt":"\(savedAt)","marks":{},"colorLabels":{},"picks":["newer.jpg"],"rejects":[]}
    """
    try Data(legacyJSON.utf8).write(to: legacyFile, options: .atomic)

    for allowConfirmation in [false, true] {
        var conflictWasRefused = false
        do {
            _ = try VimKeymap.load(
                folder: folder,
                allowUnverifiedMigration: allowConfirmation
            )
        } catch VimKeymapError.conflictingStateSources(let sources) {
            conflictWasRefused = sources.count == 2
        }
        try require(
            conflictWasRefused,
            "conflicting state sources did not fail closed (confirmation=\(allowConfirmation))"
        )
    }
    let durableDataAfterConflict = try Data(contentsOf: durableFile)
    try require(
        durableDataAfterConflict == durableData,
        "conflict handling rewrote the durable state"
    )
    try require(
        FileManager.default.fileExists(atPath: legacyFile.path),
        "conflict handling deleted the compatibility source"
    )
}

/// An empty loaded keymap is still bound to the folder incarnation that was
/// accepted at load time. Replacing that folder before its first culling edit
/// must not create a reference for the replacement or persist stale UI state.
@MainActor
public func vimBoundKeymapRefusesReplacementOnFirstSave() async throws {
    let parent = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_bound_replacement_\(UUID().uuidString)")
    let folder = parent.appendingPathComponent("Photos")
    let unrelated = parent.appendingPathComponent("Unrelated")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    guard let stateDirectoryPath = ProcessInfo.processInfo.environment[
        "LATENT_VIM_STATE_DIRECTORY"
    ] else {
        throw VerifyError(message: "isolated Vim state directory was not configured")
    }
    let stateDirectory = URL(fileURLWithPath: stateDirectoryPath, isDirectory: true)
    let beforeFiles = Set(
        (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory.path)) ?? []
    )
    let registryURL = stateDirectory.appendingPathComponent("folder-references.json")
    let registryBefore = try? Data(contentsOf: registryURL)

    let loaded = try VimKeymap.load(folder: folder)
    try FileManager.default.removeItem(at: folder)
    try FileManager.default.moveItem(at: unrelated, to: folder)
    loaded.picks.insert(folder.appendingPathComponent("stale.jpg"))

    var saveWasRefused = false
    do {
        try loaded.save(folder: folder)
    } catch VimKeymapError.folderContinuityMismatch {
        saveWasRefused = true
    }
    try require(saveWasRefused, "a bound keymap saved into a replacement folder")
    let afterFiles = Set(
        (try? FileManager.default.contentsOfDirectory(atPath: stateDirectory.path)) ?? []
    )
    try require(afterFiles == beforeFiles, "a refused bound save created persistence files")
    let registryAfter = try? Data(contentsOf: registryURL)
    try require(
        registryAfter == registryBefore,
        "a refused bound save changed the folder-reference registry"
    )
}

/// Background persistence publishes its asynchronous write error and clears
/// that error only after a later write succeeds.
@MainActor
public func vimBackgroundSaveReportsWriteFailure() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_write_error_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let stateFile = try VimKeymap.stateFileURL(for: folder)
    defer {
        try? VimKeymap.removePersistedState(for: folder)
        try? FileManager.default.removeItem(at: folder)
    }

    // A directory occupying the exact destination cannot be replaced by the
    // writer's atomic regular-file commit.
    try FileManager.default.createDirectory(
        at: stateFile,
        withIntermediateDirectories: false
    )
    let keymap = VimKeymap()
    keymap.picks.insert(folder.appendingPathComponent("picked.jpg"))
    let failedSave = keymap.saveInBackground(folder: folder)
    await failedSave.value

    let failure = try requireValue(
        keymap.lastPersistenceError,
        "background save silently swallowed its write failure"
    )
    try require(failure.operation == .backgroundSave, "unexpected failure operation \(failure.operation)")
    try require(
        failure.fileURL?.path == stateFile.path,
        "failure destination was \(failure.fileURL?.path ?? "nil"), expected \(stateFile.path)"
    )
    try require(!failure.message.isEmpty, "failure should include the filesystem error")
    try require(keymap.hasUnpersistedChanges, "failed snapshot was incorrectly marked persisted")

    try FileManager.default.removeItem(at: stateFile)
    let successfulSave = keymap.saveInBackground(folder: folder)
    await successfulSave.value
    try require(keymap.lastPersistenceError == nil, "a successful retry did not clear the old failure")
    try require(!keymap.hasUnpersistedChanges, "successful retry did not mark the snapshot persisted")
    try require(FileManager.default.fileExists(atPath: stateFile.path), "successful retry wrote no state file")
}

/// A synchronous lifecycle flush allocated after a queued background edit is
/// the definitive snapshot regardless of which queue block reaches disk first.
@MainActor
public func vimLifecycleSaveSupersedesQueuedBackgroundSnapshot() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_write_order_\(UUID().uuidString)")
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
    try require(!loaded.isPicked(first), "queued background snapshot replaced the lifecycle flush")
    try require(loaded.isPicked(newest), "lifecycle flush did not persist its newest pick")
}

/// An older async callback cannot erase the error from a newer synchronous
/// lifecycle save. Error publication follows the same revision order as data.
@MainActor
public func vimOlderBackgroundCompletionCannotClearNewerSaveFailure() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_vim_error_order_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        try? VimKeymap.removePersistedState(for: folder)
        try? FileManager.default.removeItem(at: folder)
    }

    let keymap = VimKeymap()
    keymap.picks.insert(folder.appendingPathComponent("picked.jpg"))
    let olderWrite = keymap.saveInBackground(folder: folder)
    let stateFile = try VimKeymap.stateFileURL(for: folder)
    try FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)

    var synchronousSaveFailed = false
    do {
        try keymap.save(folder: folder)
    } catch {
        synchronousSaveFailed = true
    }
    try require(synchronousSaveFailed, "newer lifecycle save unexpectedly succeeded")
    await olderWrite.value

    try require(
        keymap.lastPersistenceError?.operation == .save,
        "older callback replaced the newer synchronous save error"
    )
    try require(keymap.hasUnpersistedChanges, "failed newest snapshot was incorrectly marked persisted")
}

private func requireValue<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw VerifyError(message: message) }
    return value
}
