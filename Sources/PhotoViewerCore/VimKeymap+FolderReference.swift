import Foundation
import CryptoKit
import Darwin

// State-file locations and the folder-reference registry: resolving a
// folder to the bookmark-backed reference that survives renames and moves.

@MainActor
extension VimKeymap {
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

    static func referenceStateFileURL(referenceID: String, in base: URL) -> URL {
        base.appendingPathComponent("folder-reference-\(referenceID).json")
    }

    static func resourceIdentityStateFileURL(identity: String, in base: URL) -> URL {
        base.appendingPathComponent("folder-\(identity).json")
    }

    static func stateDirectoryURL() throws -> URL {
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

    static func pathHash(for folderURL: URL) -> String {
        SHA256.hash(data: Data(folderURL.path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func canonicalFolderURL(_ folderURL: URL) -> URL {
        folderURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static func folderTargetSnapshot(for folderURL: URL) -> FolderTargetSnapshot? {
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

    static func folderReference(
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

    static func folderReferenceUnlocked(
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
    static func commitFolderReference(
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
    static func createMigrationFolderReference(
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

    static func exactFolderReferenceLookup(
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
}
