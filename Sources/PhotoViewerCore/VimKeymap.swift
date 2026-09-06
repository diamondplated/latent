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
    private static let supportedReferenceRegistryVersion = 1
    private static let referenceRegistryFilename = "folder-references.json"
    private static var nextSaveRevision: UInt64 = 0

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
    public private(set) var lastPersistenceError: VimKeymapPersistenceFailure?

    /// True only when in-memory culling differs from the newest confirmed
    /// state-file snapshot. App lifecycle code uses this to avoid creating an
    /// empty bookmark/state record for every folder that is merely browsed.
    public private(set) var hasUnpersistedChanges = false

    private var latestBackgroundSaveRevision: UInt64 = 0
    private var mutationRevision: UInt64 = 0
    /// Persistence is bound to the folder incarnation accepted by `load` (or
    /// captured on the first save of a programmatically-created keymap). Saves
    /// never rediscover their destination from a mutable pathname.
    @ObservationIgnored private var boundFolderTarget: FolderTargetSnapshot?
    @ObservationIgnored private var boundReferenceID: String?

    public init() {}

    public func clearPersistenceError() {
        lastPersistenceError = nil
    }

    private func markStateChanged() {
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

    // MARK: - Persistence

    /// Resolves the state file for `folderURL`. Existing folders are registered
    /// with Foundation bookmark data, which is designed to reconnect a saved
    /// reference after a rename, same-volume move, or system restart. The
    /// filesystem identity and path hashes remain compatibility fallbacks.
    public static func stateFileURL(for folderURL: URL) throws -> URL {
        let base = try stateDirectoryURL()
        if let lookup = try folderReference(
            for: folderURL,
            in: base,
            createIfMissing: true
        ) {
            return referenceStateFileURL(referenceID: lookup.reference.id, in: base)
        }
        if let identity = folderIdentity(for: folderURL) {
            return resourceIdentityStateFileURL(identity: identity, in: base)
        }
        return base.appendingPathComponent("\(pathHash(for: folderURL)).json")
    }

    /// Removes state and its durable folder-reference entry. This is primarily
    /// useful to callers that intentionally forget a folder (and keeps tests
    /// from accumulating bookmark records); it never touches the photo folder.
    public static func removePersistedState(for folderURL: URL) throws {
        let base = try stateDirectoryURL()
        try withRegistryLock(in: base) {
            var registry = try loadFolderReferenceRegistry(in: base)
            let matchingIDs = Set(
                registry.references.compactMap { reference in
                    referenceMatches(reference, folderURL: folderURL) ? reference.id : nil
                }
            )

            for id in matchingIDs {
                try removeItemIfPresent(at: referenceStateFileURL(referenceID: id, in: base))
            }
            if !matchingIDs.isEmpty {
                registry.references.removeAll { matchingIDs.contains($0.id) }
                try saveFolderReferenceRegistry(registry, in: base)
            }
        }

        if let identity = folderIdentity(for: folderURL) {
            try removeItemIfPresent(at: resourceIdentityStateFileURL(identity: identity, in: base))
        }
        try removeItemIfPresent(at: legacyStateFileURL(for: folderURL))
    }

    /// Version-1 location retained so an existing installation can migrate
    /// its path-keyed state the next time that folder is opened.
    static func legacyStateFileURL(for folderURL: URL) throws -> URL {
        try stateDirectoryURL()
            .appendingPathComponent("\(pathHash(for: folderURL)).json")
    }

    private static func referenceStateFileURL(referenceID: String, in base: URL) -> URL {
        base.appendingPathComponent("folder-reference-\(referenceID).json")
    }

    private static func resourceIdentityStateFileURL(identity: String, in base: URL) -> URL {
        base.appendingPathComponent("folder-\(identity).json")
    }

    private static func stateDirectoryURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["LATENT_VIM_STATE_DIRECTORY"],
           !override.isEmpty {
            guard override.hasPrefix("/") else {
                throw VimKeymapError.referenceRegistryUnavailable(
                    "LATENT_VIM_STATE_DIRECTORY must be an absolute path"
                )
            }
            let base = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            return base
        }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("photo-viewer/VimState", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func pathHash(for folderURL: URL) -> String {
        SHA256.hash(data: Data(folderURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonicalFolderURL(_ folderURL: URL) -> URL {
        folderURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func folderTargetSnapshot(for folderURL: URL) -> FolderTargetSnapshot? {
        let canonicalURL = canonicalFolderURL(folderURL)
        guard isDirectory(canonicalURL) else { return nil }
        var status = stat()
        guard canonicalURL.path.withCString({ lstat($0, &status) }) == 0 else {
            return nil
        }
        return FolderTargetSnapshot(
            canonicalPath: canonicalURL.path,
            deviceID: UInt64(bitPattern: Int64(status.st_dev)),
            inode: UInt64(status.st_ino),
            resourceIdentity: folderIdentity(for: canonicalURL),
            creationDate: directoryCreationDate(for: canonicalURL)
        )
    }

    private static func folderReference(
        for folderURL: URL,
        in base: URL,
        createIfMissing: Bool,
        allowUnverifiedMatch: Bool = false,
        refreshMatchedReference: Bool = true
    ) throws -> FolderReferenceLookup? {
        try withRegistryLock(in: base) {
            try folderReferenceUnlocked(
                for: folderURL,
                in: base,
                createIfMissing: createIfMissing,
                allowUnverifiedMatch: allowUnverifiedMatch,
                refreshMatchedReference: refreshMatchedReference
            )
        }
    }

    private static func folderReferenceUnlocked(
        for folderURL: URL,
        in base: URL,
        createIfMissing: Bool,
        allowUnverifiedMatch: Bool,
        refreshMatchedReference: Bool
    ) throws -> FolderReferenceLookup? {
        let canonicalURL = canonicalFolderURL(folderURL)
        guard let target = folderTargetSnapshot(for: canonicalURL) else { return nil }

        var registry = try loadFolderReferenceRegistry(in: base)
        let canonicalPath = target.canonicalPath
        let identity = target.resourceIdentity
        let creationDate = target.creationDate

        // Resolving persisted bookmark bytes is the authoritative match. It is
        // deliberately tried before resource ids because Apple documents those
        // opaque ids as unsuitable for persistence across system restarts.
        var matchedIndex: Int?
        var matchedBookmarkIsStale = false
        var matchedRequiresConfirmation = false
        var unverifiableReferenceIDs: Set<String> = []
        for (index, reference) in registry.references.enumerated() {
            guard let resolved = resolveFolderReference(reference),
                  pathsReferToSameFolder(resolved.url.path, canonicalPath) else { continue }
            switch resolvedReferenceMatch(
                reference,
                resolvedIsStale: resolved.isStale,
                targetIdentity: identity,
                targetCreationDate: creationDate
            ) {
            case .matches:
                matchedIndex = index
                matchedBookmarkIsStale = resolved.isStale
            case .mismatch:
                break
            case .unverifiable:
                unverifiableReferenceIDs.insert(reference.id)
            }
            if matchedIndex != nil { break }
        }

        // If bookmark resolution is temporarily unavailable, accept only the
        // last known path plus corroborating directory metadata. Never match
        // on an opaque filesystem id alone: ids can be reused.
        if matchedIndex == nil {
            for (index, reference) in registry.references.enumerated() {
                guard pathsReferToSameFolder(reference.lastKnownPath, canonicalPath) else {
                    continue
                }
                switch metadataReferenceMatch(
                    reference,
                    targetIdentity: identity,
                    targetCreationDate: creationDate
                ) {
                case .matches:
                    matchedIndex = index
                case .mismatch:
                    break
                case .unverifiable:
                    unverifiableReferenceIDs.insert(reference.id)
                }
                if matchedIndex != nil { break }
            }
        }

        if matchedIndex == nil, !unverifiableReferenceIDs.isEmpty {
            // Use the same deterministic candidate for the initial refusal and
            // a later confirmed retry. `id` breaks a rare equal-date tie.
            let candidateIndex = registry.references.indices
                .filter { unverifiableReferenceIDs.contains(registry.references[$0].id) }
                .max { lhs, rhs in
                    let left = registry.references[lhs]
                    let right = registry.references[rhs]
                    if left.updatedAt == right.updatedAt { return left.id < right.id }
                    return left.updatedAt < right.updatedAt
                }!
            guard allowUnverifiedMatch else {
                let referenceID = registry.references[candidateIndex].id
                throw VimKeymapError.folderContinuityUnverifiable(
                    referenceStateFileURL(referenceID: referenceID, in: base),
                    "a saved folder reference resolves to this path but lacks enough identity metadata"
                )
            }
            // The user explicitly confirmed this ambiguous migration. Prefer
            // the newest candidate if a damaged/old registry has more than one
            // unresolved record for the same pathname.
            matchedIndex = candidateIndex
            matchedBookmarkIsStale = true
            matchedRequiresConfirmation = true
        }

        if let matchedIndex {
            var reference = registry.references[matchedIndex]
            let needsRefresh = reference.lastKnownPath != canonicalPath
                || (identity != nil && reference.resourceIdentity != identity)
                || (creationDate != nil && reference.creationDate != creationDate)
                || matchedBookmarkIsStale
            if needsRefresh && refreshMatchedReference {
                reference.bookmarkData = try makeBookmark(for: canonicalURL)
                reference.lastKnownPath = canonicalPath
                reference.resourceIdentity = identity ?? reference.resourceIdentity
                reference.creationDate = creationDate ?? reference.creationDate
                reference.updatedAt = Date()
                registry.references[matchedIndex] = reference
                try saveFolderReferenceRegistry(registry, in: base)
            }
            return FolderReferenceLookup(
                reference: reference,
                requiresConfirmation: matchedRequiresConfirmation,
                target: target
            )
        }

        guard createIfMissing else { return nil }
        let bookmarkData = try makeBookmark(for: canonicalURL)
        let reference = FolderReference(
            id: UUID().uuidString.lowercased(),
            bookmarkData: bookmarkData,
            lastKnownPath: canonicalPath,
            resourceIdentity: identity,
            creationDate: creationDate,
            updatedAt: Date()
        )
        registry.references.append(reference)
        try saveFolderReferenceRegistry(registry, in: base)
        return FolderReferenceLookup(
            reference: reference,
            requiresConfirmation: false,
            target: target
        )
    }

    /// Commit the exact reference inspected by `load`, after its state bytes
    /// have decoded and passed continuity checks. The registry is reloaded
    /// under the process lock and compared as a CAS token; another process or
    /// a folder replacement therefore causes a refusal instead of rebinding a
    /// different record selected by a second generic lookup.
    private static func commitFolderReference(
        _ lookup: FolderReferenceLookup,
        for folderURL: URL,
        in base: URL
    ) throws -> FolderReference {
        try withRegistryLock(in: base) {
            var registry = try loadFolderReferenceRegistry(in: base)
            guard let index = registry.references.firstIndex(where: {
                $0.id == lookup.reference.id
            }), registry.references[index] == lookup.reference else {
                throw VimKeymapError.referenceRegistryUnavailable(
                    "the confirmed folder reference changed before it could be committed"
                )
            }

            let canonicalURL = canonicalFolderURL(folderURL)
            guard let target = folderTargetSnapshot(for: canonicalURL),
                  target == lookup.target else {
                throw VimKeymapError.folderContinuityMismatch(
                    referenceStateFileURL(referenceID: lookup.reference.id, in: base)
                )
            }
            let canonicalPath = target.canonicalPath
            let identity = target.resourceIdentity
            let creationDate = target.creationDate

            let current = registry.references[index]
            let match: FolderReferenceMatch
            let bookmarkNeedsRefresh: Bool
            if let resolved = resolveFolderReference(current),
               pathsReferToSameFolder(resolved.url.path, canonicalPath) {
                bookmarkNeedsRefresh = resolved.isStale
                match = resolvedReferenceMatch(
                    current,
                    resolvedIsStale: resolved.isStale,
                    targetIdentity: identity,
                    targetCreationDate: creationDate
                )
            } else if pathsReferToSameFolder(current.lastKnownPath, canonicalPath) {
                bookmarkNeedsRefresh = true
                match = metadataReferenceMatch(
                    current,
                    targetIdentity: identity,
                    targetCreationDate: creationDate
                )
            } else {
                bookmarkNeedsRefresh = true
                match = .mismatch
            }

            switch match {
            case .matches:
                break
            case .mismatch:
                throw VimKeymapError.folderContinuityMismatch(
                    referenceStateFileURL(referenceID: current.id, in: base)
                )
            case .unverifiable:
                guard lookup.requiresConfirmation else {
                    throw VimKeymapError.folderContinuityUnverifiable(
                        referenceStateFileURL(referenceID: current.id, in: base),
                        "the folder reference lost its identity evidence before it could be refreshed"
                    )
                }
            }

            let needsRefresh = lookup.requiresConfirmation
                || bookmarkNeedsRefresh
                || current.lastKnownPath != canonicalPath
                || (identity != nil && current.resourceIdentity != identity)
                || (creationDate != nil && current.creationDate != creationDate)
            guard needsRefresh else { return current }

            var refreshed = current
            refreshed.bookmarkData = try makeBookmark(for: canonicalURL)
            refreshed.lastKnownPath = canonicalPath
            refreshed.resourceIdentity = identity ?? current.resourceIdentity
            refreshed.creationDate = creationDate ?? current.creationDate
            refreshed.updatedAt = Date()
            registry.references[index] = refreshed
            try saveFolderReferenceRegistry(registry, in: base)
            return refreshed
        }
    }

    /// Create the destination for a validated compatibility migration without
    /// rediscovering the folder by path. The target fingerprint was captured
    /// before source validation and is checked before and after bookmark
    /// creation while the registry lock prevents another Latent process from
    /// inserting a competing reference.
    private static func createMigrationFolderReference(
        for folderURL: URL,
        expectedTarget: FolderTargetSnapshot,
        sourceURL: URL,
        in base: URL
    ) throws -> FolderReference {
        try withRegistryLock(in: base) {
            guard folderTargetSnapshot(for: folderURL) == expectedTarget else {
                throw VimKeymapError.folderContinuityMismatch(sourceURL)
            }
            if try folderReferenceUnlocked(
                for: folderURL,
                in: base,
                createIfMissing: false,
                allowUnverifiedMatch: false,
                refreshMatchedReference: false
            ) != nil {
                throw VimKeymapError.referenceRegistryUnavailable(
                    "the folder-reference registry changed during migration"
                )
            }

            let canonicalURL = URL(
                fileURLWithPath: expectedTarget.canonicalPath,
                isDirectory: true
            )
            let bookmarkData = try makeBookmark(for: canonicalURL)
            guard folderTargetSnapshot(for: folderURL) == expectedTarget else {
                throw VimKeymapError.folderContinuityMismatch(sourceURL)
            }

            var registry = try loadFolderReferenceRegistry(in: base)
            var reference: FolderReference
            repeat {
                reference = FolderReference(
                    id: UUID().uuidString.lowercased(),
                    bookmarkData: bookmarkData,
                    lastKnownPath: expectedTarget.canonicalPath,
                    resourceIdentity: expectedTarget.resourceIdentity,
                    creationDate: expectedTarget.creationDate,
                    updatedAt: Date()
                )
            } while registry.references.contains(where: { $0.id == reference.id })

            guard let resolved = resolveFolderReference(reference),
                  folderTargetSnapshot(for: resolved.url) == expectedTarget,
                  folderTargetSnapshot(for: folderURL) == expectedTarget else {
                throw VimKeymapError.folderContinuityMismatch(sourceURL)
            }
            registry.references.append(reference)
            try saveFolderReferenceRegistry(registry, in: base)
            return reference
        }
    }

    private static func exactFolderReferenceLookup(
        referenceID: String,
        expectedTarget: FolderTargetSnapshot,
        in base: URL
    ) throws -> FolderReferenceLookup {
        try withRegistryLock(in: base) {
            let registry = try loadFolderReferenceRegistry(in: base)
            guard let reference = registry.references.first(where: {
                $0.id == referenceID
            }) else {
                throw VimKeymapError.referenceRegistryUnavailable(
                    "the bound folder reference no longer exists"
                )
            }
            return FolderReferenceLookup(
                reference: reference,
                requiresConfirmation: false,
                target: expectedTarget
            )
        }
    }

    /// Resolve a save against this keymap's accepted folder incarnation. This
    /// may register a fresh programmatic keymap on its first save, but every
    /// later write addresses that exact reference id.
    private func persistenceDestination(
        for folderURL: URL
    ) throws -> (url: URL, target: FolderTargetSnapshot) {
        guard let liveTarget = Self.folderTargetSnapshot(for: folderURL) else {
            throw VimKeymapError.folderContinuityMismatch(folderURL)
        }
        if boundFolderTarget == nil { boundFolderTarget = liveTarget }
        guard let expectedTarget = boundFolderTarget,
              liveTarget == expectedTarget else {
            throw VimKeymapError.folderContinuityMismatch(folderURL)
        }

        let base = try Self.stateDirectoryURL()
        let reference: FolderReference
        if let boundReferenceID {
            let lookup = try Self.exactFolderReferenceLookup(
                referenceID: boundReferenceID,
                expectedTarget: expectedTarget,
                in: base
            )
            reference = try Self.commitFolderReference(
                lookup,
                for: folderURL,
                in: base
            )
        } else if let lookup = try Self.folderReference(
            for: folderURL,
            in: base,
            createIfMissing: false,
            refreshMatchedReference: false
        ) {
            guard lookup.target == expectedTarget,
                  !lookup.requiresConfirmation else {
                throw VimKeymapError.folderContinuityUnverifiable(
                    Self.referenceStateFileURL(referenceID: lookup.reference.id, in: base),
                    "the save destination needs explicit folder confirmation"
                )
            }
            reference = try Self.commitFolderReference(
                lookup,
                for: folderURL,
                in: base
            )
        } else {
            reference = try Self.createMigrationFolderReference(
                for: folderURL,
                expectedTarget: expectedTarget,
                sourceURL: folderURL,
                in: base
            )
        }
        boundReferenceID = reference.id
        return (
            Self.referenceStateFileURL(referenceID: reference.id, in: base),
            expectedTarget
        )
    }

    private static func referenceMatches(_ reference: FolderReference, folderURL: URL) -> Bool {
        let canonicalURL = canonicalFolderURL(folderURL)
        guard isDirectory(canonicalURL) else { return false }
        let canonicalPath = canonicalURL.path
        let identity = folderIdentity(for: canonicalURL)
        let creationDate = directoryCreationDate(for: canonicalURL)
        if let resolved = resolveFolderReference(reference),
           pathsReferToSameFolder(resolved.url.path, canonicalPath),
           resolvedReferenceMatch(
               reference,
               resolvedIsStale: resolved.isStale,
               targetIdentity: identity,
               targetCreationDate: creationDate
           ) == .matches {
            return true
        }
        return pathsReferToSameFolder(reference.lastKnownPath, canonicalPath)
            && metadataReferenceMatch(
                reference,
                targetIdentity: identity,
                targetCreationDate: creationDate
            ) == .matches
    }

    private static func resolvedReferenceMatch(
        _ reference: FolderReference,
        resolvedIsStale: Bool,
        targetIdentity: String?,
        targetCreationDate: Date?
    ) -> FolderReferenceMatch {
        // A replacement directory at the same path can be returned by stale
        // bookmark resolution. A known creation-date mismatch is conclusive.
        if let stored = reference.creationDate, let targetCreationDate,
           !datesIdentifySameDirectory(stored, targetCreationDate) {
            return .mismatch
        }
        // A live, non-stale bookmark is the durable authority. Resource ids
        // are deliberately not checked here because Apple does not promise
        // they remain stable across restarts or remounts.
        if !resolvedIsStale { return .matches }
        return metadataReferenceMatch(
            reference,
            targetIdentity: targetIdentity,
            targetCreationDate: targetCreationDate
        )
    }

    private static func metadataReferenceMatch(
        _ reference: FolderReference,
        targetIdentity: String?,
        targetCreationDate: Date?
    ) -> FolderReferenceMatch {
        var hasCreationDateProof = false
        var resourceIdentityContradicts = false
        if let stored = reference.creationDate, let targetCreationDate {
            guard datesIdentifySameDirectory(stored, targetCreationDate) else {
                return .mismatch
            }
            hasCreationDateProof = true
        }
        if let stored = reference.resourceIdentity, let targetIdentity {
            resourceIdentityContradicts = stored != targetIdentity
        }
        // Opaque filesystem ids are useful contradiction evidence but are not
        // documented as durable and may be reused. Metadata-only recovery must
        // have a matching creation-date pair; otherwise require confirmation.
        guard hasCreationDateProof, !resourceIdentityContradicts else {
            return .unverifiable
        }
        return .matches
    }

    private static func datesIdentifySameDirectory(_ lhs: Date, _ rhs: Date) -> Bool {
        lhs == rhs
    }

    private static func directoryCreationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    private static func pathsReferToSameFolder(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        func aliases(for path: String) -> Set<String> {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            var result: Set<String> = [standardized]
            let resolved = URL(fileURLWithPath: standardized)
                .resolvingSymlinksInPath()
                .standardizedFileURL.path
            result.insert(resolved)
            // Darwin may spell the same data-volume path with or without the
            // `/private` prefix (notably /tmp and /var).
            for candidate in Array(result) where candidate.hasPrefix("/private/") {
                result.insert(String(candidate.dropFirst("/private".count)))
            }
            return result
        }
        return !aliases(for: lhs).isDisjoint(with: aliases(for: rhs))
    }

    /// Compare the path spelling without following its final symbolic link.
    /// The `/private` alias normalization remains necessary for temporary paths
    /// returned in either Darwin form.
    private static func pathsHaveSameLexicalLocation(_ lhs: String?, _ rhs: String) -> Bool {
        guard let lhs else { return false }
        func aliases(for path: String) -> Set<String> {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            var result: Set<String> = [standardized]
            if standardized.hasPrefix("/private/") {
                result.insert(String(standardized.dropFirst("/private".count)))
            } else if standardized.hasPrefix("/tmp/") || standardized.hasPrefix("/var/") {
                result.insert("/private" + standardized)
            }
            return result
        }
        return !aliases(for: lhs).isDisjoint(with: aliases(for: rhs))
    }

    private static func makeBookmark(for folderURL: URL) throws -> Data {
        try folderURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
    }

    private static func resolveFolderReference(
        _ reference: FolderReference
    ) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: reference.bookmarkData,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return (canonicalFolderURL(url), isStale)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func loadFolderReferenceRegistry(in base: URL) throws -> FolderReferenceRegistry {
        let url = base.appendingPathComponent(referenceRegistryFilename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FolderReferenceRegistry(
                version: supportedReferenceRegistryVersion,
                references: []
            )
        }
        let registry = try JSONDecoder().decode(
            FolderReferenceRegistry.self,
            from: Data(contentsOf: url)
        )
        guard registry.version <= supportedReferenceRegistryVersion else {
            throw VimKeymapError.unsupportedReferenceRegistryVersion(
                found: registry.version,
                supported: supportedReferenceRegistryVersion
            )
        }
        guard registry.version == supportedReferenceRegistryVersion else {
            throw VimKeymapError.invalidReferenceRegistry(
                "unsupported legacy version \(registry.version)"
            )
        }
        let ids = registry.references.map(\.id)
        guard Set(ids).count == ids.count,
              ids.allSatisfy({ id in
                  guard let uuid = UUID(uuidString: id) else { return false }
                  return uuid.uuidString.lowercased() == id
              }) else {
            throw VimKeymapError.invalidReferenceRegistry(
                "reference ids must be unique canonical UUIDs"
            )
        }
        return registry
    }

    private static func saveFolderReferenceRegistry(
        _ registry: FolderReferenceRegistry,
        in base: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(registry)
        try data.write(
            to: base.appendingPathComponent(referenceRegistryFilename),
            options: .atomic
        )
    }

    /// `Data.write(.atomic)` prevents torn bytes but not a lost update from
    /// two processes that both read before either writes. Hold a small flock
    /// across each complete registry transaction so concurrent app/verifier
    /// processes merge against the newest committed registry.
    private static func withRegistryLock<T>(
        in base: URL,
        _ body: () throws -> T
    ) throws -> T {
        let lockURL = base.appendingPathComponent(".folder-references.lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw VimKeymapError.referenceRegistryUnavailable(
                "could not open lock: \(String(cString: strerror(errno)))"
            )
        }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw VimKeymapError.referenceRegistryUnavailable(
                "could not acquire lock: \(String(cString: strerror(errno)))"
            )
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private static func removeItemIfPresent(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Resource identifiers are opaque by design and file identifiers are
    /// unique only within a volume, so the stable key hashes both the volume
    /// and file values. On Darwin Foundation they are commonly represented as
    /// `Data`, with secure-coding as a fallback for other representations.
    public static func folderIdentity(for folderURL: URL) -> String? {
        let resolvedURL = folderURL.resolvingSymlinksInPath()
        guard
            let values = try? resolvedURL.resourceValues(forKeys: [
                .volumeIdentifierKey,
                .fileResourceIdentifierKey,
            ]),
            let volumeIdentifier = values.volumeIdentifier,
            let fileIdentifier = values.fileResourceIdentifier,
            let volumeData = opaqueIdentifierData(volumeIdentifier),
            let fileData = opaqueIdentifierData(fileIdentifier)
        else {
            return nil
        }

        // Digest the components separately before combining them so their
        // boundary is unambiguous regardless of the identifiers' byte shape.
        var identityData = Data(SHA256.hash(data: volumeData))
        identityData.append(contentsOf: SHA256.hash(data: fileData))
        return SHA256.hash(data: identityData)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func opaqueIdentifierData(_ identifier: Any) -> Data? {
        if let data = identifier as? Data {
            return data
        }
        return try? NSKeyedArchiver.archivedData(
            withRootObject: identifier,
            requiringSecureCoding: true
        )
    }

    /// Persist current state to the per-folder JSON file. Marks are stored
    /// as relative paths against `folder` so the JSON survives the user
    /// renaming or moving the parent directory.
    public func save(folder: URL) throws {
        try persist(folder: folder, operation: .save)
    }

    /// Capture current state into a Sendable snapshot, then write to disk
    /// off the main actor. Avoids blocking the main thread on slow volumes.
    @discardableResult
    public func saveInBackground(folder: URL) -> Task<Void, Never> {
        Self.nextSaveRevision &+= 1
        let revision = Self.nextSaveRevision
        let capturedMutationRevision = mutationRevision
        latestBackgroundSaveRevision = revision

        let destination: (url: URL, target: FolderTargetSnapshot)
        do {
            destination = try persistenceDestination(for: folder)
        } catch {
            recordPersistenceFailure(
                operation: .backgroundSave,
                fileURL: nil,
                error: error
            )
            return Task {}
        }

        let data: Data
        do {
            guard Self.folderTargetSnapshot(for: folder) == destination.target else {
                throw VimKeymapError.folderContinuityMismatch(folder)
            }
            data = try Self.encode(makeStateFile(
                folder: folder,
                target: destination.target
            ))
            guard Self.folderTargetSnapshot(for: folder) == destination.target else {
                throw VimKeymapError.folderContinuityMismatch(folder)
            }
        } catch {
            recordPersistenceFailure(
                operation: .backgroundSave,
                fileURL: destination.url,
                error: error
            )
            return Task {}
        }

        // Compute and encode the tiny snapshot on main, then hand the actual
        // atomic filesystem write to a serialized writer queue. A monotonically
        // increasing process-wide revision prevents rapid edits from finishing
        // out of order and letting an older snapshot replace the newest one.
        return Task {
            let outcome = await VimStateFileWriter.shared.write(
                data,
                to: destination.url,
                revision: revision
            )
            guard latestBackgroundSaveRevision == revision else { return }
            switch outcome {
            case .written:
                lastPersistenceError = nil
                if mutationRevision == capturedMutationRevision {
                    hasUnpersistedChanges = false
                }
            case .superseded:
                break
            case .failed(let message):
                recordPersistenceFailure(
                    operation: .backgroundSave,
                    fileURL: destination.url,
                    message: message
                )
            }
        }
    }

    /// Load state from the per-folder JSON file. Returns a fresh empty
    /// instance if no file exists yet; throws `VimKeymapError` on a
    /// future-version file.
    public static func load(
        folder: URL,
        allowUnverifiedMigration: Bool = false
    ) throws -> VimKeymap {
        let keymap = VimKeymap()
        let base = try Self.stateDirectoryURL()
        let initialTarget = Self.folderTargetSnapshot(for: folder)
        keymap.boundFolderTarget = initialTarget
        let existingReferenceLookup = try Self.folderReference(
            for: folder,
            in: base,
            createIfMissing: false,
            allowUnverifiedMatch: allowUnverifiedMigration,
            refreshMatchedReference: false
        )
        if let existingReferenceLookup, existingReferenceLookup.target != initialTarget {
            throw VimKeymapError.folderContinuityMismatch(folder)
        }
        let existingReferenceURL = existingReferenceLookup.map {
            Self.referenceStateFileURL(referenceID: $0.reference.id, in: base)
        }
        let resourceIdentityURL = Self.folderIdentity(for: folder).map {
            Self.resourceIdentityStateFileURL(identity: $0, in: base)
        }
        let legacyURL = try Self.legacyStateFileURL(for: folder)
        var candidates: [StateSource] = []
        func appendCandidate(
            _ url: URL?,
            kind: StateSourceKind,
            referenceRequiresConfirmation: Bool = false
        ) {
            guard let url,
                  !candidates.contains(where: { $0.url.path == url.path }) else { return }
            candidates.append(StateSource(
                url: url,
                kind: kind,
                referenceRequiresConfirmation: referenceRequiresConfirmation
            ))
        }
        appendCandidate(
            existingReferenceURL,
            kind: .bookmark,
            referenceRequiresConfirmation: existingReferenceLookup?.requiresConfirmation ?? false
        )
        appendCandidate(resourceIdentityURL, kind: .resourceIdentity)
        appendCandidate(legacyURL, kind: .legacyPath)

        let existingSources = candidates.filter {
            FileManager.default.fileExists(atPath: $0.url.path)
        }
        guard !existingSources.isEmpty else {
            // Preserve ordinary stale-bookmark refreshes and let an explicit
            // confirmation repair an ambiguous reference even when it has no
            // state file. Crucially, this happens only after we know there are
            // no candidate bytes that still need decoding or validation.
            if let existingReferenceLookup {
                let reference = try Self.commitFolderReference(
                    existingReferenceLookup,
                    for: folder,
                    in: base
                )
                keymap.boundReferenceID = reference.id
            }
            return keymap
        }
        guard let initialTarget,
              Self.folderTargetSnapshot(for: folder) == initialTarget else {
            throw VimKeymapError.folderContinuityMismatch(existingSources[0].url)
        }

        // Decode and classify every on-disk candidate before selecting one.
        // A compatibility file conclusively tied to an older folder incarnation
        // is ignored; two viable or ambiguous sources fail closed. This lets a
        // replacement folder keep its own new bookmark state without allowing
        // a concurrent legacy writer to be hidden by priority order.
        var viableSources: [ValidatedStateSource] = []
        for source in existingSources {
            let data = try Data(contentsOf: source.url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(StateFile.self, from: data)
            if payload.version > Self.supportedVersion {
                throw VimKeymapError.unsupportedVersion(
                    found: payload.version,
                    supported: Self.supportedVersion
                )
            }
            let match = Self.matchStateSourceToCurrentFolder(
                payload,
                source: source,
                folder: folder
            )
            if case .mismatch = match {
                if source.kind == .bookmark {
                    throw VimKeymapError.folderContinuityMismatch(source.url)
                }
                continue
            }
            viableSources.append(ValidatedStateSource(
                source: source,
                data: data,
                payload: payload,
                match: match
            ))
        }
        guard viableSources.count <= 1 else {
            throw VimKeymapError.conflictingStateSources(
                viableSources.map { $0.source.url }
            )
        }
        guard let validatedSource = viableSources.first else {
            return keymap
        }
        let source = validatedSource.source
        let sourceURL = source.url
        let data = validatedSource.data
        let payload = validatedSource.payload

        switch validatedSource.match {
        case .matches:
            break
        case .mismatch:
            preconditionFailure("mismatched sources were filtered above")
        case .unverifiable(let reason, let canTrustWithConfirmation):
            guard allowUnverifiedMigration, canTrustWithConfirmation else {
                throw VimKeymapError.folderContinuityUnverifiable(sourceURL, reason)
            }
            break
        }

        // Rehydrate URLs against the live folder. If the folder has been
        // renamed since the save, the absolute paths will reflect the new
        // location, which is exactly what we want.
        keymap.marks = payload.marks.reduce(into: [:]) { acc, kv in
            guard let ch = kv.key.first, kv.key.count == 1 else { return }
            acc[ch] = folder.appendingPathComponent(kv.value)
        }
        keymap.colorLabels = payload.colorLabels.reduce(into: [:]) { acc, kv in
            guard (1...9).contains(kv.value) else { return }
            acc[folder.appendingPathComponent(kv.key)] = kv.value
        }
        keymap.picks = Set(payload.picks.map { folder.appendingPathComponent($0) })
        keymap.rejects = Set(payload.rejects.map { folder.appendingPathComponent($0) })
        // Old files could contain both flags because earlier builds treated the
        // sets independently. Reject wins during migration so a negatively
        // culled item can never be mistaken for an accepted pick.
        keymap.picks.subtract(keymap.rejects)
        keymap.hasUnpersistedChanges = false

        // Upgrade both the schema and the lookup key in one atomic write. A
        // folder with no culling state is never registered merely because it
        // was opened; the durable bookmark is created only once state exists.
        // Do not discard successfully decoded in-memory state if migration
        // fails; expose that failure and leave the old file untouched.
        let currentURL: URL
        do {
            if let existingReferenceLookup {
                let reference = try Self.commitFolderReference(
                    existingReferenceLookup,
                    for: folder,
                    in: base
                )
                currentURL = Self.referenceStateFileURL(
                    referenceID: reference.id,
                    in: base
                )
                keymap.boundReferenceID = reference.id
            } else {
                let reference = try Self.createMigrationFolderReference(
                    for: folder,
                    expectedTarget: initialTarget,
                    sourceURL: sourceURL,
                    in: base
                )
                currentURL = Self.referenceStateFileURL(
                    referenceID: reference.id,
                    in: base
                )
                keymap.boundReferenceID = reference.id
            }
        } catch {
            keymap.hasUnpersistedChanges = true
            keymap.recordPersistenceFailure(
                operation: .migration,
                fileURL: nil,
                error: error
            )
            return keymap
        }
        if payload.version < Self.supportedVersion || sourceURL.path != currentURL.path {
            do {
                try keymap.persist(
                    folder: folder,
                    destinationURL: currentURL,
                    expectedTarget: initialTarget,
                    operation: .migration
                )
                if sourceURL.path != currentURL.path {
                    do {
                        let latestSourceData = try Data(contentsOf: sourceURL)
                        guard latestSourceData == data else {
                            keymap.hasUnpersistedChanges = true
                            keymap.recordPersistenceFailure(
                                operation: .migration,
                                fileURL: sourceURL,
                                message: "The source state changed during migration; Latent preserved it instead of deleting newer culling data."
                            )
                            return keymap
                        }
                        try FileManager.default.removeItem(at: sourceURL)
                    } catch {
                        keymap.recordPersistenceFailure(
                            operation: .migration,
                            fileURL: sourceURL,
                            error: error
                        )
                    }
                }
            } catch {
                // `persist` has already recorded a consumable failure.
            }
        }
        return keymap
    }

    private static func matchStateSourceToCurrentFolder(
        _ payload: StateFile,
        source: StateSource,
        folder: URL
    ) -> StateSourceMatch {
        let canonicalFolder = canonicalFolderURL(folder)
        guard isDirectory(canonicalFolder) else { return .mismatch }

        switch source.kind {
        case .bookmark:
            if source.referenceRequiresConfirmation,
               payload.folderCreationTimestamp == nil {
                return .unverifiable(
                    "the saved bookmark lacks creation metadata and needs confirmation",
                    canTrustWithConfirmation: true
                )
            }
            // Version 3 records carry an extra defense against a damaged or
            // manually edited registry. Older bookmark snapshots remain
            // readable because the registry already validated continuity.
            guard let storedTimestamp = payload.folderCreationTimestamp else {
                return .matches
            }
            guard let currentTimestamp = directoryCreationDate(for: canonicalFolder)?
                .timeIntervalSince1970 else {
                return .unverifiable(
                    "the folder creation date is unavailable",
                    canTrustWithConfirmation: true
                )
            }
            return storedTimestamp == currentTimestamp ? .matches : .mismatch

        case .resourceIdentity:
            guard let storedIdentity = payload.folderIdentity,
                  let currentIdentity = folderIdentity(for: canonicalFolder) else {
                return .unverifiable(
                    "the resource identity is unavailable",
                    canTrustWithConfirmation: false
                )
            }
            guard storedIdentity == currentIdentity else {
                return .unverifiable(
                    "the state payload does not match its resource-identity key",
                    canTrustWithConfirmation: false
                )
            }
            return matchFallbackSnapshotToCurrentFolder(
                payload,
                sourceURL: source.url,
                folder: canonicalFolder,
                requireUnchangedPathMetadata: false
            )

        case .legacyPath:
            guard pathsHaveSameLexicalLocation(payload.folderPath, folder.path) else {
                return .unverifiable(
                    "the state payload path does not match this folder",
                    canTrustWithConfirmation: false
                )
            }
            let pathEntryMatch = legacyPathEntryMatch(
                sourceURL: source.url,
                folderURL: folder
            )
            let fallbackMatch = matchFallbackSnapshotToCurrentFolder(
                payload,
                sourceURL: source.url,
                folder: canonicalFolder,
                requireUnchangedPathMetadata: true
            )
            // Conclusive replacement evidence always wins. Confirmation may
            // bridge missing proof, never contradict evidence that the current
            // directory was created after the snapshot.
            if case .mismatch = pathEntryMatch { return .mismatch }
            if case .mismatch = fallbackMatch { return .mismatch }
            if case .unverifiable(let reason, let canTrust) = pathEntryMatch {
                return .unverifiable(reason, canTrustWithConfirmation: canTrust)
            }
            if case .unverifiable(let reason, let canTrust) = fallbackMatch {
                return .unverifiable(reason, canTrustWithConfirmation: canTrust)
            }
            switch fallbackMatch {
            case .mismatch, .unverifiable:
                preconditionFailure("handled above")
            case .matches:
                // A version-1 file remembers only a pathname. Even when the
                // selected directory's timestamps predate the snapshot, an
                // ordinary ancestor could have been replaced by a pre-existing
                // tree without changing those descendant timestamps. No local
                // metadata can prove the full path's continuity after the fact.
                return .unverifiable(
                    "this path-only v0.2 snapshot needs confirmation before its first v0.3 import",
                    canTrustWithConfirmation: true
                )
            }
        }
    }

    /// Legacy files are keyed to the spelling the user opened, which may pass
    /// through one or more symbolic links. Validate every lexical path entry
    /// before resolving the target: retargeting an ancestor link is just as
    /// capable of transferring the original folder's culls as replacing the
    /// final entry itself.
    private static func legacyPathEntryMatch(
        sourceURL: URL,
        folderURL: URL
    ) -> StateSourceMatch {
        guard let stateValues = try? sourceURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ), let stateModificationDate = stateValues.contentModificationDate else {
            return .unverifiable(
                "the state-file modification date is unavailable",
                canTrustWithConfirmation: true
            )
        }

        let components = (folderURL.standardizedFileURL.path as NSString).pathComponents
        var currentPath = "/"
        for component in components where component != "/" {
            currentPath = (currentPath as NSString).appendingPathComponent(component)
            var status = stat()
            guard currentPath.withCString({ lstat($0, &status) }) == 0 else {
                return .unverifiable(
                    "the opened path metadata is unavailable",
                    canTrustWithConfirmation: true
                )
            }
            guard mode_t(status.st_mode) & mode_t(S_IFMT) == mode_t(S_IFLNK) else {
                continue
            }
            let changedAt = Date(
                timeIntervalSince1970: TimeInterval(status.st_ctimespec.tv_sec)
                    + TimeInterval(status.st_ctimespec.tv_nsec) / 1_000_000_000
            )
            guard changedAt <= stateModificationDate else {
                return .unverifiable(
                    "a symbolic link in the opened path changed after this legacy snapshot was saved",
                    canTrustWithConfirmation: true
                )
            }
            let createdAt = Date(
                timeIntervalSince1970: TimeInterval(status.st_birthtimespec.tv_sec)
                    + TimeInterval(status.st_birthtimespec.tv_nsec) / 1_000_000_000
            )
            guard createdAt <= stateModificationDate else { return .mismatch }
        }
        return .matches
    }

    /// Older compatibility files did not persist the directory's creation
    /// date. For those snapshots, both the logical save time and the state
    /// file's filesystem mtime must be no earlier than the current directory's
    /// creation. The one-second allowance applies only to the JSON timestamp,
    /// whose legacy ISO-8601 representation truncated sub-second precision;
    /// the filesystem mtime remains an exact rapid-replacement guard.
    private static func matchFallbackSnapshotToCurrentFolder(
        _ payload: StateFile,
        sourceURL: URL,
        folder: URL,
        requireUnchangedPathMetadata: Bool
    ) -> StateSourceMatch {
        guard let currentCreationDate = directoryCreationDate(for: folder) else {
            return .unverifiable(
                "the folder creation date is unavailable",
                canTrustWithConfirmation: true
            )
        }
        if let storedTimestamp = payload.folderCreationTimestamp {
            return storedTimestamp == currentCreationDate.timeIntervalSince1970
                ? .matches
                : .mismatch
        }
        guard let stateValues = try? sourceURL.resourceValues(
            forKeys: [.contentModificationDateKey]
        ), let stateModificationDate = stateValues.contentModificationDate else {
            return .unverifiable(
                "the state-file modification date is unavailable",
                canTrustWithConfirmation: true
            )
        }
        // The folder must predate both the logical snapshot and the physical
        // state-file commit.
        guard currentCreationDate <= payload.updatedAt.addingTimeInterval(1),
              currentCreationDate <= stateModificationDate else {
            return .mismatch
        }
        // An exact resource identity already proves a rename refers to the
        // same live directory. Path-only v1 state needs the additional ctime
        // boundary to catch an unrelated pre-existing directory moved into
        // that pathname after the snapshot.
        guard requireUnchangedPathMetadata else { return .matches }
        guard let folderValues = try? folder.resourceValues(
            forKeys: [.attributeModificationDateKey]
        ), let folderAttributeModificationDate = folderValues.attributeModificationDate else {
            return .unverifiable(
                "the folder attribute-change date is unavailable",
                canTrustWithConfirmation: true
            )
        }
        guard folderAttributeModificationDate <= stateModificationDate else {
            // Child additions/removals and a directory move both advance ctime.
            // That makes this case ambiguous, not evidence that the state is
            // unrelated. Refuse automatic migration without hiding the file
            // behind a newly editable bookmark snapshot.
            return .unverifiable(
                "the folder changed after this legacy snapshot was saved",
                canTrustWithConfirmation: true
            )
        }
        return .matches
    }

    // MARK: - Internal helpers

    /// Best-effort relative path. Falls back to the absolute path if the
    /// URL is not actually rooted under `folder` — a robustness valve for
    /// callers that pass URLs from other directories.
    static func relativePath(of url: URL, under folder: URL) -> String {
        let urlPath = url.standardizedFileURL.path
        // FileManager can canonicalize enumerated children (for example,
        // /var becomes /private/var) without changing the folder URL supplied
        // by the caller. Try both root spellings so state remains relative and
        // therefore portable across a later folder rename.
        var folderPaths = Set([
            folder.standardizedFileURL.path,
            folder.standardizedFileURL.resolvingSymlinksInPath().path,
        ])
        // `resolvingSymlinksInPath()` does not consistently bridge Darwin's
        // `/tmp` ↔ `/private/tmp` and `/var` ↔ `/private/var` spellings. Add
        // those lexical aliases explicitly so a caller passing an enumerated
        // Foundation URL can never persist an absolute path as culling state.
        for path in Array(folderPaths) {
            if path.hasPrefix("/private/") {
                folderPaths.insert(String(path.dropFirst("/private".count)))
            } else if path == "/tmp" || path.hasPrefix("/tmp/")
                        || path == "/var" || path.hasPrefix("/var/")
                        || path == "/etc" || path.hasPrefix("/etc/") {
                folderPaths.insert("/private" + path)
            }
        }
        for folderPath in folderPaths {
            if urlPath == folderPath { return "" }
            let prefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
            if urlPath.hasPrefix(prefix) {
                return String(urlPath.dropFirst(prefix.count))
            }
        }
        return urlPath
    }

    private func makeStateFile(
        folder: URL,
        target: FolderTargetSnapshot
    ) -> StateFile {
        StateFile(
            version: Self.supportedVersion,
            folderPath: folder.path,
            folderIdentity: target.resourceIdentity,
            folderCreationTimestamp: target.creationDate?.timeIntervalSince1970,
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
    }

    private static func encode(_ payload: StateFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    private func persist(
        folder: URL,
        destinationURL suppliedDestinationURL: URL? = nil,
        expectedTarget suppliedExpectedTarget: FolderTargetSnapshot? = nil,
        operation: VimKeymapPersistenceFailure.Operation
    ) throws {
        Self.nextSaveRevision &+= 1
        let writeRevision = Self.nextSaveRevision
        let capturedMutationRevision = mutationRevision
        // A synchronous boundary save also supersedes UI publication from any
        // older background task that has not resumed on MainActor yet.
        latestBackgroundSaveRevision = writeRevision
        var destinationURL = suppliedDestinationURL
        do {
            let destination: (url: URL, target: FolderTargetSnapshot)
            if let suppliedDestinationURL {
                guard let suppliedExpectedTarget else {
                    throw VimKeymapError.folderContinuityMismatch(folder)
                }
                destination = (suppliedDestinationURL, suppliedExpectedTarget)
            } else {
                destination = try persistenceDestination(for: folder)
            }
            destinationURL = destination.url
            guard Self.folderTargetSnapshot(for: folder) == destination.target else {
                throw VimKeymapError.folderContinuityMismatch(folder)
            }
            let data = try Self.encode(makeStateFile(
                folder: folder,
                target: destination.target
            ))
            guard Self.folderTargetSnapshot(for: folder) == destination.target else {
                throw VimKeymapError.folderContinuityMismatch(folder)
            }
            let outcome = VimStateFileWriter.shared.writeSynchronously(
                data,
                to: destination.url,
                revision: writeRevision
            )
            switch outcome {
            case .written, .superseded:
                lastPersistenceError = nil
                if mutationRevision == capturedMutationRevision {
                    hasUnpersistedChanges = false
                }
            case .failed(let message):
                throw VimStateWriterError.writeFailed(message)
            }
        } catch {
            hasUnpersistedChanges = true
            recordPersistenceFailure(
                operation: operation,
                fileURL: destinationURL,
                error: error
            )
            throw error
        }
    }

    private func recordPersistenceFailure(
        operation: VimKeymapPersistenceFailure.Operation,
        fileURL: URL?,
        error: Error
    ) {
        recordPersistenceFailure(
            operation: operation,
            fileURL: fileURL,
            message: String(describing: error)
        )
    }

    private func recordPersistenceFailure(
        operation: VimKeymapPersistenceFailure.Operation,
        fileURL: URL?,
        message: String
    ) {
        lastPersistenceError = VimKeymapPersistenceFailure(
            operation: operation,
            fileURL: fileURL,
            message: message,
            occurredAt: Date()
        )
    }

    /// On-disk envelope. `Character` keys serialize as 1-char strings since
    /// JSON keys must be strings.
    private struct StateFile: Codable {
        let version: Int
        let folderPath: String
        let folderIdentity: String?
        let folderCreationTimestamp: Double?
        let updatedAt: Date
        let marks: [String: String]          // mark-letter -> relative path
        let colorLabels: [String: Int]       // relative path -> 0-9
        let picks: [String]                  // sorted relative paths
        let rejects: [String]                // sorted relative paths
    }

    private enum StateSourceKind: Equatable {
        case bookmark
        case resourceIdentity
        case legacyPath
    }

    private struct StateSource {
        let url: URL
        let kind: StateSourceKind
        let referenceRequiresConfirmation: Bool
    }

    private struct ValidatedStateSource {
        let source: StateSource
        let data: Data
        let payload: StateFile
        let match: StateSourceMatch
    }

    private enum StateSourceMatch {
        case matches
        case mismatch
        case unverifiable(String, canTrustWithConfirmation: Bool)
    }

    private enum FolderReferenceMatch: Equatable {
        case matches
        case mismatch
        case unverifiable
    }

    private struct FolderReferenceRegistry: Codable {
        let version: Int
        var references: [FolderReference]
    }

    private struct FolderReferenceLookup {
        let reference: FolderReference
        let requiresConfirmation: Bool
        let target: FolderTargetSnapshot
    }

    private struct FolderTargetSnapshot: Equatable {
        let canonicalPath: String
        /// Required in-session identity. Unlike Foundation resource ids these
        /// values are not persisted across restarts; they close path-replacement
        /// races even on filesystems that expose no creation/resource metadata.
        let deviceID: UInt64
        let inode: UInt64
        let resourceIdentity: String?
        let creationDate: Date?
    }

    private struct FolderReference: Codable, Equatable {
        let id: String
        var bookmarkData: Data
        var lastKnownPath: String
        var resourceIdentity: String?
        var creationDate: Date?
        var updatedAt: Date
    }
}

private enum VimStateWriteOutcome: Sendable {
    case written
    case superseded
    case failed(String)
}

/// Serializes background state-file commits and discards a late-arriving write
/// when a newer snapshot for that same folder has already won the race.
private enum VimStateWriterError: Error, LocalizedError {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let message): message
        }
    }
}

/// One serial queue coordinates asynchronous edits with synchronous lifecycle
/// flushes. A flush allocated after an edit always wins even if the edit's
/// Task has not reached the queue yet; its lower revision is then discarded.
private final class VimStateFileWriter: @unchecked Sendable {
    static let shared = VimStateFileWriter()
    private let queue = DispatchQueue(label: "com.diamondplated.latent.vim-state-writer")
    private var latestRevision: [URL: UInt64] = [:]

    func write(_ data: Data, to url: URL, revision: UInt64) async -> VimStateWriteOutcome {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: performWrite(data, to: url, revision: revision))
            }
        }
    }

    func writeSynchronously(_ data: Data, to url: URL, revision: UInt64) -> VimStateWriteOutcome {
        queue.sync { performWrite(data, to: url, revision: revision) }
    }

    private func performWrite(_ data: Data, to url: URL, revision: UInt64) -> VimStateWriteOutcome {
        guard revision > latestRevision[url, default: 0] else { return .superseded }
        latestRevision[url] = revision
        do {
            try data.write(to: url, options: .atomic)
            return .written
        } catch {
            return .failed(String(describing: error))
        }
    }
}
