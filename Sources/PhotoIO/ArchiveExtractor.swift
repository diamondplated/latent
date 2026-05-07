import Foundation

public enum ArchiveError: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case extractionFailed(URL, Int32, String)
    case toolMissing(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let ext):
            return "Unsupported archive format: \(ext). Supported: zip, tar, tar.gz/.tgz, tar.bz2/.tbz2, tar.xz/.txz."
        case .extractionFailed(let url, let code, let stderr):
            return "Extraction of \(url.lastPathComponent) failed (exit \(code)): \(stderr)"
        case .toolMissing(let tool):
            return "Required system tool not found on PATH: \(tool)"
        }
    }
}

/// Detected archive format. Each maps to a system tool that's bundled with
/// macOS — `unzip` and `tar` are both in `/usr/bin`. We deliberately do NOT
/// add support for 7z/rar to avoid third-party deps.
public enum ArchiveFormat: Sendable {
    case zip
    case tar
    case tarGz
    case tarBz2
    case tarXz

    /// Detect format from the URL's extension. Looks at compound extensions
    /// like `.tar.gz` so a `Foo.tar.gz` doesn't fall back to "tar".
    public static func detect(from url: URL) -> ArchiveFormat? {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") { return .tarGz }
        if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") || name.hasSuffix(".tbz") { return .tarBz2 }
        if name.hasSuffix(".tar.xz") || name.hasSuffix(".txz") { return .tarXz }
        if name.hasSuffix(".tar") { return .tar }
        return nil
    }

    var supportedExtensions: [String] {
        switch self {
        case .zip:    ["zip"]
        case .tar:    ["tar"]
        case .tarGz:  ["tar.gz", "tgz"]
        case .tarBz2: ["tar.bz2", "tbz2", "tbz"]
        case .tarXz:  ["tar.xz", "txz"]
        }
    }
}

/// Extracts an archive into a freshly-created temporary directory, using
/// system tools (`unzip`, `tar`) — no third-party dependencies. Designed
/// so the photo viewer can transparently treat a `.zip` of photos as if
/// it were a folder.
///
/// The caller owns the returned directory's lifetime: cleanup happens via
/// `cleanup(_:)` or by deleting the dir directly.
public actor ArchiveExtractor {
    public init() {}

    /// All supported archive extensions (compound and simple), useful for
    /// `NSOpenPanel.allowedContentTypes` and pre-flight checks.
    public static var supportedExtensions: [String] {
        ArchiveFormat.allCases.flatMap(\.supportedExtensions)
    }

    public static func isArchive(_ url: URL) -> Bool {
        ArchiveFormat.detect(from: url) != nil
    }

    /// Extract `archiveURL` into a fresh temp dir. Returns the dir URL.
    /// Throws on unrecognized format or extraction failure.
    public func extract(_ archiveURL: URL) async throws -> URL {
        guard let format = ArchiveFormat.detect(from: archiveURL) else {
            throw ArchiveError.unsupportedFormat(archiveURL.pathExtension)
        }
        let dest = try makeTempDir(for: archiveURL)

        switch format {
        case .zip:
            try await runProcess(
                tool: "/usr/bin/unzip",
                args: ["-q", archiveURL.path, "-d", dest.path],
                inputArchive: archiveURL
            )
        case .tar:
            try await runProcess(
                tool: "/usr/bin/tar",
                args: ["-xf", archiveURL.path, "-C", dest.path],
                inputArchive: archiveURL
            )
        case .tarGz:
            try await runProcess(
                tool: "/usr/bin/tar",
                args: ["-xzf", archiveURL.path, "-C", dest.path],
                inputArchive: archiveURL
            )
        case .tarBz2:
            try await runProcess(
                tool: "/usr/bin/tar",
                args: ["-xjf", archiveURL.path, "-C", dest.path],
                inputArchive: archiveURL
            )
        case .tarXz:
            try await runProcess(
                tool: "/usr/bin/tar",
                args: ["-xJf", archiveURL.path, "-C", dest.path],
                inputArchive: archiveURL
            )
        }

        return dest
    }

    /// Delete an extracted-archive directory. Errors swallowed — best effort.
    public func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Private

    private func makeTempDir(for archiveURL: URL) throws -> URL {
        let stem = archiveURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        let unique = "pv-archive-\(stem)-\(UUID().uuidString)"
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(unique, isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        return dest
    }

    private func runProcess(tool: String, args: [String], inputArchive: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw ArchiveError.toolMissing(tool)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()  // discard stdout

        try process.run()

        // Wait synchronously off the actor's executor by hopping to a Task.
        // Process.waitUntilExit() blocks the calling thread.
        await Task.detached {
            process.waitUntilExit()
        }.value

        if process.terminationStatus != 0 {
            let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let stderr = String(data: stderrData, encoding: .utf8) ?? "(no stderr)"
            throw ArchiveError.extractionFailed(inputArchive, process.terminationStatus, stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

extension ArchiveFormat: CaseIterable {
    public static let allCases: [ArchiveFormat] = [.zip, .tar, .tarGz, .tarBz2, .tarXz]
}
