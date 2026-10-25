import Foundation
import AppKit
import SwiftUI
import PipelineCore
import EnhancementStages
import PhotoIO

// What the editor UI calls: loading input, editing stages, compare, export.

@MainActor
extension EnhancementState {
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
        previewTask: Task<CGImage?, Never>? = nil,
        forceReload: Bool = false
    ) async {
        // If the user re-clicks the same URL we're already on, do nothing —
        // avoids a redundant re-decode and pipeline run when the selection
        // change in DetailView fires `.task(id:)` on the same URL.
        if !forceReload, currentURL == url, originalBuffer != nil { return }

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
}
