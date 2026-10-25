import Foundation
import CryptoKit
import Darwin

// Matching a saved reference back to a live folder, and the registry's
// on-disk I/O and locking.

@MainActor
extension VimKeymap {
    /// Resolve a save against this keymap's accepted folder incarnation. This
    /// may register a fresh programmatic keymap on its first save, but every
    /// later write addresses that exact reference id.
    func persistenceDestination(
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

    static func referenceMatches(_ reference: FolderReference, folderURL: URL) -> Bool {
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

    static func resolvedReferenceMatch(
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

    static func metadataReferenceMatch(
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

    static func datesIdentifySameDirectory(_ lhs: Date, _ rhs: Date) -> Bool {
        lhs == rhs
    }

    static func directoryCreationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    static func pathsReferToSameFolder(_ lhs: String?, _ rhs: String) -> Bool {
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
    static func pathsHaveSameLexicalLocation(_ lhs: String?, _ rhs: String) -> Bool {
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

    static func makeBookmark(for folderURL: URL) throws -> Data {
        try folderURL.bookmarkData(
            options: [],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
    }

    static func resolveFolderReference(
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

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func loadFolderReferenceRegistry(in base: URL) throws -> FolderReferenceRegistry {
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

    static func saveFolderReferenceRegistry(
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
    static func withRegistryLock<T>(
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

    static func removeItemIfPresent(at url: URL) throws {
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

    static func opaqueIdentifierData(_ identifier: Any) -> Data? {
        if let data = identifier as? Data {
            return data
        }
        return try? NSKeyedArchiver.archivedData(
            withRootObject: identifier,
            requiringSecureCoding: true
        )
    }
}
