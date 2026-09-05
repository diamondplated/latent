import Darwin
import CoreServices
import Foundation

public enum ArchiveError: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case extractionFailed(URL, Int32, String)
    case unsafeArchive(URL, String)
    case resourceLimitExceeded(URL, String)
    case extractionTimedOut(URL, TimeInterval)
    case toolMissing(String)
    /// Format requires a Homebrew-installed CLI. Includes the install command
    /// so the UI can show a copy-pasteable hint.
    case toolMissingHomebrew(tool: String, install: String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported archive format: \(ext). Supported: zip, tar, tar.gz/.tgz, tar.bz2/.tbz2, tar.xz/.txz, rar, 7z."
        case .extractionFailed(let url, let code, let stderr):
            return "Extraction of \(url.lastPathComponent) failed (exit \(code)): \(stderr)"
        case .unsafeArchive(let url, let reason):
            return "Refused unsafe archive \(url.lastPathComponent): \(reason)"
        case .resourceLimitExceeded(let url, let reason):
            return "Archive \(url.lastPathComponent) exceeds the extraction safety limit: \(reason)"
        case .extractionTimedOut(let url, let seconds):
            return "Extraction of \(url.lastPathComponent) timed out after \(Int(seconds.rounded())) seconds."
        case .toolMissing(let tool):
            return "Required system tool not found on PATH: \(tool)"
        case .toolMissingHomebrew(let tool, let install):
            return """
            \(tool) isn't installed. macOS doesn't bundle it; install via Homebrew:

                \(install)

            Then re-open the archive.
            """
        }
    }
}

/// Resource ceilings applied before, during and after extraction. The defaults
/// are deliberately generous for photo/video collections while still bounding
/// archive bombs, pathological member lists and hung helper processes.
public struct ArchiveExtractionLimits: Sendable {
    public let maximumEntries: Int
    public let maximumExpandedBytes: Int64
    public let maximumSingleFileBytes: Int64
    public let maximumListingBytes: Int
    public let maximumPathBytes: Int
    public let maximumDiagnosticBytes: Int
    public let timeout: TimeInterval
    public let pollInterval: TimeInterval

    public init(
        maximumEntries: Int = 100_000,
        maximumExpandedBytes: Int64 = 100 * 1_024 * 1_024 * 1_024,
        maximumSingleFileBytes: Int64 = 50 * 1_024 * 1_024 * 1_024,
        maximumListingBytes: Int = 32 * 1_024 * 1_024,
        maximumPathBytes: Int = 4_096,
        maximumDiagnosticBytes: Int = 64 * 1_024,
        timeout: TimeInterval = 30 * 60,
        pollInterval: TimeInterval = 0.25
    ) {
        precondition(maximumEntries > 0)
        precondition(maximumExpandedBytes >= 0)
        precondition(maximumSingleFileBytes >= 0)
        precondition(maximumListingBytes > 0)
        precondition(maximumPathBytes > 0)
        precondition(maximumDiagnosticBytes > 0)
        precondition(timeout > 0)
        precondition(pollInterval > 0)

        self.maximumEntries = maximumEntries
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumSingleFileBytes = maximumSingleFileBytes
        self.maximumListingBytes = maximumListingBytes
        self.maximumPathBytes = maximumPathBytes
        self.maximumDiagnosticBytes = maximumDiagnosticBytes
        self.timeout = timeout
        self.pollInterval = pollInterval
    }
}

/// Detected archive format. zip + tar variants use macOS-bundled tools
/// (/usr/bin/unzip, /usr/bin/tar). RAR and 7z need Homebrew-installed tools
/// — we detect at runtime and surface a clear "install via brew" error.
public enum ArchiveFormat: Sendable {
    case zip
    case tar
    case tarGz
    case tarBz2
    case tarXz
    case rar
    case sevenZip

    /// Detect format from the URL's extension. Looks at compound extensions
    /// like `.tar.gz` so a `Foo.tar.gz` doesn't fall back to "tar".
    public static func detect(from url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") || name.hasSuffix(".tbz") { return .tarBz2 }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .tarXz }
        if name.hasSuffix(".tar") { return .tar }
        if name.hasSuffix(".rar") { return .rar }
        if name.hasSuffix(".7z") { return .sevenZip }
        return nil
    }

    var supportedExtensions: [String] {
        switch self {
        case .zip:      ["zip"]
        case .tar:      ["tar"]
        case .tarGz:    ["tar.gz", "tgz"]
        case .tarBz2:   ["tar.bz2", "tbz2", "tbz"]
        case .tarXz:    ["tar.xz", "txz"]
        case .rar:      ["rar"]
        case .sevenZip: ["7z"]
        }
    }
}

/// Extracts an archive into a freshly-created temporary directory. Archive
/// member names are inspected before extraction, and the resulting directory
/// is monitored and validated against traversal, symlink and resource attacks.
///
/// The caller owns the returned directory's lifetime: cleanup happens via
/// `cleanup(_:)` or by deleting the dir directly.
public actor ArchiveExtractor {
    private let limits: ArchiveExtractionLimits

    public init(limits: ArchiveExtractionLimits = ArchiveExtractionLimits()) {
        self.limits = limits
    }

    /// All supported archive extensions (compound and simple), useful for
    /// `NSOpenPanel.allowedContentTypes` and pre-flight checks.
    public static var supportedExtensions: [String] {
        ArchiveFormat.allCases.flatMap(\.supportedExtensions)
    }

    public static func isArchive(_ url: URL) -> Bool {
        ArchiveFormat.detect(from: url) != nil
    }

    /// Extract `archiveURL` into a fresh temp dir. Returns the dir URL.
    /// Throws on unrecognized formats, unsafe contents, timeout, cancellation,
    /// resource-limit violations or extraction failure.
    public func extract(_ archiveURL: URL) async throws -> URL {
        guard let format = ArchiveFormat.detect(from: archiveURL) else {
            throw ArchiveError.unsupportedFormat(archiveURL.pathExtension)
        }

        let invocation = try makeInvocation(for: format, archiveURL: archiveURL)
        try await preflight(invocation: invocation, archiveURL: archiveURL)
        try Task.checkCancellation()

        let dest = try makeTempDir(for: archiveURL)
        var extracted = false
        defer {
            if !extracted {
                try? FileManager.default.removeItem(at: dest)
            }
        }

        _ = try await runTool(
            tool: invocation.tool,
            args: invocation.extractionArguments,
            inputArchive: archiveURL,
            destination: dest,
            stdoutLimit: nil
        )
        try validateExtractedTree(at: dest, archiveURL: archiveURL, strict: true)
        try Task.checkCancellation()

        extracted = true
        return dest
    }

    // MARK: - Tool location

    private static let homebrewSearchPaths = [
        "/opt/homebrew/bin",        // Apple Silicon brew
        "/usr/local/bin",           // Intel brew
        "/opt/local/bin",           // MacPorts
        "/usr/local/sbin",
    ]

    /// Find a package-manager-installed CLI tool by name. Only fixed,
    /// reviewable locations are accepted; an arbitrary executable injected
    /// earlier in PATH must never become an archive parser implicitly.
    public static func locate(tool: String) -> String? {
        let fm = FileManager.default
        for prefix in homebrewSearchPaths {
            let candidate = "\(prefix)/\(tool)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Delete an extracted-archive directory. Errors swallowed — best effort.
    public func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Archive inspection

    private enum ListingStyle: Equatable {
        case onePathPerLine
        case sevenZipTechnical
    }

    private struct ToolInvocation {
        let tool: String
        let listingArguments: [String]
        let extractionArguments: [String]
        let listingStyle: ListingStyle
    }

    private func makeInvocation(for format: ArchiveFormat, archiveURL: URL) throws -> ToolInvocation {
        switch format {
        case .zip:
            return ToolInvocation(
                tool: "/usr/bin/unzip",
                listingArguments: ["-Z1", archiveURL.path],
                extractionArguments: ["-q", archiveURL.path, "-d", "DESTINATION"],
                listingStyle: .onePathPerLine
            )
        case .tar, .tarGz, .tarBz2, .tarXz:
            // bsdtar auto-detects compression while listing. Extraction keeps
            // explicit flags so behavior remains consistent with prior builds.
            let extractFlag: String
            switch format {
            case .tar: extractFlag = "-xf"
            case .tarGz: extractFlag = "-xzf"
            case .tarBz2: extractFlag = "-xjf"
            case .tarXz: extractFlag = "-xJf"
            default: fatalError("unreachable")
            }
            return ToolInvocation(
                tool: "/usr/bin/tar",
                listingArguments: ["-tf", archiveURL.path],
                extractionArguments: [extractFlag, archiveURL.path, "-C", "DESTINATION"],
                listingStyle: .onePathPerLine
            )
        case .rar:
            guard let unrar = Self.locate(tool: "unrar") else {
                throw ArchiveError.toolMissingHomebrew(
                    tool: "unrar",
                    install: "brew install carlocab/personal/unrar  # or  brew install --cask rar"
                )
            }
            return ToolInvocation(
                tool: unrar,
                listingArguments: ["lb", "-p-", archiveURL.path],
                extractionArguments: ["x", "-y", "-inul", archiveURL.path, "DESTINATION/"],
                listingStyle: .onePathPerLine
            )
        case .sevenZip:
            guard let sevenzz = Self.locate(tool: "7zz") ?? Self.locate(tool: "7z") else {
                throw ArchiveError.toolMissingHomebrew(
                    tool: "7zz",
                    install: "brew install sevenzip"
                )
            }
            return ToolInvocation(
                tool: sevenzz,
                listingArguments: ["l", "-slt", "-p-", archiveURL.path],
                extractionArguments: ["x", archiveURL.path, "-oDESTINATION", "-y", "-bso0", "-bsp0"],
                listingStyle: .sevenZipTechnical
            )
        }
    }

    private func preflight(invocation: ToolInvocation, archiveURL: URL) async throws {
        let result = try await runTool(
            tool: invocation.tool,
            args: invocation.listingArguments,
            inputArchive: archiveURL,
            destination: nil,
            stdoutLimit: limits.maximumListingBytes
        )
        guard !result.stdout.truncated else {
            throw ArchiveError.resourceLimitExceeded(
                archiveURL,
                "member listing is larger than \(limits.maximumListingBytes) bytes"
            )
        }
        guard let listing = String(data: result.stdout.data, encoding: .utf8) else {
            throw ArchiveError.unsafeArchive(archiveURL, "member listing is not valid UTF-8")
        }

        let candidates: [String]
        switch invocation.listingStyle {
        case .onePathPerLine:
            candidates = listing.split(separator: "\n", omittingEmptySubsequences: true).map {
                String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }
        case .sevenZipTechnical:
            candidates = listing.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
                let line = String(line).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                let prefix = "Path = "
                guard line.hasPrefix(prefix) else { return nil }
                return String(line.dropFirst(prefix.count))
            }
        }

        var memberCount = 0
        for path in candidates {
            // 7-Zip's technical listing includes one metadata record for the
            // archive itself before its member records.
            if invocation.listingStyle == .sevenZipTechnical,
               Self.listedPath(path, identifies: archiveURL) {
                continue
            }
            memberCount += 1
            guard memberCount <= limits.maximumEntries else {
                throw ArchiveError.resourceLimitExceeded(
                    archiveURL,
                    "more than \(limits.maximumEntries) members"
                )
            }
            try Self.validateMemberPath(path, archiveURL: archiveURL, maximumBytes: limits.maximumPathBytes)
        }
    }

    private static func listedPath(_ path: String, identifies archiveURL: URL) -> Bool {
        if path == archiveURL.path { return true }
        guard path.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL == archiveURL.standardizedFileURL
    }

    static func validateMemberPath(_ path: String, archiveURL: URL, maximumBytes: Int = 4_096) throws {
        guard !path.isEmpty else {
            throw ArchiveError.unsafeArchive(archiveURL, "an archive member has an empty path")
        }
        guard path.utf8.count <= maximumBytes else {
            throw ArchiveError.resourceLimitExceeded(
                archiveURL,
                "member path is longer than \(maximumBytes) bytes"
            )
        }
        if path.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7f }) {
            throw ArchiveError.unsafeArchive(archiveURL, "member path contains control characters")
        }

        // Backslashes are separators for some archive tools even on macOS, so
        // validate both POSIX and Windows spellings conservatively.
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") {
            throw ArchiveError.unsafeArchive(archiveURL, "absolute member path: \(path)")
        }
        if normalized.count >= 2 {
            let chars = Array(normalized.prefix(2))
            if chars[0].isLetter && chars[1] == ":" {
                throw ArchiveError.unsafeArchive(archiveURL, "drive-qualified member path: \(path)")
            }
        }
        if normalized.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
            throw ArchiveError.unsafeArchive(archiveURL, "parent traversal in member path: \(path)")
        }
    }

    private func validateExtractedTree(at root: URL, archiveURL: URL, strict: Bool) throws {
        let ledger = ExtractedTreeLedger(root: root, archiveURL: archiveURL, limits: limits)
        try ledger.replaceWithFullScan(strict: strict)
    }

    private static func isContained(_ candidate: String, by root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root + "/")
    }

    // MARK: - Process execution

    private struct ToolResult {
        let stdout: BoundedDataCollector.Snapshot
    }

    /// Internal entry point retained for focused process-runner tests.
    func runProcess(tool: String, args: [String], inputArchive: URL) async throws {
        _ = try await runTool(
            tool: tool,
            args: args,
            inputArchive: inputArchive,
            destination: nil,
            stdoutLimit: nil
        )
    }

    private func runTool(
        tool: String,
        args: [String],
        inputArchive: URL,
        destination: URL?,
        stdoutLimit: Int?
    ) async throws -> ToolResult {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw ArchiveError.toolMissing(tool)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = destination.map { destination in
            args.map { argument in
                switch argument {
                case "DESTINATION": destination.path
                case "DESTINATION/": destination.path + "/"
                case "-oDESTINATION": "-o" + destination.path
                default: argument
                }
            }
        } ?? args
        var environment = ProcessInfo.processInfo.environment
        // Info-ZIP and some tar implementations accept implicit options from
        // environment variables. Ignore them so the inspected and extracted
        // command lines are exactly the ones constructed above.
        for key in ["UNZIP", "UNZIPOPT", "ZIPINFO", "TAR_OPTIONS"] {
            environment.removeValue(forKey: key)
        }
        for key in Array(environment.keys) where key.hasPrefix("DYLD_") || key.hasPrefix("LD_") {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin"
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        let stderrCollector = BoundedDataCollector(limit: limits.maximumDiagnosticBytes)
        process.standardError = stderrPipe

        let stdoutPipe: Pipe?
        let stdoutCollector: BoundedDataCollector
        if let stdoutLimit {
            let pipe = Pipe()
            stdoutPipe = pipe
            stdoutCollector = BoundedDataCollector(limit: stdoutLimit)
            process.standardOutput = pipe
        } else {
            stdoutPipe = nil
            stdoutCollector = BoundedDataCollector(limit: 1)
            process.standardOutput = FileHandle.nullDevice
        }

        // Watch extraction changes at file granularity instead of recursively
        // walking an ever-growing tree every poll. The event ledger performs
        // O(1) work for ordinary file writes/creates and one subtree scan for
        // a newly-observed directory. FSEvents explicitly marks dropped or
        // hierarchically coalesced batches, where a full reconciliation is the
        // safe fallback. A final strict scan still gates a successful result.
        let treeMonitor: ExtractedTreeEventMonitor?
        if let destination {
            let monitor = ExtractedTreeEventMonitor(
                root: destination,
                archiveURL: inputArchive,
                limits: limits
            )
            try monitor.start()
            treeMonitor = monitor
        } else {
            treeMonitor = nil
        }

        do {
            try process.run()
        } catch {
            treeMonitor?.stop(flushPendingEvents: false)
            throw error
        }
        let processBox = SendableProcess(process)
        let stderrTask = Self.startDraining(stderrPipe.fileHandleForReading, into: stderrCollector)
        let stdoutTask = stdoutPipe.map {
            Self.startDraining($0.fileHandleForReading, into: stdoutCollector)
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(limits.timeout))
        let pollSeconds = min(limits.pollInterval, limits.timeout)
        let pollNanoseconds = UInt64((pollSeconds * 1_000_000_000).rounded())

        do {
            while process.isRunning {
                try Task.checkCancellation()
                if clock.now >= deadline {
                    throw ArchiveError.extractionTimedOut(inputArchive, limits.timeout)
                }
                try treeMonitor?.checkForFailure()
                try await Task.sleep(nanoseconds: pollNanoseconds)
            }
        } catch {
            await Self.terminateAndWait(processBox)
            treeMonitor?.stop(flushPendingEvents: false)
            await stderrTask.value
            await stdoutTask?.value
            if error is CancellationError {
                throw CancellationError()
            }
            throw error
        }

        await stderrTask.value
        await stdoutTask?.value
        treeMonitor?.stop(flushPendingEvents: true)
        try treeMonitor?.checkForFailure()
        try Task.checkCancellation()

        if process.terminationStatus != 0 {
            throw ArchiveError.extractionFailed(
                inputArchive,
                process.terminationStatus,
                stderrCollector.diagnosticString()
            )
        }
        return ToolResult(stdout: stdoutCollector.snapshot())
    }

    private static func startDraining(
        _ handle: FileHandle,
        into collector: BoundedDataCollector
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while true {
                do {
                    guard let chunk = try handle.read(upToCount: 8_192), !chunk.isEmpty else { break }
                    collector.append(chunk)
                } catch {
                    break
                }
            }
            try? handle.close()
        }
    }

    private static func terminateAndWait(_ processBox: SendableProcess) async {
        await Task.detached(priority: .utility) {
            let process = processBox.process
            if process.isRunning {
                process.terminate()
            }
            var attempts = 0
            while process.isRunning, attempts < 40 {
                usleep(50_000)
                attempts += 1
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            if process.isRunning {
                process.waitUntilExit()
            }
        }.value
    }

    // MARK: - Temporary directory

    private func makeTempDir(for archiveURL: URL) throws -> URL {
        // Keep the component fixed-width and independent of an untrusted input
        // filename. A near-NAME_MAX archive name plus our UUID otherwise makes
        // creation fail before extraction even begins.
        _ = archiveURL
        let unique = "pv-archive-\(UUID().uuidString)"
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dest,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dest
    }
}

/// A current, conservative accounting of one extraction directory. Ordinary
/// FSEvent updates touch only the changed entry. Full replacement scans are
/// reserved for startup, the final strict validation, and FSEvents' explicit
/// `MustScanSubDirs` recovery signal.
private final class ExtractedTreeLedger {
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

/// File-level FSEvents monitoring makes extraction validation proportional to
/// changed paths instead of `entryCount * pollCount`. A dropped/coalesced event
/// batch requests a full ledger rebuild, which is the documented safe recovery
/// path and not the steady-state behavior.
private final class ExtractedTreeEventMonitor: @unchecked Sendable {
    private let ledger: ExtractedTreeLedger
    private let archiveURL: URL
    private let latency: CFTimeInterval
    private let callbackQueue = DispatchQueue(label: "com.diamondplated.latent.archive-monitor", qos: .utility)
    private let stateLock = NSLock()
    private var failure: Error?
    private var stream: FSEventStreamRef?

    init(root: URL, archiveURL: URL, limits: ArchiveExtractionLimits) {
        self.ledger = ExtractedTreeLedger(root: root, archiveURL: archiveURL, limits: limits)
        self.archiveURL = archiveURL
        self.latency = max(0.05, min(limits.pollInterval, 0.25))
    }

    func start() throws {
        try ledger.replaceWithFullScan(strict: false)

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagFileEvents
        )
        guard let newStream = FSEventStreamCreate(
            kCFAllocatorDefault,
            archiveTreeEventCallback,
            &context,
            [ledger.rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            throw ArchiveError.unsafeArchive(
                archiveURL,
                "could not start extraction safety monitoring"
            )
        }

        stream = newStream
        FSEventStreamSetDispatchQueue(newStream, callbackQueue)
        guard FSEventStreamStart(newStream) else {
            FSEventStreamSetDispatchQueue(newStream, nil)
            FSEventStreamInvalidate(newStream)
            FSEventStreamRelease(newStream)
            stream = nil
            throw ArchiveError.unsafeArchive(
                archiveURL,
                "could not start extraction safety monitoring"
            )
        }
    }

    func checkForFailure() throws {
        stateLock.lock()
        let currentFailure = failure
        stateLock.unlock()
        if let currentFailure { throw currentFailure }
    }

    func stop(flushPendingEvents: Bool) {
        guard let stream else { return }
        if flushPendingEvents {
            FSEventStreamFlushSync(stream)
        }
        FSEventStreamStop(stream)
        FSEventStreamSetDispatchQueue(stream, nil)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil

        // The context pointer is unretained, so ensure every callback that was
        // already submitted has returned before this monitor can be released.
        callbackQueue.sync {}
    }

    fileprivate func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
        do {
            if flags.contains(where: {
                $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
                    || $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagMount) != 0
                    || $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagUnmount) != 0
            }) {
                throw ArchiveError.unsafeArchive(
                    archiveURL,
                    "the extraction directory changed while it was being monitored"
                )
            }

            if flags.contains(where: {
                $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            }) {
                try ledger.replaceWithFullScan(strict: false)
                return
            }

            // Parents first: if a whole new hierarchy arrives in one batch,
            // its first subtree scan records descendants before their events.
            let orderedPaths = Set(paths).sorted {
                let lhsDepth = $0.utf8.reduce(into: 0) { if $1 == 47 { $0 += 1 } }
                let rhsDepth = $1.utf8.reduce(into: 0) { if $1 == 47 { $0 += 1 } }
                return lhsDepth == rhsDepth ? $0 < $1 : lhsDepth < rhsDepth
            }
            for path in orderedPaths {
                if try ledger.reconcile(path: path) {
                    try ledger.addInitialContents(ofDirectoryAt: path)
                }
            }
            // Validate aggregate limits after the entire batch is reconciled.
            // Rename events can arrive new-path-first; checking each mutation
            // would briefly double-count the same file and reject safe archives.
            try ledger.validateCurrentTotals()
        } catch {
            recordFailure(error)
        }
    }

    private func recordFailure(_ error: Error) {
        stateLock.lock()
        if failure == nil { failure = error }
        stateLock.unlock()
    }
}

private func archiveTreeEventCallback(
    _ stream: ConstFSEventStreamRef,
    _ clientInfo: UnsafeMutableRawPointer?,
    _ eventCount: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
    _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
    _ = stream
    _ = eventIDs
    guard let clientInfo else { return }
    let monitor = Unmanaged<ExtractedTreeEventMonitor>.fromOpaque(clientInfo).takeUnretainedValue()
    let pathArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
    var paths: [String] = []
    var flags: [FSEventStreamEventFlags] = []
    paths.reserveCapacity(eventCount)
    flags.reserveCapacity(eventCount)
    for index in 0..<eventCount {
        guard let rawPath = CFArrayGetValueAtIndex(pathArray, index) else { continue }
        let path = unsafeBitCast(rawPath, to: CFString.self) as String
        paths.append(path)
        flags.append(eventFlags[index])
    }
    monitor.receive(paths: paths, flags: flags)
}

private final class SendableProcess: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class BoundedDataCollector: @unchecked Sendable {
    struct Snapshot: Sendable {
        let data: Data
        let truncated: Bool
    }

    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var truncated = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, limit - data.count)
        if remaining > 0 {
            data.append(contentsOf: chunk.prefix(remaining))
        }
        if chunk.count > remaining {
            truncated = true
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(data: data, truncated: truncated)
    }

    func diagnosticString() -> String {
        let snapshot = snapshot()
        var message = String(decoding: snapshot.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if snapshot.truncated {
            message += message.isEmpty ? "[diagnostic output truncated]" : "\n[diagnostic output truncated]"
        }
        return message.isEmpty ? "(no stderr)" : message
    }
}

extension ArchiveFormat: CaseIterable {
    public static let allCases: [ArchiveFormat] = [.zip, .tar, .tarGz, .tarBz2, .tarXz, .rar, .sevenZip]
}
