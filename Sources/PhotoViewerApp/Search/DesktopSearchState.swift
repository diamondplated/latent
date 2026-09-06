import Foundation
import Observation
import PhotoIO
import PhotoML
import PhotoSearch

/// Window-local coordinator for semantic search. Every operation is local and
/// user initiated: opening the search bar only inspects the saved index, while
/// indexing starts exclusively from the explicit button.
@MainActor
@Observable
final class DesktopSearchState {
    enum IndexState: Equatable {
        case noFolder
        case readOnlySource
        case checking
        case missing
        case current(indexedCount: Int, skippedCount: Int)
        case stale(indexedCount: Int, skippedCount: Int, discoveredCount: Int)
        case failed(String)
    }

    enum ResultContext: Equatable {
        case none
        case text(String)
        case similar(filename: String)
    }

    struct ModelAvailability: Equatable {
        let imageEncoder: Bool
        let textEncoder: Bool
        let tokenizer: Bool

        var canIndexOrFindSimilar: Bool { imageEncoder }
        var canSearchText: Bool { imageEncoder && textEncoder && tokenizer }

        nonisolated static func detect() -> ModelAvailability {
            ModelAvailability(
                imageEncoder: ModelRegistry.url(for: .openCLIPImageEncoder) != nil,
                textEncoder: ModelRegistry.url(for: .openCLIPTextEncoder) != nil,
                tokenizer: CLIPBPETokenizer.locateMergesFile() != nil
            )
        }
    }

    var query = ""
    private(set) var indexState: IndexState = .noFolder
    /// nil means search is not filtering the browser; [] is an active query
    /// with no matches. The distinction keeps an empty query from blanking the
    /// grid while still allowing an honest zero-result state.
    private(set) var resultFilter: [URL]? = nil
    private(set) var resultContext: ResultContext = .none
    private(set) var isSearching = false
    private(set) var isIndexing = false
    private(set) var indexedCurrent = 0
    private(set) var indexedTotal = 0
    private(set) var indexingFilename = ""
    private(set) var isStoppingIndex = false
    private(set) var message: String? = nil
    private(set) var modelAvailability = ModelAvailability.detect()

    @ObservationIgnored private var folderURL: URL?
    @ObservationIgnored private var sourceIsReadOnly = false
    @ObservationIgnored private var engine: SearchEngine?
    @ObservationIgnored private var engineFolder: URL?
    @ObservationIgnored private var inspectionTask: Task<Void, Never>?
    @ObservationIgnored private var indexingTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var inspectionGeneration: UInt64 = 0
    @ObservationIgnored private var indexingGeneration: UInt64 = 0
    @ObservationIgnored private var searchGeneration: UInt64 = 0
    @ObservationIgnored private var ignoreNextQueryChange = false
    @ObservationIgnored private var folderChangedWhileIndexing = false

    var hasSavedIndex: Bool {
        switch indexState {
        case .current, .stale: true
        default: false
        }
    }

    var progressFraction: Double {
        guard indexedTotal > 0 else { return 0 }
        return min(1, Double(indexedCurrent) / Double(indexedTotal))
    }

    var modelHelpText: String? {
        if !modelAvailability.imageEncoder {
            return "Indexing and Find Similar need the local OpenCLIP image model. Latent never downloads it automatically."
        }
        if !modelAvailability.textEncoder || !modelAvailability.tokenizer {
            return "Text search also needs the local OpenCLIP text model and tokenizer. Find Similar is still available."
        }
        return nil
    }

    func bind(folder: URL?, readOnly: Bool) {
        guard folderURL != folder || sourceIsReadOnly != readOnly else { return }
        cancelAllOperations()
        folderURL = folder
        sourceIsReadOnly = readOnly
        engine = nil
        engineFolder = nil
        query = ""
        resultFilter = nil
        resultContext = .none
        indexedCurrent = 0
        indexedTotal = 0
        indexingFilename = ""
        isStoppingIndex = false
        isIndexing = false
        folderChangedWhileIndexing = false
        message = nil
        modelAvailability = .detect()

        guard folder != nil else {
            indexState = .noFolder
            return
        }
        guard !readOnly else {
            indexState = .readOnlySource
            return
        }
        // Defer even the model-free filesystem inspection until the user opens
        // search. Folder browsing itself should not gain hidden recursive work.
        indexState = .checking
    }

    /// Cheap to call when the search UI opens or a watched folder changes.
    /// This scans metadata only and deliberately does not load Core ML.
    func refreshIndexStatus(after delay: Duration? = nil) {
        guard let folderURL, !sourceIsReadOnly, !isIndexing else { return }
        inspectionTask?.cancel()
        inspectionGeneration &+= 1
        let generation = inspectionGeneration
        indexState = .checking

        inspectionTask = Task { [weak self] in
            do {
                if let delay { try await Task.sleep(for: delay) }
                let status = try await SearchIndexInspector.inspect(folderURL: folderURL)
                try Task.checkCancellation()
                guard let self,
                      self.inspectionGeneration == generation,
                      self.folderURL == folderURL else { return }
                switch status {
                case .missing:
                    self.indexState = .missing
                case .current(let count, let skipped):
                    self.indexState = .current(indexedCount: count, skippedCount: skipped)
                case .stale(let indexed, let skipped, let discovered):
                    self.indexState = .stale(
                        indexedCount: indexed,
                        skippedCount: skipped,
                        discoveredCount: discovered
                    )
                }
                self.inspectionTask = nil
            } catch is CancellationError {
                // A replacement inspection owns the visible state.
            } catch {
                guard let self,
                      self.inspectionGeneration == generation,
                      self.folderURL == folderURL else { return }
                self.indexState = .failed("Couldn’t inspect the local search index: \(error.localizedDescription)")
                self.inspectionTask = nil
            }
        }
    }

    /// Mark the persisted embeddings as suspect immediately, then reconcile
    /// after a short delay so a burst of watcher events produces one scan.
    func noteFolderContentsChanged() {
        guard !sourceIsReadOnly else { return }
        if isIndexing {
            folderChangedWhileIndexing = true
            return
        }
        switch indexState {
        case .current(let count, let skipped):
            indexState = .stale(
                indexedCount: count,
                skippedCount: skipped,
                discoveredCount: count + skipped
            )
        case .stale, .checking:
            break
        default:
            return
        }
        // Replacing an in-flight inspection is essential: it may already have
        // snapshotted metadata before this newest filesystem event.
        refreshIndexStatus(after: .milliseconds(350))
    }

    func recheckModels() async {
        await ModelManager.shared.reset()
        engine = nil
        engineFolder = nil
        modelAvailability = .detect()
        message = modelHelpText == nil ? "OpenCLIP search assets are ready." : nil
    }

    func startIndexing(visibleURLs: @escaping @MainActor () -> [URL]) {
        guard let folderURL, !sourceIsReadOnly, indexingTask == nil else { return }
        modelAvailability = .detect()
        guard modelAvailability.canIndexOrFindSimilar else {
            message = "Install the OpenCLIP image model first. Nothing was downloaded or sent anywhere."
            return
        }

        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        inspectionTask?.cancel()
        inspectionTask = nil
        indexingGeneration &+= 1
        let generation = indexingGeneration
        indexedCurrent = 0
        indexedTotal = 0
        indexingFilename = "Preparing local model…"
        isStoppingIndex = false
        isIndexing = true
        folderChangedWhileIndexing = false
        message = nil

        let progress = DesktopIndexProgress { [weak self] filename, current, total in
            guard let self,
                  self.indexingGeneration == generation,
                  self.folderURL == folderURL else { return }
            self.indexingFilename = filename
            self.indexedCurrent = current
            self.indexedTotal = total
        }

        indexingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let engine = try await self.engineForCurrentFolder(
                    folderURL,
                    rebuildingInvalidIndex: true
                )
                try Task.checkCancellation()
                let report = try await engine.indexFolder(progress: progress)
                try Task.checkCancellation()
                guard self.indexingGeneration == generation,
                      self.folderURL == folderURL else { return }
                let needsFreshnessCheck = self.folderChangedWhileIndexing
                self.folderChangedWhileIndexing = false
                self.indexState = .current(
                    indexedCount: report.indexedCount,
                    skippedCount: report.skippedCount
                )
                self.indexedCurrent = report.indexedCount + report.skippedCount
                self.indexedTotal = report.indexedCount + report.skippedCount
                self.indexingFilename = ""
                self.indexingTask = nil
                self.isStoppingIndex = false
                self.isIndexing = false
                if report.skippedCount > 0 {
                    self.message = "Indexed \(report.indexedCount) photo\(report.indexedCount == 1 ? "" : "s") locally; skipped \(report.skippedCount) unreadable file\(report.skippedCount == 1 ? "" : "s")."
                } else {
                    self.message = report.indexedCount == 1
                        ? "Indexed 1 photo locally."
                        : "Indexed \(report.indexedCount) photos locally."
                }
                if needsFreshnessCheck {
                    self.message = nil
                    self.refreshIndexStatus(after: .milliseconds(350))
                }
                if !self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Index discovery is recursive and can outlive one or more
                    // watcher commits. Resolve against the browser population
                    // that exists *now*, not the array captured at button click.
                    self.scheduleTextSearch(visibleURLs: visibleURLs(), debounce: false)
                }
            } catch is CancellationError {
                guard self.indexingGeneration == generation,
                      self.folderURL == folderURL else { return }
                // Never reuse the actor whose in-memory refresh was cancelled.
                // SearchEngine also stages updates transactionally, so this is
                // defense in depth rather than the sole data-integrity guard.
                self.engine = nil
                self.engineFolder = nil
                self.indexingTask = nil
                self.isStoppingIndex = false
                self.isIndexing = false
                self.folderChangedWhileIndexing = false
                self.indexingFilename = ""
                self.message = "Indexing stopped. No partial index was saved; if the final save had already finished, that complete index is available."
                self.refreshIndexStatus()
            } catch {
                guard self.indexingGeneration == generation,
                      self.folderURL == folderURL else { return }
                self.engine = nil
                self.engineFolder = nil
                self.indexingTask = nil
                self.isStoppingIndex = false
                self.isIndexing = false
                self.folderChangedWhileIndexing = false
                self.indexingFilename = ""
                self.message = self.friendly(error)
                self.refreshIndexStatus()
            }
        }
    }

    func cancelIndexing() {
        guard let indexingTask else { return }
        isStoppingIndex = true
        message = "Stopping after the current photo…"
        indexingTask.cancel()
    }

    func scheduleTextSearch(visibleURLs: [URL], debounce: Bool = true) {
        if ignoreNextQueryChange {
            ignoreNextQueryChange = false
            return
        }

        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        let generation = searchGeneration
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        message = nil

        guard !text.isEmpty else {
            isSearching = false
            resultFilter = nil
            resultContext = .none
            return
        }
        resultContext = .text(text)
        // A query that cannot run (no index or missing local models) must not
        // make the browser look empty. Apply a result filter only after an
        // actual search completes, including an honest zero-match result.
        resultFilter = nil

        guard let folderURL, !isIndexing else {
            isSearching = false
            return
        }
        guard hasSavedIndex || hasPersistedIndexFile(for: folderURL) else {
            isSearching = false
            message = "Index this folder before searching it."
            return
        }
        modelAvailability = .detect()
        guard modelAvailability.canSearchText else {
            isSearching = false
            message = "Text search needs the local OpenCLIP image model, text model, and tokenizer."
            return
        }
        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                if debounce { try await Task.sleep(for: .milliseconds(250)) }
                let engine = try await self.engineForCurrentFolder(folderURL)
                try Task.checkCancellation()
                let hits = try await engine.search(text: text, k: 500)
                try Task.checkCancellation()
                let urls = await Self.resolve(
                    hits: hits,
                    under: folderURL,
                    visibleURLs: visibleURLs,
                    excluding: nil
                )
                try Task.checkCancellation()
                guard self.searchGeneration == generation,
                      self.folderURL == folderURL,
                      self.query.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
                self.resultFilter = urls
                self.resultContext = .text(text)
                self.isSearching = false
                self.searchTask = nil
                self.message = urls.isEmpty ? "No matches in the current browser view." : nil
            } catch is CancellationError {
                // The newer query owns the UI.
            } catch {
                guard self.searchGeneration == generation,
                      self.folderURL == folderURL else { return }
                self.isSearching = false
                self.searchTask = nil
                self.message = self.friendly(error)
            }
        }
    }

    func findSimilar(to url: URL, visibleURLs: [URL]) {
        guard let folderURL, !sourceIsReadOnly, !isIndexing else { return }
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        let generation = searchGeneration
        ignoreNextQueryChange = !query.isEmpty
        query = ""
        resultContext = .similar(filename: url.lastPathComponent)
        resultFilter = nil
        message = nil

        guard hasSavedIndex || hasPersistedIndexFile(for: folderURL) else {
            message = "Index this folder before finding similar photos."
            return
        }
        modelAvailability = .detect()
        guard modelAvailability.canIndexOrFindSimilar else {
            message = "Find Similar needs the local OpenCLIP image model."
            return
        }

        isSearching = true
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let queryBuffer = try await Task.detached(priority: .userInitiated) {
                    try ImageReader().read(url: url).0
                }.value
                try Task.checkCancellation()
                let engine = try await self.engineForCurrentFolder(folderURL)
                let hits = try await engine.search(similarTo: queryBuffer, k: 500)
                try Task.checkCancellation()
                let urls = await Self.resolve(
                    hits: hits,
                    under: folderURL,
                    visibleURLs: visibleURLs,
                    excluding: url
                )
                try Task.checkCancellation()
                guard self.searchGeneration == generation,
                      self.folderURL == folderURL else { return }
                self.resultFilter = urls
                self.resultContext = .similar(filename: url.lastPathComponent)
                self.isSearching = false
                self.searchTask = nil
                self.message = urls.isEmpty ? "No other matches in the current browser view." : nil
            } catch is CancellationError {
                // A newer search or folder owns the UI.
            } catch {
                guard self.searchGeneration == generation,
                      self.folderURL == folderURL else { return }
                self.isSearching = false
                self.searchTask = nil
                self.message = self.friendly(error)
            }
        }
    }

    func clearResults() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        ignoreNextQueryChange = !query.isEmpty
        query = ""
        resultFilter = nil
        resultContext = .none
        isSearching = false
        message = nil
    }

    /// Close the search surface without carrying the clear button's one-shot
    /// query-change suppression into the next time the bar is opened.
    ///
    /// `clearResults()` intentionally ignores the `TextField` observation
    /// caused by its own programmatic `query = ""`. A close can remove that
    /// field before SwiftUI delivers the observation, so the suppression must
    /// be consumed here rather than by the user's first query after reopening.
    func resetForClose() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        ignoreNextQueryChange = false
        query = ""
        resultFilter = nil
        resultContext = .none
        isSearching = false
        message = nil
    }

    /// Phone navigation addresses the complete folder. Keep the search bar
    /// open, but clear its local query/ranking before the external selection.
    func resetForExternalSelection() {
        resetForClose()
    }

    /// Retire operations and rankings captured against the old browser
    /// population when the same folder is reloaded in a different recursion
    /// mode. The persisted index remains available and is re-inspected after
    /// the folder scan completes.
    func resetForFolderReload() {
        cancelAllOperations()
        query = ""
        resultFilter = nil
        resultContext = .none
        indexedCurrent = 0
        indexedTotal = 0
        indexingFilename = ""
        message = nil
        if folderURL == nil {
            indexState = .noFolder
        } else if sourceIsReadOnly {
            indexState = .readOnlySource
        } else {
            indexState = .checking
        }
    }

    func cancelAllOperations() {
        inspectionGeneration &+= 1
        indexingGeneration &+= 1
        searchGeneration &+= 1
        inspectionTask?.cancel()
        indexingTask?.cancel()
        searchTask?.cancel()
        inspectionTask = nil
        indexingTask = nil
        searchTask = nil
        isSearching = false
        isStoppingIndex = false
        isIndexing = false
        folderChangedWhileIndexing = false
        ignoreNextQueryChange = false
    }

    private func engineForCurrentFolder(
        _ folder: URL,
        rebuildingInvalidIndex: Bool = false
    ) async throws -> SearchEngine {
        if let engine, engineFolder == folder { return engine }
        let built = try await SearchEngine(
            folderURL: folder,
            recoverInvalidIndex: rebuildingInvalidIndex
        )
        try Task.checkCancellation()
        guard folderURL == folder else { throw CancellationError() }
        engine = built
        engineFolder = folder
        return built
    }

    private func friendly(_ error: Error) -> String {
        if let searchError = error as? SearchError {
            switch searchError {
            case .textNotAvailable:
                return "Text search needs the local OpenCLIP text model and tokenizer."
            case .encoderError:
                return "OpenCLIP search assets are missing or couldn’t be loaded. Nothing was downloaded."
            case .folderNotADirectory:
                return "The folder is no longer available."
            case .readError(let url, _):
                return "Couldn’t read \(url.lastPathComponent) for search."
            }
        }
        return "Search couldn’t finish: \(error.localizedDescription)"
    }

    private func hasPersistedIndexFile(for folder: URL) -> Bool {
        guard let url = try? EmbeddingIndex.indexFileURL(for: folder) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    nonisolated private static func resolve(
        hits: [SearchResult],
        under folder: URL,
        visibleURLs: [URL],
        excluding excludedURL: URL?
    ) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            let paths = FolderPathMapper(rootURL: folder)
            let normalizePath: (URL) -> String = { url in
                paths.pathRebasedToRoot(for: url)
            }
            let visibleByPath = Dictionary(
                visibleURLs.map { (normalizePath($0), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let rootPrefix = paths.rootPath.hasSuffix("/")
                ? paths.rootPath
                : paths.rootPath + "/"
            let excludedPath = excludedURL.map(normalizePath)
            var seen = Set<String>()
            var resolved: [URL] = []
            resolved.reserveCapacity(min(hits.count, visibleURLs.count))

            for hit in hits {
                guard let candidate = paths.url(
                    forRelativePath: hit.entry.relativePath
                ) else { continue }
                let path = normalizePath(candidate)
                guard path.hasPrefix(rootPrefix), path != excludedPath,
                      seen.insert(path).inserted,
                      let visible = visibleByPath[path] else { continue }
                resolved.append(visible)
            }
            return resolved
        }.value
    }
}

private struct DesktopIndexProgress: SearchProgress {
    let update: @MainActor @Sendable (String, Int, Int) -> Void

    func indexing(_ relativePath: String, current: Int, total: Int) async {
        await update(relativePath, current, total)
    }
}
