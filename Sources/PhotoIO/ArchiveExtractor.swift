import Foundation

public enum ArchiveError: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case extractionFailed(URL, Int32, String)
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
        var extracted = false
        defer {
            if !extracted {
                try? FileManager.default.removeItem(at: dest)
            }
        }

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
        case .rar:
            // unrar isn't shipped with macOS. Search Homebrew prefixes,
            // surface a friendly error if not installed.
            guard let unrar = Self.locate(tool: "unrar") else {
                throw ArchiveError.toolMissingHomebrew(
                    tool: "unrar",
                    install: "brew install carlocab/personal/unrar  # or  brew install --cask rar"
                )
            }
            // -x: extract files with full paths; -y: assume yes; -inul: silent
            try await runProcess(tool: unrar, args: ["x", "-y", "-inul", archiveURL.path, dest.path + "/"], inputArchive: archiveURL)
        case .sevenZip:
            // 7zz is provided by Homebrew's `sevenzip` formula (the modern
            // replacement for the old `p7zip`). Names: `7zz` (sevenzip) and
            // `7z` (p7zip, deprecated). Try both.
            guard let sevenzz = Self.locate(tool: "7zz") ?? Self.locate(tool: "7z") else {
                throw ArchiveError.toolMissingHomebrew(
                    tool: "7zz",
                    install: "brew install sevenzip"
                )
            }
            // x = extract with paths, -y = assume yes, -bso0 -bsp0 = silent
            try await runProcess(tool: sevenzz, args: ["x", archiveURL.path, "-o" + dest.path, "-y", "-bso0", "-bsp0"], inputArchive: archiveURL)
        }

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

    /// Find a Homebrew-installed CLI tool by name. Returns the absolute path
    /// or nil if it's not on any of the standard paths.
    public static func locate(tool: String) -> String? {
        let fm = FileManager.default
        for prefix in homebrewSearchPaths {
            let candidate = "\(prefix)/\(tool)"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        // Last-resort: respect the user's PATH (covers atypical install
        // locations). Run /usr/bin/which to resolve.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [tool]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.availableData
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, fm.isExecutableFile(atPath: path) { return path }
            }
        } catch {
            // ignore
        }
        return nil
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

    func runProcess(tool: String, args: [String], inputArchive: URL) async throws {
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            throw ArchiveError.toolMissing(tool)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()

        let stderrHandle = stderrPipe.fileHandleForReading
        let stderrTask = Task.detached {
            (try? stderrHandle.readToEnd()) ?? Data()
        }

        // Wait synchronously off the actor's executor by hopping to a Task.
        // Process.waitUntilExit() blocks the calling thread.
        await Task.detached {
            process.waitUntilExit()
        }.value

        let stderrData = await stderrTask.value
        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8) ?? "(no stderr)"
            throw ArchiveError.extractionFailed(inputArchive, process.terminationStatus, stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

extension ArchiveFormat: CaseIterable {
    public static let allCases: [ArchiveFormat] = [.zip, .tar, .tarGz, .tarBz2, .tarXz, .rar, .sevenZip]
}
