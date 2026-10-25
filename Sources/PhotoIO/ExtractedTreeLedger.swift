import Darwin
import CoreServices
import Foundation

/// A current, conservative accounting of one extraction directory. Ordinary
/// FSEvent updates touch only the changed entry. Full replacement scans are
/// reserved for startup, the final strict validation, and FSEvents' explicit
/// `MustScanSubDirs` recovery signal.
final class ExtractedTreeLedger {
    private enum EntryKind {
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    private struct Entry {
        let kind: EntryKind
        let byteCount: Int64
    }

    let rootPath: String

    private let root: URL
    private let archiveURL: URL
    private let limits: ArchiveExtractionLimits
    private var entries: [String: Entry] = [:]
    private var expandedBytes: Int64 = 0

    init(root: URL, archiveURL: URL, limits: ArchiveExtractionLimits) {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        self.root = canonicalRoot
        self.rootPath = canonicalRoot.path
        self.archiveURL = archiveURL
        self.limits = limits
    }

    func replaceWithFullScan(strict: Bool) throws {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw ArchiveError.unsafeArchive(archiveURL, "could not inspect extracted contents")
        }

        var replacement: [String: Entry] = [:]
        var replacementBytes: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            guard let (relativePath, entry) = try inspect(url: url, strict: strict) else {
                continue
            }
            try validateAdding(
                relativePath: relativePath,
                entry: entry,
                toCount: replacement.count,
                expandedBytes: replacementBytes
            )
            replacement[relativePath] = entry
            replacementBytes += entry.byteCount
        }

        if strict, let enumerationError {
            throw ArchiveError.unsafeArchive(
                archiveURL,
                "could not enumerate extracted contents: \(enumerationError.localizedDescription)"
            )
        }
        entries = replacement
        expandedBytes = replacementBytes
    }

    /// Reconcile one file-level FSEvent. Returns whether the path is a newly
    /// observed directory whose already-created children need one initial scan.
    func reconcile(path: String) throws -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let relativePath = try relativePath(for: url) else {
            return false // The extraction root itself is not an archive member.
        }

        let prior = entries[relativePath]
        guard let (_, current) = try inspect(url: url, strict: false) else {
            remove(relativePath: relativePath, includingDescendants: prior?.kind == .directory)
            return false
        }

        try validateSingleFile(relativePath: relativePath, entry: current)
        let priorBytes = prior?.byteCount ?? 0
        entries[relativePath] = current
        expandedBytes = expandedBytes - priorBytes + current.byteCount
        return prior == nil && current.kind == .directory
    }

    /// Scan a directory only when it first appears. Sorting event paths by
    /// depth means a parent is registered before later child events in the same
    /// callback, preventing nested create batches from triggering repeat scans.
    func addInitialContents(ofDirectoryAt path: String) throws {
        let directory = URL(fileURLWithPath: path)
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            // The directory may have been renamed or removed again before its
            // event was delivered. A later event or final scan reconciles it.
            return
        }

        while let child = enumerator.nextObject() as? URL {
            guard let (relativePath, entry) = try inspect(url: child, strict: false) else {
                continue
            }
            let prior = entries[relativePath]
            let priorBytes = prior?.byteCount ?? 0
            try validateSingleFile(relativePath: relativePath, entry: entry)
            entries[relativePath] = entry
            expandedBytes = expandedBytes - priorBytes + entry.byteCount
        }

        // During extraction, a disappearing path is an expected race. Other
        // enumeration failures are unsafe because they would make accounting
        // incomplete.
        if let enumerationError {
            let nsError = enumerationError as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSFileNoSuchFileError {
                throw ArchiveError.unsafeArchive(
                    archiveURL,
                    "could not enumerate new extraction directory: \(enumerationError.localizedDescription)"
                )
            }
        }
    }

    private func inspect(url: URL, strict: Bool) throws -> (String, Entry)? {
        guard let relativePath = try relativePath(for: url) else { return nil }

        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            if !strict, errno == ENOENT || errno == ENOTDIR {
                return nil
            }
            throw ArchiveError.unsafeArchive(
                archiveURL,
                "could not inspect \(relativePath): \(String(cString: strerror(errno)))"
            )
        }

        let fileType = status.st_mode & mode_t(S_IFMT)
        switch fileType {
        case mode_t(S_IFDIR):
            try validateResolvedContainment(of: url, relativePath: relativePath)
            return (relativePath, Entry(kind: .directory, byteCount: 0))
        case mode_t(S_IFREG):
            try validateResolvedContainment(of: url, relativePath: relativePath)
            return (relativePath, Entry(kind: .regularFile, byteCount: max(0, Int64(status.st_size))))
        case mode_t(S_IFLNK):
            do {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                let targetURL: URL
                if target.hasPrefix("/") {
                    targetURL = URL(fileURLWithPath: target)
                } else {
                    targetURL = url.deletingLastPathComponent().appendingPathComponent(target)
                }
                let resolvedTarget = targetURL.standardizedFileURL
                    .resolvingSymlinksInPath().standardizedFileURL.path
                guard Self.isContained(resolvedTarget, by: rootPath) else {
                    throw ArchiveError.unsafeArchive(
                        archiveURL,
                        "symbolic link escapes extraction root: \(relativePath) -> \(target)"
                    )
                }
            } catch let error as ArchiveError {
                throw error
            } catch {
                throw ArchiveError.unsafeArchive(
                    archiveURL,
                    "could not inspect symbolic link \(relativePath): \(error.localizedDescription)"
                )
            }
            return (relativePath, Entry(kind: .symbolicLink, byteCount: 0))
        default:
            if strict {
                throw ArchiveError.unsafeArchive(
                    archiveURL,
                    "unsupported special file in archive: \(relativePath)"
                )
            }
            return (relativePath, Entry(kind: .other, byteCount: 0))
        }
    }

    private func relativePath(for url: URL) throws -> String? {
        let lexicalPath = url.standardizedFileURL.path
        guard Self.isContained(lexicalPath, by: rootPath) else {
            throw ArchiveError.unsafeArchive(
                archiveURL,
                "extracted path escaped its temporary directory"
            )
        }
        guard lexicalPath != rootPath else { return nil }
        let relativePath = String(lexicalPath.dropFirst(rootPath.count + 1))
        guard relativePath.utf8.count <= limits.maximumPathBytes else {
            throw ArchiveError.resourceLimitExceeded(
                archiveURL,
                "extracted path is longer than \(limits.maximumPathBytes) bytes"
            )
        }
        return relativePath
    }

    private func validateResolvedContainment(of url: URL, relativePath: String) throws {
        let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard Self.isContained(resolvedPath, by: rootPath) else {
            throw ArchiveError.unsafeArchive(
                archiveURL,
                "extracted path resolves outside its temporary directory: \(relativePath)"
            )
        }
    }

    private func validateAdding(
        relativePath: String,
        entry: Entry,
        toCount existingCount: Int,
        expandedBytes existingBytes: Int64
    ) throws {
        guard existingCount < limits.maximumEntries else {
            throw ArchiveError.resourceLimitExceeded(
                archiveURL,
                "more than \(limits.maximumEntries) extracted entries"
            )
        }
        try validateSingleFile(relativePath: relativePath, entry: entry)
        guard entry.byteCount <= limits.maximumExpandedBytes - existingBytes else {
            throw ArchiveError.resourceLimitExceeded(
                archiveURL,
                "expanded contents exceed \(limits.maximumExpandedBytes) bytes"
            )
        }
    }

    func validateCurrentTotals() throws {
        guard entries.count <= limits.maximumEntries else {
            throw ArchiveError.resourceLimitExceeded(
                archiveURL,
                "more than \(limits.maximumEntries) extracted entries"
            )
        }
        guard expandedBytes <= limits.maximumExpandedBytes else {
            throw ArchiveError.resourceLimitExceeded(
                archiveURL,
                "expanded contents exceed \(limits.maximumExpandedBytes) bytes"
            )
        }
    }

    private func validateSingleFile(relativePath: String, entry: Entry) throws {
        guard entry.byteCount <= limits.maximumSingleFileBytes else {
            throw ArchiveError.resourceLimitExceeded(
                archiveURL,
                "\(relativePath) is \(entry.byteCount) bytes (limit \(limits.maximumSingleFileBytes))"
            )
        }
    }

    private func remove(relativePath: String, includingDescendants: Bool) {
        if let removed = entries.removeValue(forKey: relativePath) {
            expandedBytes -= removed.byteCount
        }
        guard includingDescendants else { return }
        let prefix = relativePath + "/"
        let descendantKeys = entries.keys.filter { $0.hasPrefix(prefix) }
        for key in descendantKeys {
            if let removed = entries.removeValue(forKey: key) {
                expandedBytes -= removed.byteCount
            }
        }
    }

    private static func isContained(_ candidate: String, by root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }
}
