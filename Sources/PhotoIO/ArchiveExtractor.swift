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
extension ArchiveFormat: CaseIterable {
    public static let allCases: [ArchiveFormat] = [.zip, .tar, .tarGz, .tarBz2, .tarXz, .rar, .sevenZip]
}
