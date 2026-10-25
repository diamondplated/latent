import Foundation
import CryptoKit
import Darwin

/// Modifier-key set for the vim dispatcher.
///
/// Defined here (not lifted from SwiftUI's `EventModifiers`) so this module
/// stays Foundation-only — `PhotoViewerCore` deliberately has no SwiftUI
/// dependency. Callers in the SwiftUI layer are expected to translate
/// `EventModifiers` -> `VimModifiers` at the integration boundary.
public struct VimModifiers: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift   = VimModifiers(rawValue: 1 << 0)
    public static let control = VimModifiers(rawValue: 1 << 1)
    public static let option  = VimModifiers(rawValue: 1 << 2)
    public static let command = VimModifiers(rawValue: 1 << 3)
}

/// Outcome of a single dispatch. The dispatcher only translates keystrokes
/// into intent; it does not move a selection cursor or mutate caller state.
/// `.none` covers both "key not handled" and "this keystroke completed a
/// chord prefix; nothing to do yet" — callers treat both identically.
public enum VimAction: Sendable, Equatable {
    case next
    case prev
    case first
    case last
    case setMark(Character)
    case jumpToMark(Character)
    /// Color label 0-9. 0 means "clear label".
    case setColorLabel(Int)
    case togglePick
    case toggleReject
    case none
}

/// Errors emitted by `VimKeymap` save/load.
public enum VimKeymapError: Error, CustomStringConvertible {
    /// On-disk file's schema version is newer than this build supports.
    case unsupportedVersion(found: Int, supported: Int)
    /// The folder-reference registry is newer than this build understands.
    /// Refusing to rewrite it prevents a downgrade from orphaning state.
    case unsupportedReferenceRegistryVersion(found: Int, supported: Int)
    /// Registry contents are malformed or unsafe to use as file names.
    case invalidReferenceRegistry(String)
    /// The registry could not be safely locked or updated.
    case referenceRegistryUnavailable(String)
    /// A state file resolved through the durable bookmark registry but its
    /// recorded directory incarnation no longer matches the live folder.
    case folderContinuityMismatch(URL)
    /// A compatibility state file exists, but this filesystem cannot provide
    /// enough continuity metadata to attach it without risking cross-folder
    /// culling leakage.
    case folderContinuityUnverifiable(URL, String)
    /// More than one state source exists for the same live folder, usually
    /// because another process changed a compatibility file mid-migration.
    /// Neither source is selected automatically or by identity confirmation.
    case conflictingStateSources([URL])

    public var description: String {
        switch self {
        case .unsupportedVersion(let found, let supported):
            return "VimKeymap state version \(found) is newer than supported (\(supported))"
        case .unsupportedReferenceRegistryVersion(let found, let supported):
            return "VimKeymap folder-reference registry version \(found) is newer than supported (\(supported))"
        case .invalidReferenceRegistry(let reason):
            return "VimKeymap folder-reference registry is invalid: \(reason)"
        case .referenceRegistryUnavailable(let reason):
            return "VimKeymap folder-reference registry is unavailable: \(reason)"
        case .folderContinuityMismatch(let fileURL):
            return "VimKeymap state at \(fileURL.path) belongs to a different incarnation of this folder"
        case .folderContinuityUnverifiable(let fileURL, let reason):
            return "VimKeymap could not safely verify state at \(fileURL.path): \(reason)"
        case .conflictingStateSources(let fileURLs):
            return "VimKeymap found conflicting state files: \(fileURLs.map(\.path).joined(separator: ", "))"
        }
    }
}

/// A persistence failure from a save that could not report an error directly
/// to its caller (most notably `saveInBackground(folder:)`). UI clients can
/// observe `VimKeymap.lastPersistenceError` and present or log the failure.
public struct VimKeymapPersistenceFailure: LocalizedError, Sendable, Equatable, CustomStringConvertible {
    public enum Operation: String, Sendable, Equatable {
        case save
        case backgroundSave
        case migration
    }

    public let operation: Operation
    public let fileURL: URL?
    public let message: String
    public let occurredAt: Date

    public var description: String {
        let destination = fileURL?.path ?? "the Vim state directory"
        return "Vim state \(operation.rawValue) failed at \(destination): \(message)"
    }

    public var errorDescription: String? { description }
}

/// Vim-style keystroke dispatcher with per-folder state persistence.
///
/// State lives in memory and serializes to
/// `~/Library/Application Support/photo-viewer/VimState/folder-reference-<id>.json`.
/// A Foundation bookmark registry reconnects that opaque id to the folder
/// after same-volume moves, renames, and process or system restarts. Older
/// resource-id and version-1 path-hash files are migrated on first load.
/// The dispatcher is a tiny state machine: `pendingPrefix` is a `String`
/// (rather than an enum) so future chords like counts (`5j`) or two-key
/// operators can extend it without re-shaping the state field. Single-quote
/// for mark-jump is handled by checking the literal character `"'"`.
@MainActor
@Observable
public final class VimKeymap {
    /// Bumped when the on-disk format changes in a way older builds can't
    /// safely round-trip. Older code refuses to load a newer file.
    public static let supportedVersion = 3
    static let supportedReferenceRegistryVersion = 1
    static let referenceRegistryFilename = "folder-references.json"
    static var nextSaveRevision: UInt64 = 0

    /// Marks (`m<x>` to set, `'<x>` to jump). Stored in memory as URLs;
    /// serialized as relative paths so the JSON is portable across moves
    /// of the parent folder.
    public var marks: [Character: URL] = [:] {
        didSet { markStateChanged() }
    }

    /// Color label 0-9 per photo URL. Absence == 0 / no label.
    public var colorLabels: [URL: Int] = [:] {
        didSet { markStateChanged() }
    }

    /// Picks and rejects are mutually exclusive. A photo can be neither, but
    /// marking it as one always clears the other so downstream filters and
    /// exports never have to resolve contradictory culling state.
    public var picks: Set<URL> = [] {
        didSet { markStateChanged() }
    }
    public var rejects: Set<URL> = [] {
        didSet { markStateChanged() }
    }

    /// Chord prefix accumulator. Empty between completed actions; non-empty
    /// after a leader key (`g`, `m`, `'`) until the second key arrives or
    /// any unrecognized key clears it.
    public var pendingPrefix: String = ""

    /// The newest persistence failure that could not be delivered by a
    /// throwing call. A successful save clears it. This makes background
    /// write failures observable instead of silently discarding them.
    public internal(set) var lastPersistenceError: VimKeymapPersistenceFailure?

    /// True only when in-memory culling differs from the newest confirmed
    /// state-file snapshot. App lifecycle code uses this to avoid creating an
    /// empty bookmark/state record for every folder that is merely browsed.
    public internal(set) var hasUnpersistedChanges = false

    var latestBackgroundSaveRevision: UInt64 = 0
    var mutationRevision: UInt64 = 0
    /// Persistence is bound to the folder incarnation accepted by `load` (or
    /// captured on the first save of a programmatically-created keymap). Saves
    /// never rediscover their destination from a mutable pathname.
    @ObservationIgnored var boundFolderTarget: FolderTargetSnapshot?
    @ObservationIgnored var boundReferenceID: String?

    public init() {}

    public func clearPersistenceError() {
        lastPersistenceError = nil
    }

    func markStateChanged() {
        mutationRevision &+= 1
        hasUnpersistedChanges = true
    }

    // MARK: - Reads

    public func colorLabel(for url: URL) -> Int {
        colorLabels[url] ?? 0
    }

    public func isPicked(_ url: URL) -> Bool {
        picks.contains(url)
    }

    public func isRejected(_ url: URL) -> Bool {
        rejects.contains(url)
    }

    // MARK: - Dispatch

    /// Translate one keystroke into a `VimAction` and update internal state
    /// (marks/labels/picks/rejects + `pendingPrefix`).
    ///
    /// Returns `.none` for unhandled keys and for the first key of a
    /// multi-key chord (e.g. the first `g` in `gg`). The dispatcher does not
    /// itself navigate; it converts keystrokes into intent. `currentURL`
    /// is required for any action that mutates state on a specific photo
    /// (label/pick/reject/setMark); `currentIndex`/`totalCount` are taken
    /// for future bounds-check needs but are not used for dispatch today.
    public func handle(
        keyCharacter: Character,
        modifiers: VimModifiers,
        currentURL: URL?,
        currentIndex: Int?,
        totalCount: Int
    ) -> VimAction {
        // 1. Resolve a pending chord first. If we are mid-chord, the second
        //    keystroke completes (or aborts) the action and we are done.
        if !pendingPrefix.isEmpty {
            let prefix = pendingPrefix
            pendingPrefix = ""

            switch prefix {
            case "g":
                if keyCharacter == "g" {
                    return .first
                }
                // Anything else after `g` aborts the chord.
                return .none

            case "m":
                if keyCharacter.isLetter {
                    if let url = currentURL {
                        marks[keyCharacter] = url
                    }
                    return .setMark(keyCharacter)
                }
                return .none

            case "'":
                if keyCharacter.isLetter {
                    return .jumpToMark(keyCharacter)
                }
                return .none

            default:
                // Unknown prefix — should not happen, but be safe.
                return .none
            }
        }

        // 2. No chord pending. Match leaders and standalone keys.
        switch keyCharacter {
        case "j":
            return .next
        case "k":
            return .prev
        case "g":
            // First half of `gg`. Wait for the second key.
            pendingPrefix = "g"
            return .none
        case "G":
            // Vim's last-line jump. Require shift to disambiguate from `g`.
            if modifiers.contains(.shift) {
                return .last
            }
            return .none
        case "m":
            pendingPrefix = "m"
            return .none
        case "'":
            pendingPrefix = "'"
            return .none
        case "P":
            if modifiers.contains(.shift), let url = currentURL {
                if picks.contains(url) {
                    picks.remove(url)
                } else {
                    picks.insert(url)
                    rejects.remove(url)
                }
                return .togglePick
            }
            return .none
        case "X":
            if modifiers.contains(.shift), let url = currentURL {
                if rejects.contains(url) {
                    rejects.remove(url)
                } else {
                    rejects.insert(url)
                    picks.remove(url)
                }
                return .toggleReject
            }
            return .none
        default:
            // Digits 0-9 set the color label on the current photo.
            if let digit = keyCharacter.wholeNumberValue, (0...9).contains(digit) {
                if let url = currentURL {
                    if digit == 0 {
                        colorLabels.removeValue(forKey: url)
                    } else {
                        colorLabels[url] = digit
                    }
                }
                return .setColorLabel(digit)
            }
            return .none
        }
    }
}
