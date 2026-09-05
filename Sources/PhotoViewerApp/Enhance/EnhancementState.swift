import Foundation
import AppKit
import SwiftUI
import PipelineCore
import EnhancementStages
import PhotoIO

private enum FullBufferReadOutcome: @unchecked Sendable {
    case success(ImageBuffer, ImageMetadata)
    case failure(any Error)
    case cancelled
}

/// One-shot result shared when more than one UI action asks for the same full
/// buffer. The operation resolves this from a worker thread while the editor
/// awaits it on the main actor.
private final class FullBufferReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: FullBufferReadOutcome?
    private var waiters: [CheckedContinuation<FullBufferReadOutcome, Never>] = []

    func value() async -> FullBufferReadOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func resolve(_ outcome: FullBufferReadOutcome) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for continuation in pending {
            continuation.resume(returning: outcome)
        }
    }
}

/// A full-resolution read holds its physical queue permit until the complete
/// ImageIO + working-buffer conversion returns. Queued reads can be cancelled;
/// already-running reads remain reusable if their URL quickly becomes current
/// again.
private final class FullBufferReadOperation: Operation, @unchecked Sendable {
    private let url: URL
    private let reader: ImageReader
    private let result: FullBufferReadResult
    private let stateLock = NSLock()
    private var startedRead = false

    init(url: URL, reader: ImageReader, result: FullBufferReadResult) {
        self.url = url
        self.reader = reader
        self.result = result
        super.init()
    }

    override func main() {
        stateLock.lock()
        guard !isCancelled else {
            stateLock.unlock()
            result.resolve(.cancelled)
            return
        }
        startedRead = true
        stateLock.unlock()

        do {
            let (buffer, metadata) = try reader.read(url: url)
            result.resolve(.success(buffer, metadata))
        } catch {
            result.resolve(.failure(error))
        }
    }

    func cancelIfQueued() -> Bool {
        stateLock.lock()
        guard !startedRead else {
            stateLock.unlock()
            return false
        }
        super.cancel()
        stateLock.unlock()
        result.resolve(.cancelled)
        return true
    }
}

/// Keeps only the newest queued full-buffer request while sharing any existing
/// job for the same URL. Running synchronous reads cannot be interrupted, so
/// they remain registered and continue occupying the process-wide decode gate
/// until return instead of disappearing from concurrency accounting.
@MainActor
private final class FullBufferReadCoordinator {
    private struct Job {
        let id: UUID
        let operation: FullBufferReadOperation
        let resultTask: Task<FullBufferReadOutcome, Never>
    }

    private let reader = ImageReader()
    private var jobs: [URL: Job] = [:]
    private var requestedURL: URL?

    func read(_ url: URL) -> Task<FullBufferReadOutcome, Never> {
        requestedURL = url
        cancelQueuedJobs(except: url)

        if let existing = jobs[url] {
            existing.operation.queuePriority = .veryHigh
            existing.operation.qualityOfService = .userInitiated
            return existing.resultTask
        }

        let id = UUID()
        let result = FullBufferReadResult()
        let operation = FullBufferReadOperation(url: url, reader: reader, result: result)
        operation.queuePriority = .veryHigh
        operation.qualityOfService = .userInitiated
        let resultTask = Task.detached(priority: .userInitiated) {
            await result.value()
        }
        jobs[url] = Job(id: id, operation: operation, resultTask: resultTask)

        Task { @MainActor [weak self, resultTask] in
            _ = await resultTask.value
            self?.finish(url: url, id: id)
        }
        ImageDecodeWorkQueue.shared.addOperation(operation)
        return resultTask
    }

    func cancelRequest(for url: URL?) {
        if url == nil || requestedURL == url {
            requestedURL = nil
        }
        cancelQueuedJobs(except: requestedURL)
    }

    private func cancelQueuedJobs(except retainedURL: URL?) {
        let obsolete = jobs.keys.filter { $0 != retainedURL }
        for url in obsolete {
            guard let job = jobs[url] else { continue }
            if job.operation.cancelIfQueued() {
                jobs.removeValue(forKey: url)
            }
        }
    }

    private func finish(url: URL, id: UUID) {
        guard jobs[url]?.id == id else { return }
        jobs.removeValue(forKey: url)
    }
}

/// Single source of truth for the in-app enhancement editor.
///
/// Lifecycle:
///   1. `loadInput(url:)` resets to defaults, restores that image's
///      `.enhance.json` recipe, then reads pixels via `ImageReader`.
///   2. Any param/enable change calls `runPipeline()`, which persists the
///      recipe, cancels the in-flight task, and starts a new one. Upstream
///      stages cache-hit on identical params, so only the changed stage and
///      below recompute.
///   3. `saveEnhanced()` atomically exports the latest `enhancedBuffer` (or
///      original if no enhanced result yet) to a collision-safe copy beside
///      the source. The original is never replaced.
///
/// Debounce policy: cancel-on-edit instead of wall-clock debounce. Slider
/// drags fire many writes; cancellation drops the obsolete tasks before they
/// touch the cache. The cache then makes per-edit re-runs ~free for the
/// upstream slice that didn't change.
@MainActor
@Observable
final class EnhancementState {

    // MARK: - Per-stage state

    // Defaults: stages that work today (Sharpen + Upscale-via-Lanczos) are
    // ON; placebo stages (need a model file the user hasn't installed) are
    // OFF. The user can flip them on later, but `buildSteps()` will still
    // gate on the actual model presence so the pipeline never wastes time
    // running an identity-passthrough.
    var artifactRemovalEnabled: Bool = false {
        didSet { recipeSettingDidChange() }
    }
    var artifactRemovalParams: ArtifactRemoval.Params = .init() {
        didSet { recipeSettingDidChange() }
    }

    var denoiseEnabled: Bool = false {
        didSet { recipeSettingDidChange() }
    }
    var denoiseParams: Denoise.Params = .init() {
        didSet { recipeSettingDidChange() }
    }

    var upscaleEnabled: Bool = true {
        didSet { recipeSettingDidChange() }
    }
    var upscaleParams: Upscale.Params = .init() {
        didSet { recipeSettingDidChange() }
    }

    var sharpenEnabled: Bool = true {
        didSet { recipeSettingDidChange() }
    }
    var sharpenParams: Sharpen.Params = .init() {
        didSet { recipeSettingDidChange() }
    }

    // MARK: - Image state

    /// URL currently loaded. Set by `loadInput`; mutating clears buffers.
    private(set) var currentURL: URL? = nil
    /// Pre-pipeline pixels in the working format. `nil` while loading or on read error.
    private(set) var originalBuffer: ImageBuffer? = nil
    /// Pipeline output. `nil` until the first run completes (or while one is running).
    private(set) var enhancedBuffer: ImageBuffer? = nil
    /// Metadata captured at read time; passed back to the writer on save so
    /// EXIF/color-space round-trips correctly.
    private(set) var originalMetadata: ImageMetadata? = nil

    /// Fast-path full-resolution CGImage shown immediately on selection
    /// change so navigation feels instant. Decoded via CGImageSource (no
    /// NSImage middleman that can pick a smaller representation, and
    /// preserves the source's color space — Display P3 / Adobe RGB photos
    /// stay in their native gamut all the way to the SwiftUI Image view).
    private(set) var previewCGImage: CGImage? = nil
    /// CGImage of `originalBuffer`, cached so SwiftUI doesn't redo the
    /// float16 → CGImage bridge on every body() call. nil before the
    /// working buffer is ready; `originalDisplayImage` falls back to
    /// `previewCGImage`.
    private(set) var originalCGImage: CGImage? = nil
    /// CGImage of `enhancedBuffer`, cached likewise.
    private(set) var enhancedCGImage: CGImage? = nil

    /// User-selected comparison mode. `displayMode` adds the transient blink
    /// override on top. Defaults to `.original` so simply browsing photos
    /// doesn't trigger a 2-second Lanczos+Sharpen pipeline run on every nav.
    /// The pipeline only runs when the user explicitly switches to .enhanced
    /// or .sideBySide (or adjusts a slider).
    var compareMode: CompareMode = .original
    /// True while the user holds the blink key (B). Forces the original view
    /// momentarily; on release falls back to `compareMode`.
    var blinking: Bool = false

    /// What DetailView should actually render right now. Combines compareMode
    /// with the transient blink state.
    var displayMode: CompareMode {
        blinking ? .original : compareMode
    }

    /// CGImage to render in the "original" pane. Falls back through:
    ///   1. fully-decoded working buffer (slowest to arrive)
    ///   2. fast preview from CGImageSource (instant)
    ///   3. nil → caller shows skeleton
    var originalDisplayImage: CGImage? { originalCGImage ?? previewCGImage }

    /// CGImage to render in the "enhanced" pane. Falls back through:
    ///   1. pipeline output (slowest to arrive)
    ///   2. original buffer (so user sees something during enhancement)
    ///   3. fast preview
    ///   4. nil
    var enhancedDisplayImage: CGImage? {
        enhancedCGImage ?? originalCGImage ?? previewCGImage
    }

    /// True only when we have absolutely no image to show — controls whether
    /// DetailView shows the skeleton loader.
    var hasAnyImage: Bool { originalDisplayImage != nil || enhancedDisplayImage != nil }

    /// Backward-compat for the existing badge / dimensions code in DetailView.
    /// Tracks whatever's effectively rendering (including transient blink).
    var showingOriginal: Bool {
        displayMode == .original
    }

    /// True while the current pipeline task is running.
    private(set) var isProcessing: Bool = false
    /// Last error the pipeline or I/O surfaced; nil if none.
    private(set) var lastError: String? = nil
    /// Non-fatal recipe persistence problem. Kept separate from processing
    /// errors so a successful pipeline run cannot erase an important warning
    /// about a sidecar the app could not read or update.
    private(set) var recipeWarning: String? = nil
    /// Destination of the most recent successful export for this image. The
    /// panel uses it as explicit success feedback instead of making a silent
    /// filesystem write.
    private(set) var lastExportedURL: URL? = nil
    /// True while an export is preparing or committing its output file.
    private(set) var isExporting: Bool = false

    /// Enhancement recipes apply only to still images. Video and animated
    /// image playback stay available, but their pixels do not enter this
    /// image-only pipeline.
    var canEnhanceCurrentMedia: Bool {
        currentURL != nil && currentMediaSupportsEnhancements && !isLoadingRecipe
    }

    /// Reset is useful only after this image differs from Latent's defaults.
    var canResetRecipe: Bool {
        canEnhanceCurrentMedia && !recipePersistenceBlocked && !isUsingDefaultRecipe
    }

    // MARK: - Pipeline plumbing

    /// Shared across loads — cache keys are content-hashed, so loading a new
    /// image doesn't poison hits for the old one. 256 MiB ceiling is enough
    /// for several intermediates of a typical photo at working format.
    let cache = IntermediateCache(maxBytes: 256 * 1024 * 1024)
    private let writer = ImageWriter()
    private let fullBufferReadCoordinator = FullBufferReadCoordinator()

    /// In-flight pipeline run, if any. Replaced (and cancelled) on every edit.
    private var pipelineTask: Task<Void, Never>? = nil
    /// Token for the newest pipeline run. Separate from loadGeneration so
    /// cancelled edits for the same image can't clear a newer run's state.
    private var pipelineGeneration: UInt64 = 0
    /// Token for the most recent `loadInput` so a slow read for an old URL
    /// can't clobber state set by a later URL.
    private var loadGeneration: UInt64 = 0
    /// Shared full-buffer load so compare-mode switches and slider edits do
    /// not pile up duplicate ImageReader work for the same image.
    private var fullBufferLoadTask: Task<Void, Never>? = nil
    private var fullBufferLoadGeneration: UInt64? = nil
    private var fullBufferLoadURL: URL? = nil
    /// Sidecar originally loaded for this image. Retained so a save can replace
    /// known stages while round-tripping stages introduced by newer versions.
    private var loadedSidecar: EnhanceSidecar? = nil
    private var recipeDirty = false
    private var suppressRecipeTracking = false
    /// Keeps controls disabled while the selected image's recipe is loading,
    /// preventing a fast edit from being overwritten by a late sidecar read.
    private(set) var isLoadingRecipe = false
    /// A sidecar that failed to decode may contain newer top-level data. Do not
    /// overwrite it merely because this older build changed a slider.
    private var recipePersistenceBlocked = false
    private var currentMediaSupportsEnhancements = false
    private var exportGeneration: UInt64 = 0

    init() {}

    /// Clear all retained pixel data and cancel in-flight work. Called when
    /// the user closes a folder so 100MB+ of decoded buffers don't linger.
    func reset() {
        // Capture an in-progress slider edit even if the enclosing view goes
        // away before SwiftUI delivers its normal on-editing-ended callback.
        persistRecipeIfNeeded()
        cancelPipeline(clearProcessing: true)
        cancelFullBufferLoad()
        Task { await cache.clear() }
        exportGeneration &+= 1
        isExporting = false
        currentURL = nil
        currentMediaSupportsEnhancements = false
        originalBuffer = nil
        enhancedBuffer = nil
        originalMetadata = nil
        previewCGImage = nil
        originalCGImage = nil
        enhancedCGImage = nil
        lastError = nil
        recipeWarning = nil
        lastExportedURL = nil
        loadedSidecar = nil
        isLoadingRecipe = false
        recipePersistenceBlocked = false
        applyDefaultRecipe()
        recipeDirty = false
        compareMode = .original
        blinking = false
    }

    // MARK: - Public API

    /// Load a photo from disk into the editor and run the pipeline once.
    /// Calling again with a different URL cancels the previous run.
    ///
    /// Two-phase load:
    ///   1. Fast preview: CGImageSource decode on a detached task — typically
    ///      ~50-150ms for a 14MP JPEG. Shown immediately so navigation feels
    ///      instant. **Skipped entirely on prefetch cache hit** — the
    ///      ImagePrefetcher has already decoded the neighbors, so cache
    ///      lookups land synchronously and the swap is sub-frame.
    ///   2. Full buffer: ImageReader.read() does the linear-sRGB float16
    ///      conversion needed by the pipeline. Hundreds of ms — happens in
    ///      the background, then runPipeline() kicks off.
    func loadInput(
        url: URL,
        prefetched: CGImage? = nil,
        previewTask: Task<CGImage?, Never>? = nil
    ) async {
        // If the user re-clicks the same URL we're already on, do nothing —
        // avoids a redundant re-decode and pipeline run when the selection
        // change in DetailView fires `.task(id:)` on the same URL.
        if currentURL == url, originalBuffer != nil { return }

        // Navigation can interrupt a slider gesture before its commit
        // callback. Persist any dirty values against the old URL before the
        // per-image state below is reset.
        persistRecipeIfNeeded()

        loadGeneration &+= 1
        let myGen = loadGeneration

        // Cancel any in-flight work for the previous image.
        cancelPipeline(clearProcessing: true)
        cancelFullBufferLoad()
        exportGeneration &+= 1
        isExporting = false

        // Never show the previous photo under the new filename/actions. A
        // prefetch hit replaces these immediately; a miss shows a skeleton.
        currentURL = url
        currentMediaSupportsEnhancements = MediaTyping.detect(url) == .staticImage
        originalBuffer = nil
        enhancedBuffer = nil
        originalMetadata = nil
        previewCGImage = nil
        originalCGImage = nil
        enhancedCGImage = nil
        lastError = nil
        recipeWarning = nil
        lastExportedURL = nil
        loadedSidecar = nil
        isLoadingRecipe = currentMediaSupportsEnhancements
        recipePersistenceBlocked = false
        applyDefaultRecipe()
        recipeDirty = false

        // AVPlayer/NSImageView own video and animated-image rendering. Reset a
        // lingering side-by-side comparison here so DetailView can route those
        // media types correctly, then skip image decoding and recipe I/O.
        guard currentMediaSupportsEnhancements else {
            isLoadingRecipe = false
            compareMode = .original
            return
        }

        // Restore this image's recipe before any pipeline run. Decode into
        // temporary values and commit all settings together so a malformed
        // known stage cannot leave a half-applied recipe in the UI.
        do {
            let sidecar = try await Task.detached(priority: .utility) {
                try EnhanceSidecar.load(for: url)
            }.value
            guard myGen == loadGeneration, currentURL == url else { return }
            if let sidecar {
                try apply(sidecar: sidecar)
                loadedSidecar = sidecar
            }
            isLoadingRecipe = false
        } catch {
            guard myGen == loadGeneration, currentURL == url else { return }
            isLoadingRecipe = false
            applyDefaultRecipe()
            recipeDirty = false
            recipePersistenceBlocked = true
            recipeWarning = "Couldn't read \(url.lastPathComponent).enhance.json. Its saved recipe was left untouched."
            // Do not silently render defaults as though they were the saved
            // enhancement the user requested.
            compareMode = .original
        }

        // Prefetch fast path: caller (the BrowserView selection handler)
        // looked up the prefetcher and passed in a decoded CGImage. Skip
        // the disk decode entirely — we already have the pixels.
        if let prefetched {
            previewCGImage = prefetched
            originalCGImage = nil
            enhancedCGImage = nil
            // Same as the slow path: only run the heavy buffer read if the
            // user is actually going to need the pipeline output.
            if compareMode != .original {
                await loadFullBuffer(url: url, generation: myGen)
            }
            return
        }

        // Phase 1: fast full-resolution preview as a CGImage. The CGImage
        // carries the source file's native color space (Display P3, Adobe
        // RGB, etc.), so passing it straight into SwiftUI's Image view
        // means wide-gamut photos stay in their gamut on capable displays.
        // Apply the preview first so the UI swaps to the new photo
        // immediately. Same-step nil out the cached CGImages of the
        // previous photo so we don't keep displaying stale content if
        // the preview decode took longer than a vsync.
        let preview = await previewTask?.value
        guard !Task.isCancelled,
              myGen == loadGeneration,
              currentURL == url else { return }
        previewCGImage = preview
        if preview == nil, MediaTyping.detect(url) == .staticImage {
            lastError = "Couldn't open \(url.lastPathComponent)."
        }

        // Phase 2: full pipeline-ready buffer + metadata. Only kick this off
        // when there's a reason to — i.e. the user is in a mode that needs
        // the enhanced output, OR they're going to need it for Export Copy.
        // For the default browsing case (compareMode = .original), skip the
        // heavy ImageReader.read() + Lanczos+Sharpen entirely so nav is free.
        if compareMode != .original {
            await loadFullBuffer(url: url, generation: myGen)
        }
    }

    /// Heavy decode + pipeline run. Idempotent across repeat calls for the
    /// same URL (the generation guard drops stale results). Called from
    /// `loadInput` only when needed, or on-demand when the user switches to
    /// a compare mode that requires enhanced output.
    func loadFullBuffer(url: URL, generation myGen: UInt64) async {
        // If we've already loaded this URL's buffer, don't redo it.
        if originalBuffer != nil, currentURL == url {
            if enhancedBuffer == nil, pipelineTask == nil {
                runPipeline()
            }
            return
        }

        if let task = fullBufferLoadTask,
           fullBufferLoadGeneration == myGen,
           fullBufferLoadURL == url {
            await task.value
            return
        }

        cancelFullBufferLoad()
        fullBufferLoadGeneration = myGen
        fullBufferLoadURL = url

        let readTask = fullBufferReadCoordinator.read(url)
        let task = Task { @MainActor [weak self, readTask] in
            let outcome = await readTask.value
            guard !Task.isCancelled else { return }
            self?.applyFullBufferLoadOutcome(outcome, url: url, generation: myGen)
        }
        fullBufferLoadTask = task
        await task.value
    }

    /// Called by the UI when the user changes compare mode. Triggers the
    /// heavy buffer load + pipeline if we don't already have an enhanced
    /// result for the current photo.
    func ensureEnhancedAvailable() {
        guard canEnhanceCurrentMedia else { return }
        guard let url = currentURL else { return }
        guard enhancedBuffer == nil else { return }

        if originalBuffer != nil {
            if pipelineTask == nil {
                runPipeline()
            }
            return
        }

        Task { await loadFullBuffer(url: url, generation: loadGeneration) }
    }

    /// Cancel any running pipeline and start a new one with the current
    /// stage state. Safe to call from any UI binding (slider edit, toggle).
    /// If the heavy decode hasn't run yet (lazy default), kick that off
    /// first; the pipeline runs as a continuation when it lands.
    func runPipeline() {
        // UI controls mutate their value first and call runPipeline on commit.
        // Persist that exact recipe before starting expensive work; automatic
        // runs after image load leave `recipeDirty == false` and do no I/O.
        persistRecipeIfNeeded()

        guard canEnhanceCurrentMedia else { return }
        guard let url = currentURL else { return }
        guard let input = originalBuffer else {
            // Lazy load the buffer first — runPipeline is normally chained
            // off slider/toggle edits, so the user wants to SEE the result.
            // ensureEnhancedAvailable does load + runPipeline once decoded.
            ensureEnhancedAvailable()
            // Side-effect: also flip out of .original so the panel shows the
            // result the user is editing toward.
            if compareMode == .original { compareMode = .enhanced }
            _ = url  // (used implicitly via ensureEnhancedAvailable)
            return
        }

        pipelineGeneration &+= 1
        let myPipelineGen = pipelineGeneration
        let previousTask = pipelineTask
        previousTask?.cancel()
        let steps = buildSteps()
        let pipeline = Pipeline(steps: steps, cache: cache)
        let myGen = loadGeneration

        isProcessing = true
        lastError = nil
        enhancedBuffer = nil
        enhancedCGImage = nil

        // Store the actual detached worker, not a main-actor wrapper around
        // it. Cancelling `pipelineTask` now reaches Pipeline.run and its tile
        // loop instead of merely abandoning a task that continues inference.
        // Wait for the cancelled predecessor so synchronous Core ML calls do
        // not overlap while an older prediction finishes draining.
        pipelineTask = Task.detached(priority: .userInitiated) { [weak self] in
            await previousTask?.value
            guard !Task.isCancelled else { return }
            let runResult: Result<ImageBuffer, Error>
            do {
                runResult = .success(try await pipeline.run(input: input))
            } catch {
                runResult = .failure(error)
            }
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                // Drop the result if the user moved on to a different image or
                // started a newer pipeline run for the same image.
                guard self.matchesGeneration(myGen),
                      self.matchesPipelineGeneration(myPipelineGen) else { return }
                self.applyPipelineResult(runResult, pipelineGeneration: myPipelineGen)
            }
        }
    }

    /// Write `enhancedBuffer` (falling back to `originalBuffer`) next to the
    /// source as `<stem>_enhanced.<ext>`. The writer encodes to a temporary
    /// sibling, then atomically claims the first free Keep Both filename; the
    /// original and any previous exports are never replaced.
    func saveEnhanced() async {
        guard let url = currentURL else {
            lastError = "Nothing to save."
            return
        }
        guard canEnhanceCurrentMedia else {
            lastExportedURL = nil
            lastError = "Enhancement export is available for still images only."
            return
        }
        guard !isExporting else { return }

        persistRecipeIfNeeded()
        exportGeneration &+= 1
        let myExportGeneration = exportGeneration
        isExporting = true
        lastExportedURL = nil
        lastError = nil
        defer {
            if exportGeneration == myExportGeneration {
                isExporting = false
            }
        }

        let savingGeneration = loadGeneration
        // Lazy-load the heavy buffer if we don't have it yet. Export Copy
        // works even when the user has been browsing in .original mode.
        if originalBuffer == nil {
            await loadFullBuffer(url: url, generation: savingGeneration)
        }
        // Slider edits replace the running task. Keep waiting until the latest
        // run settles, then bind the export to the image that was clicked.
        while let task = pipelineTask {
            await task.value
            guard currentURL == url, loadGeneration == savingGeneration else { return }
        }
        guard currentURL == url, loadGeneration == savingGeneration else { return }
        guard lastError == nil else { return }
        guard let buffer = enhancedBuffer ?? originalBuffer else {
            lastError = "Failed to load image for save."
            return
        }
        let metadata = originalMetadata
        let preferredDestination = Self.outputURL(for: url, sourceFormat: metadata?.sourceFormat)
        let writer = self.writer

        let writeResult: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let destination = try writer.writeKeepingBoth(
                    buffer: buffer,
                    metadata: metadata,
                    to: preferredDestination
                )
                return .success(destination)
            } catch {
                return .failure(error)
            }
        }.value

        guard currentURL == url, loadGeneration == savingGeneration else { return }
        switch writeResult {
        case .success(let destination):
            lastError = nil
            lastExportedURL = destination
        case .failure(let error):
            lastExportedURL = nil
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Preferred URL for `Export Copy`: `<dir>/<stem>_enhanced.<ext>`. Keeps the
    /// file in the source folder so the existing folder watcher picks it up.
    static func outputURL(for source: URL, sourceFormat: ImageFileFormat?) -> URL {
        let dir = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let sourceExtension = source.pathExtension
        let ext = sourceFormat == nil || sourceExtension.isEmpty
            ? sourceFormat?.preferredFilenameExtension ?? "jpg"
            : sourceExtension
        return dir.appendingPathComponent("\(stem)_enhanced.\(ext)")
    }

    /// Restore Latent's standard stage settings for the current still image
    /// and persist that reset as this image's recipe. Unknown future stages in
    /// the sidecar remain intact.
    func resetEnhancements() {
        guard canResetRecipe else { return }
        applyDefaultRecipe()
        recipeDirty = true
        lastExportedURL = nil
        runPipeline()
    }

    // MARK: - Private

    /// True while defaults or a sidecar are being applied programmatically.
    /// Property observers otherwise cannot distinguish that work from a user
    /// dragging a slider.
    private func withRecipeTrackingSuppressed(_ body: () -> Void) {
        let wasSuppressed = suppressRecipeTracking
        suppressRecipeTracking = true
        body()
        suppressRecipeTracking = wasSuppressed
    }

    private func applyDefaultRecipe() {
        withRecipeTrackingSuppressed {
            artifactRemovalEnabled = false
            artifactRemovalParams = .init()
            denoiseEnabled = false
            denoiseParams = .init()
            upscaleEnabled = true
            upscaleParams = .init()
            sharpenEnabled = true
            sharpenParams = .init()
        }
    }

    private func apply(sidecar: EnhanceSidecar) throws {
        // Decode first, commit second. A damaged parameter bag should not mix
        // values from the sidecar with defaults from this build.
        var artifactEnabled = false
        var artifactParams = ArtifactRemoval.Params()
        var denoiseIsEnabled = false
        var denoiseParameters = Denoise.Params()
        var upscaleIsEnabled = true
        var upscaleParameters = Upscale.Params()
        var sharpenIsEnabled = true
        var sharpenParameters = Sharpen.Params()

        for step in sidecar.steps {
            switch step.stageID {
            case "artifact-removal-fbcnn":
                artifactEnabled = step.enabled
                artifactParams = try step.parameters.decode(as: ArtifactRemoval.Params.self)
            case "denoise-nafnet":
                denoiseIsEnabled = step.enabled
                denoiseParameters = try step.parameters.decode(as: Denoise.Params.self)
            case "upscale":
                upscaleIsEnabled = step.enabled
                upscaleParameters = try step.parameters.decode(as: Upscale.Params.self)
            case "sharpen-unsharp-mask":
                sharpenIsEnabled = step.enabled
                sharpenParameters = try step.parameters.decode(as: Sharpen.Params.self)
            default:
                continue
            }
        }

        withRecipeTrackingSuppressed {
            artifactRemovalEnabled = artifactEnabled
            artifactRemovalParams = artifactParams
            denoiseEnabled = denoiseIsEnabled
            denoiseParams = denoiseParameters
            upscaleEnabled = upscaleIsEnabled
            upscaleParams = upscaleParameters
            sharpenEnabled = sharpenIsEnabled
            sharpenParams = sharpenParameters
        }
        recipeDirty = false
    }

    private func recipeSettingDidChange() {
        guard !suppressRecipeTracking else { return }
        recipeDirty = true
        lastExportedURL = nil
    }

    private var isUsingDefaultRecipe: Bool {
        !artifactRemovalEnabled
            && artifactRemovalParams == ArtifactRemoval.Params()
            && !denoiseEnabled
            && denoiseParams == Denoise.Params()
            && upscaleEnabled
            && upscaleParams == Upscale.Params()
            && sharpenEnabled
            && sharpenParams == Sharpen.Params()
    }

    private func persistRecipeIfNeeded() {
        guard recipeDirty,
              let url = currentURL,
              currentMediaSupportsEnhancements else { return }
        guard !recipePersistenceBlocked else {
            recipeWarning = "This image's saved recipe was created by an unsupported or damaged sidecar and was not overwritten."
            return
        }

        do {
            let knownSteps: [EnhanceSidecar.SidecarStep] = [
                .init(
                    stageID: "artifact-removal-fbcnn",
                    enabled: artifactRemovalEnabled,
                    parameters: try ParameterBag(artifactRemovalParams)
                ),
                .init(
                    stageID: "denoise-nafnet",
                    enabled: denoiseEnabled,
                    parameters: try ParameterBag(denoiseParams)
                ),
                .init(
                    stageID: "upscale",
                    enabled: upscaleEnabled,
                    parameters: try ParameterBag(upscaleParams)
                ),
                .init(
                    stageID: "sharpen-unsharp-mask",
                    enabled: sharpenEnabled,
                    parameters: try ParameterBag(sharpenParams)
                ),
            ]
            let base = loadedSidecar ?? EnhanceSidecar()
            let updated = base.replacingSteps(with: knownSteps)
            try updated.save(for: url)
            loadedSidecar = updated
            recipeDirty = false
            recipeWarning = nil
        } catch {
            recipeWarning = "Couldn't save the enhancement recipe for \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func matchesGeneration(_ gen: UInt64) -> Bool {
        gen == loadGeneration
    }

    private func matchesPipelineGeneration(_ gen: UInt64) -> Bool {
        gen == pipelineGeneration
    }

    private func cancelPipeline(clearProcessing: Bool) {
        pipelineGeneration &+= 1
        pipelineTask?.cancel()
        pipelineTask = nil
        if clearProcessing {
            isProcessing = false
        }
    }

    private func cancelFullBufferLoad() {
        fullBufferReadCoordinator.cancelRequest(for: fullBufferLoadURL)
        fullBufferLoadTask?.cancel()
        fullBufferLoadTask = nil
        fullBufferLoadGeneration = nil
        fullBufferLoadURL = nil
    }

    private func applyFullBufferLoadOutcome(
        _ outcome: FullBufferReadOutcome,
        url: URL,
        generation myGen: UInt64
    ) {
        guard fullBufferLoadGeneration == myGen,
              fullBufferLoadURL == url else { return }

        fullBufferLoadTask = nil
        fullBufferLoadGeneration = nil
        fullBufferLoadURL = nil

        guard myGen == loadGeneration, currentURL == url else { return }

        switch outcome {
        case .success(let buffer, let metadata):
            originalBuffer = buffer
            originalMetadata = metadata
            // Render the working-format buffer once and cache it. Falls back
            // to previewCGImage in `originalDisplayImage` if this is somehow nil.
            originalCGImage = try? buffer.makeCGImage()
            runPipeline()
        case .failure(let error):
            guard !Self.isCancellation(error) else { return }
            lastError = "Read failed: \(error.localizedDescription)"
        case .cancelled:
            return
        }
    }

    private func applyPipelineResult(_ result: Result<ImageBuffer, Error>, pipelineGeneration myPipelineGen: UInt64) {
        guard matchesPipelineGeneration(myPipelineGen) else { return }
        isProcessing = false
        pipelineTask = nil
        switch result {
        case .success(let buffer):
            enhancedBuffer = buffer
            // Cache the rendered CGImage so paneView doesn't redo the
            // float16 → CGImage bridge on every body call.
            enhancedCGImage = try? buffer.makeCGImage()
            lastError = nil
        case .failure(let error):
            // PipelineError.cancelled is expected on rapid edits — don't
            // surface it as a user-facing error.
            guard !Self.isCancellation(error) else { return }
            lastError = "Pipeline failed: \(error.localizedDescription)"
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let pErr = error as? PipelineError, case .cancelled = pErr { return true }
        return false
    }

    private func buildSteps() -> [PipelineStep] {
        // Each stage's effective-enabled is (user toggle) AND (the stage is
        // actually operational — i.e., either classical or has its model
        // installed, or has a useful fallback). Placebo stages get gated off
        // here so the pipeline never wastes a step on identity passthrough,
        // even if the user hasn't manually toggled them off in the UI.
        [
            PipelineStep(
                stage: AnyStage(ArtifactRemoval(), params: artifactRemovalParams),
                enabled: artifactRemovalEnabled
                    && StageStatusResolver.artifactRemoval().isOperational
            ),
            PipelineStep(
                stage: AnyStage(Denoise(), params: denoiseParams),
                enabled: denoiseEnabled
                    && StageStatusResolver.denoise().isOperational
            ),
            PipelineStep(
                stage: AnyStage(Upscale(), params: upscaleParams),
                enabled: upscaleEnabled
                    && StageStatusResolver.upscale(params: upscaleParams).isOperational
            ),
            PipelineStep(
                stage: AnyStage(Sharpen(), params: sharpenParams),
                enabled: sharpenEnabled
                    && StageStatusResolver.sharpen().isOperational
            ),
        ]
    }
}

// MARK: - Compare mode

/// What DetailView should display when comparing original vs enhanced.
enum CompareMode: String, CaseIterable, Sendable, Identifiable {
    case enhanced
    case original
    case sideBySide

    var id: String { rawValue }
    var label: String {
        switch self {
        case .enhanced:   "Enhanced"
        case .original:   "Original"
        case .sideBySide: "Side-by-side"
        }
    }
    var symbol: String {
        switch self {
        case .enhanced:   "wand.and.stars"
        case .original:   "photo"
        case .sideBySide: "rectangle.split.2x1"
        }
    }
}

// (NSImage helper removed — display pipeline now uses CGImage directly to
// preserve source color spaces and skip an unnecessary copy.)
