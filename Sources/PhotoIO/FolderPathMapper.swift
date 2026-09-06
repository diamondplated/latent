import Foundation

/// Keeps a user-selected folder's lexical spelling stable while filesystem
/// APIs operate on its resolved target.
///
/// Two Darwin behaviors make plain string-prefix checks unreliable here:
/// directory symlinks need to be enumerated through their resolved target,
/// and APIs can interchange `/tmp` with `/private/tmp` (likewise `/var` and
/// `/etc`). This mapper gives scanners and event consumers one shared view of
/// those equivalent roots without rewriting paths that are outside the folder.
public struct FolderPathMapper: Sendable {
    /// The lexically normalized URL spelling supplied by the caller.
    public let rootURL: URL

    /// The resolved target used for filesystem enumeration and directory
    /// probes. Returned children should be passed through `rebaseToRoot(_:)`.
    public let enumerationRootURL: URL

    /// `rootURL.path`, exposed for containment and direct-child comparisons.
    public var rootPath: String { rootURL.path }

    private let equivalentRootPaths: [String]

    public init(rootURL: URL) {
        // Foundation's `standardizedFileURL` consults the filesystem and can
        // silently turn an existing `/private/tmp/...` URL into `/tmp/...`.
        // Normalize dot components ourselves so the caller's spelling remains
        // stable in AppState, VimKeymap, and all URLs returned to SwiftUI.
        let lexicalPath = Self.lexicallyNormalized(rootURL.path)
        let lexicalRoot = URL(fileURLWithPath: lexicalPath, isDirectory: true)
        let resolvedPath = Self.lexicallyNormalized(
            lexicalRoot.resolvingSymlinksInPath().path
        )
        let resolvedRoot = URL(fileURLWithPath: resolvedPath, isDirectory: true)

        self.rootURL = lexicalRoot
        self.enumerationRootURL = resolvedRoot

        var roots: [String] = []
        func appendUnique(_ path: String) {
            guard !roots.contains(path) else { return }
            roots.append(path)
        }

        appendUnique(lexicalRoot.path)
        appendUnique(resolvedRoot.path)
        // Iterate a snapshot: aliases never need another round, and keeping
        // lexical/resolved roots first preserves the caller's preferred form.
        let seedRoots = roots
        for path in seedRoots {
            for alias in Self.darwinPrivateAliases(for: path) {
                appendUnique(alias)
            }
        }
        // Prefer the most specific root if an unusual symlink layout makes
        // one equivalent spelling a prefix of another.
        self.equivalentRootPaths = roots.sorted { $0.count > $1.count }
    }

    /// Returns a portable relative path when `url` is below any equivalent
    /// spelling of the root, including its resolved symlink target.
    public func relativePath(of url: URL) -> String? {
        let path = Self.lexicallyNormalized(url.path)
        for basePath in equivalentRootPaths {
            if path == basePath { return "" }
            let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
            if path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
        }
        return nil
    }

    /// Maps a URL below an equivalent root back onto the spelling selected by
    /// the user. URLs outside the root are returned standardized but otherwise
    /// untouched, so callers can reject them explicitly when appropriate.
    public func rebaseToRoot(_ url: URL) -> URL {
        let normalizedPath = Self.lexicallyNormalized(url.path)
        guard let relativePath = relativePath(of: url) else {
            return URL(
                fileURLWithPath: normalizedPath,
                isDirectory: url.hasDirectoryPath
            )
        }
        guard !relativePath.isEmpty else { return rootURL }

        let rebasedPath = rootPath.hasSuffix("/")
            ? rootPath + relativePath
            : rootPath + "/" + relativePath
        // Retain any prefetched resource values when no spelling change was
        // needed; rebuilding an equal URL would throw that cache away.
        return rebasedPath == normalizedPath
            ? url
            : URL(fileURLWithPath: rebasedPath, isDirectory: url.hasDirectoryPath)
    }

    /// A comparison key rooted in the caller's lexical spelling.
    public func pathRebasedToRoot(for url: URL) -> String {
        rebaseToRoot(url).path
    }

    /// Reconstructs a lexical child URL from a persisted relative path.
    /// Absolute and traversal-shaped values are rejected instead of being
    /// allowed to escape (or create a misleading nested copy of) the root.
    public func url(forRelativePath relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            return nil
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        let candidatePath = rootPath.hasSuffix("/")
            ? rootPath + relativePath
            : rootPath + "/" + relativePath
        let candidate = URL(fileURLWithPath: candidatePath)
        guard self.relativePath(of: candidate) == relativePath else { return nil }
        return candidate
    }

    private static func lexicallyNormalized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
                continue
            }
            components.append(component)
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    private static func darwinPrivateAliases(for path: String) -> [String] {
        let unprivateRoots = ["/tmp", "/var", "/etc"]
        for root in unprivateRoots {
            if path == root || path.hasPrefix(root + "/") {
                return ["/private" + path]
            }
            let privateRoot = "/private" + root
            if path == privateRoot || path.hasPrefix(privateRoot + "/") {
                return [String(path.dropFirst("/private".count))]
            }
        }
        return []
    }
}
