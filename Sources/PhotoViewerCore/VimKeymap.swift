import Foundation
import CryptoKit

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

    public var description: String {
        switch self {
        case .unsupportedVersion(let found, let supported):
            return "VimKeymap state version \(found) is newer than supported (\(supported))"
        }
    }
}

/// Vim-style keystroke dispatcher with per-folder state persistence.
///
/// State lives in memory and serializes to
/// `~/Library/Application Support/photo-viewer/VimState/<folder-sha>.json`.
/// The dispatcher is a tiny state machine: `pendingPrefix` is a `String`
/// (rather than an enum) so future chords like counts (`5j`) or two-key
/// operators can extend it without re-shaping the state field. Single-quote
/// for mark-jump is handled by checking the literal character `"'"`.
@MainActor
@Observable
public final class VimKeymap {
    /// Bumped when the on-disk format changes in a way older builds can't
    /// safely round-trip. Older code refuses to load a newer file.
    public static let supportedVersion = 1

    /// Marks (`m<x>` to set, `'<x>` to jump). Stored in memory as URLs;
    /// serialized as relative paths so the JSON is portable across moves
    /// of the parent folder.
    public var marks: [Character: URL] = [:]

    /// Color label 0-9 per photo URL. Absence == 0 / no label.
    public var colorLabels: [URL: Int] = [:]

    /// Picks and rejects are independent sets — a photo can be neither, but
    /// the UI typically shouldn't show both simultaneously. The dispatcher
    /// makes no such guarantee; callers can decide policy.
    public var picks: Set<URL> = []
    public var rejects: Set<URL> = []

    /// Chord prefix accumulator. Empty between completed actions; non-empty
    /// after a leader key (`g`, `m`, `'`) until the second key arrives or
    /// any unrecognized key clears it.
    public var pendingPrefix: String = ""

    public init() {}

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

    // MARK: - Persistence

    /// Resolves `~/Library/Application Support/photo-viewer/VimState/<sha>.json`
    /// for `folderURL`. SHA the path so the state file lives outside the
    /// user's photo folder but stays addressable per-folder. Mirrors the
    /// pattern used by `EmbeddingIndex.indexFileURL(for:)`.
    public static func stateFileURL(for folderURL: URL) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("photo-viewer/VimState", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sha = SHA256.hash(data: Data(folderURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return base.appendingPathComponent("\(sha).json")
    }

    /// Persist current state to the per-folder JSON file. Marks are stored
    /// as relative paths against `folder` so the JSON survives the user
    /// renaming or moving the parent directory.
    public func save(folder: URL) throws {
        let url = try Self.stateFileURL(for: folder)
        let payload = StateFile(
            version: Self.supportedVersion,
            folderPath: folder.path,
            updatedAt: Date(),
            marks: marks.reduce(into: [:]) { acc, kv in
                acc[String(kv.key)] = Self.relativePath(of: kv.value, under: folder)
            },
            colorLabels: colorLabels.reduce(into: [:]) { acc, kv in
                acc[Self.relativePath(of: kv.key, under: folder)] = kv.value
            },
            picks: picks.map { Self.relativePath(of: $0, under: folder) }.sorted(),
            rejects: rejects.map { Self.relativePath(of: $0, under: folder) }.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
    }

    /// Capture current state into a Sendable snapshot, then write to disk
    /// off the main actor. Avoids blocking the main thread on slow volumes.
    public func saveInBackground(folder: URL) {
        let snapshot = StateFile(
            version: Self.supportedVersion,
            folderPath: folder.path,
            updatedAt: Date(),
            marks: marks.reduce(into: [:]) { acc, kv in
                acc[String(kv.key)] = Self.relativePath(of: kv.value, under: folder)
            },
            colorLabels: colorLabels.reduce(into: [:]) { acc, kv in
                acc[Self.relativePath(of: kv.key, under: folder)] = kv.value
            },
            picks: picks.map { Self.relativePath(of: $0, under: folder) }.sorted(),
            rejects: rejects.map { Self.relativePath(of: $0, under: folder) }.sorted()
        )
        // Compute the file URL on main (it needs @MainActor isolation for
        // the static method), then detach the actual write.
        guard let url = try? Self.stateFileURL(for: folder) else { return }
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Load state from the per-folder JSON file. Returns a fresh empty
    /// instance if no file exists yet; throws `VimKeymapError` on a
    /// future-version file.
    public static func load(folder: URL) throws -> VimKeymap {
        let keymap = VimKeymap()
        let url = try Self.stateFileURL(for: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return keymap }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(StateFile.self, from: data)
        if payload.version > Self.supportedVersion {
            throw VimKeymapError.unsupportedVersion(
                found: payload.version, supported: Self.supportedVersion
            )
        }
        // Rehydrate URLs against the live folder. If the folder has been
        // renamed since the save, the absolute paths will reflect the new
        // location, which is exactly what we want.
        keymap.marks = payload.marks.reduce(into: [:]) { acc, kv in
            guard let ch = kv.key.first, kv.key.count == 1 else { return }
            acc[ch] = folder.appendingPathComponent(kv.value)
        }
        keymap.colorLabels = payload.colorLabels.reduce(into: [:]) { acc, kv in
            acc[folder.appendingPathComponent(kv.key)] = kv.value
        }
        keymap.picks = Set(payload.picks.map { folder.appendingPathComponent($0) })
        keymap.rejects = Set(payload.rejects.map { folder.appendingPathComponent($0) })
        return keymap
    }

    // MARK: - Internal helpers

    /// Best-effort relative path. Falls back to the absolute path if the
    /// URL is not actually rooted under `folder` — a robustness valve for
    /// callers that pass URLs from other directories.
    static func relativePath(of url: URL, under folder: URL) -> String {
        let folderPath = folder.path
        let urlPath = url.path
        let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        if urlPath.hasPrefix(prefix) {
            return String(urlPath.dropFirst(prefix.count))
        }
        if urlPath == folderPath {
            return ""
        }
        return urlPath
    }

    /// On-disk envelope. `Character` keys serialize as 1-char strings since
    /// JSON keys must be strings.
    private struct StateFile: Codable {
        let version: Int
        let folderPath: String
        let updatedAt: Date
        let marks: [String: String]          // mark-letter -> relative path
        let colorLabels: [String: Int]       // relative path -> 0-9
        let picks: [String]                  // sorted relative paths
        let rejects: [String]                // sorted relative paths
    }
}
