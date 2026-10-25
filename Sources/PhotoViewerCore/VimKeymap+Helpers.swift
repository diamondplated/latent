import Foundation
import CryptoKit
import Darwin

@MainActor
extension VimKeymap {
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

    func makeStateFile(
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

    static func encode(_ payload: StateFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    func persist(
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

    func recordPersistenceFailure(
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

    func recordPersistenceFailure(
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
    struct StateFile: Codable {
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

    enum StateSourceKind: Equatable {
        case bookmark
        case resourceIdentity
        case legacyPath
    }

    struct StateSource {
        let url: URL
        let kind: StateSourceKind
        let referenceRequiresConfirmation: Bool
    }

    struct ValidatedStateSource {
        let source: StateSource
        let data: Data
        let payload: StateFile
        let match: StateSourceMatch
    }

    enum StateSourceMatch {
        case matches
        case mismatch
        case unverifiable(String, canTrustWithConfirmation: Bool)
    }

    enum FolderReferenceMatch: Equatable {
        case matches
        case mismatch
        case unverifiable
    }

    struct FolderReferenceRegistry: Codable {
        let version: Int
        var references: [FolderReference]
    }

    struct FolderReferenceLookup {
        let reference: FolderReference
        let requiresConfirmation: Bool
        let target: FolderTargetSnapshot
    }

    struct FolderTargetSnapshot: Equatable {
        let canonicalPath: String
        /// Required in-session identity. Unlike Foundation resource ids these
        /// values are not persisted across restarts; they close path-replacement
        /// races even on filesystems that expose no creation/resource metadata.
        let deviceID: UInt64
        let inode: UInt64
        let resourceIdentity: String?
        let creationDate: Date?
    }

    struct FolderReference: Codable, Equatable {
        let id: String
        var bookmarkData: Data
        var lastKnownPath: String
        var resourceIdentity: String?
        var creationDate: Date?
        var updatedAt: Date
    }
}


enum VimStateWriteOutcome: Sendable {
    case written
    case superseded
    case failed(String)
}

/// Serializes background state-file commits and discards a late-arriving write
/// when a newer snapshot for that same folder has already won the race.
enum VimStateWriterError: Error, LocalizedError {
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
final class VimStateFileWriter: @unchecked Sendable {
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
