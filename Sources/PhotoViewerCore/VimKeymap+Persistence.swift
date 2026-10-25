import Foundation
import CryptoKit
import Darwin

// Saving and loading culling state, including legacy-format migration.

@MainActor
extension VimKeymap {
    // MARK: - Save and load

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

    static func matchStateSourceToCurrentFolder(
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
    static func legacyPathEntryMatch(
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
    static func matchFallbackSnapshotToCurrentFolder(
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
}
