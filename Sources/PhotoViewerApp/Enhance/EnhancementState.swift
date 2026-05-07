import Foundation
import AppKit
import SwiftUI
import PipelineCore
import EnhancementStages
import PhotoIO

/// Single source of truth for the in-app enhancement editor.
///
/// Lifecycle:
///   1. `loadInput(url:)` reads pixels via `ImageReader` and kicks off
///      the first pipeline run.
///   2. Any param/enable change calls `runPipeline()` which cancels the
///      in-flight task and starts a new one. Upstream stages cache-hit on
///      identical params, so only the changed stage and below recompute.
///   3. `saveEnhanced()` writes the latest `enhancedBuffer` (or original
///      if no enhanced result yet) to `<stem>_enhanced.<ext>`.
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
    var artifactRemovalEnabled: Bool = false
    var artifactRemovalParams: ArtifactRemoval.Params = .init()

    var denoiseEnabled: Bool = false
    var denoiseParams: Denoise.Params = .init()

    var faceRestoreEnabled: Bool = false
    var faceRestoreParams: FaceRestore.Params = .init()

    var upscaleEnabled: Bool = true
    var upscaleParams: Upscale.Params = .init()

    var sharpenEnabled: Bool = true
    var sharpenParams: Sharpen.Params = .init()

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

    /// Fast-path NSImage shown immediately on selection change so navigation
    /// feels instant. Loaded via NSImage(contentsOf:) — orders of magnitude
    /// faster than the full color-managed `ImageReader.read()` path because
    /// it skips conversion to linear sRGB float16. The "real" pipeline-ready
    /// buffer arrives later via `originalBuffer`.
    private(set) var previewNSImage: NSImage? = nil
    /// Rendered NSImage of `originalBuffer`, cached so SwiftUI doesn't redo
    /// the float16 → CGImage bridge on every body() call. nil before the
    /// working buffer is ready; falls back to `previewNSImage` in `displayedNSImage`.
    private(set) var originalNSImage: NSImage? = nil
    /// Rendered NSImage of `enhancedBuffer`, cached likewise.
    private(set) var enhancedNSImage: NSImage? = nil

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

    /// NSImage to render in the "original" pane. Falls back through:
    ///   1. fully-decoded working buffer (color-managed, slowest to arrive)
    ///   2. fast preview from NSImage(contentsOf:) (instant)
    ///   3. nil → caller shows skeleton
    var originalDisplayImage: NSImage? { originalNSImage ?? previewNSImage }

    /// NSImage to render in the "enhanced" pane. Falls back through:
    ///   1. pipeline output (slowest to arrive)
    ///   2. original buffer (so user sees something during enhancement)
    ///   3. fast preview
    ///   4. nil
    var enhancedDisplayImage: NSImage? {
        enhancedNSImage ?? originalNSImage ?? previewNSImage
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

    // MARK: - Pipeline plumbing

    /// Shared across loads — cache keys are content-hashed, so loading a new
    /// image doesn't poison hits for the old one. 256 MiB ceiling is enough
    /// for several intermediates of a typical photo at working format.
    let cache = IntermediateCache(maxBytes: 256 * 1024 * 1024)
    private let reader = ImageReader()
    private let writer = ImageWriter()

    /// In-flight pipeline run, if any. Replaced (and cancelled) on every edit.
    private var pipelineTask: Task<Void, Never>? = nil
    /// Token for the most recent `loadInput` so a slow read for an old URL
    /// can't clobber state set by a later URL.
    private var loadGeneration: UInt64 = 0

    init() {}

    // MARK: - Public API

    /// Load a photo from disk into the editor and run the pipeline once.
    /// Calling again with a different URL cancels the previous run.
    ///
    /// Two-phase load:
    ///   1. Fast preview: NSImage(contentsOf:) on a detached task — typically
    ///      ~50-150ms for a 14MP JPEG, no color management overhead. Shown
    ///      immediately so navigation feels instant.
    ///   2. Full buffer: ImageReader.read() does the linear-sRGB float16
    ///      conversion needed by the pipeline. Hundreds of ms — happens in
    ///      the background, then runPipeline() kicks off.
    func loadInput(url: URL) async {
        // If the user re-clicks the same URL we're already on, do nothing —
        // avoids a redundant re-decode and pipeline run when the selection
        // change in DetailView fires `.task(id:)` on the same URL.
        if currentURL == url, originalBuffer != nil { return }

        loadGeneration &+= 1
        let myGen = loadGeneration

        // Cancel any in-flight pipeline for the previous image.
        pipelineTask?.cancel()
        pipelineTask = nil

        // KEY: do NOT nil the previous photo's NSImages here. Keep showing
        // the last image while the new one decodes. When the new preview
        // lands the swap is instant, no skeleton flash, no fade-from-black.
        // Buffers are nilled because `runPipeline` would otherwise try to
        // re-process the OLD buffer with the new params.
        currentURL = url
        originalBuffer = nil
        enhancedBuffer = nil
        originalMetadata = nil
        lastError = nil

        // Phase 1: fast full-resolution preview. Decode via CGImageSource
        // (NOT NSImage(contentsOf:) which can lazy-load a smaller
        // representation) and wrap with explicit native size so the display
        // gets the actual pixels at full quality. Honors EXIF orientation
        // via `kCGImageSourceCreateThumbnailWithTransform` on the read path.
        async let previewTask: NSImage? = Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                return nil
            }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value

        // Apply the preview first so the UI swaps to the new photo
        // immediately. Same-step nil out the cached NSImages of the
        // previous photo so we don't keep displaying stale content if
        // the preview decode took longer than a vsync.
        let preview = await previewTask
        if myGen == loadGeneration {
            previewNSImage = preview
            originalNSImage = nil
            enhancedNSImage = nil
        }

        // Phase 2: full pipeline-ready buffer + metadata. Only kick this off
        // when there's a reason to — i.e. the user is in a mode that needs
        // the enhanced output, OR they're going to need it for Apply & Save.
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
        if originalBuffer != nil, currentURL == url { return }

        let result: Result<(ImageBuffer, ImageMetadata), Error> = await Task.detached(priority: .userInitiated) { [reader] in
            do {
                let pair = try reader.read(url: url)
                return .success(pair)
            } catch {
                return .failure(error)
            }
        }.value

        guard myGen == loadGeneration else { return }

        switch result {
        case .success(let (buffer, metadata)):
            originalBuffer = buffer
            originalMetadata = metadata
            // Render the working-format buffer once and cache it. Falls back
            // to previewNSImage in `displayedNSImage` if this is somehow nil.
            originalNSImage = buffer.makeNSImage()
            runPipeline()
        case .failure(let error):
            lastError = "Read failed: \(error.localizedDescription)"
        }
    }

    /// Called by the UI when the user changes compare mode. Triggers the
    /// heavy buffer load + pipeline if we don't already have an enhanced
    /// result for the current photo.
    func ensureEnhancedAvailable() {
        guard let url = currentURL else { return }
        if enhancedBuffer == nil {
            Task { await loadFullBuffer(url: url, generation: loadGeneration) }
        }
    }

    /// Cancel any running pipeline and start a new one with the current
    /// stage state. Safe to call from any UI binding (slider edit, toggle).
    /// If the heavy decode hasn't run yet (lazy default), kick that off
    /// first; the pipeline runs as a continuation when it lands.
    func runPipeline() {
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

        pipelineTask?.cancel()
        let steps = buildSteps()
        let pipeline = Pipeline(steps: steps, cache: cache)
        let myGen = loadGeneration

        isProcessing = true

        pipelineTask = Task { [weak self] in
            // Run off the main actor — Pipeline.run is async but the
            // CoreImage / ML work inside stages benefits from being
            // detached so SwiftUI binding writes don't queue behind it.
            let runResult: Result<ImageBuffer, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let out = try await pipeline.run(input: input)
                    return .success(out)
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self else { return }
            // Drop the result if the user moved on to a different image.
            guard self.matchesGeneration(myGen) else { return }
            self.applyPipelineResult(runResult)
        }
    }

    /// Write `enhancedBuffer` (falling back to `originalBuffer`) next to the
    /// source as `<stem>_enhanced.<ext>`. Overwrites if the destination
    /// already exists.
    func saveEnhanced() async {
        guard let url = currentURL else {
            lastError = "Nothing to save."
            return
        }
        // Lazy-load the heavy buffer if we don't have it yet. Apply & Save
        // works even when the user has been browsing in .original mode.
        if originalBuffer == nil {
            await loadFullBuffer(url: url, generation: loadGeneration)
            // Wait for any pipeline triggered by loadFullBuffer to complete.
            await pipelineTask?.value
        }
        guard let buffer = enhancedBuffer ?? originalBuffer else {
            lastError = "Failed to load image for save."
            return
        }
        let dest = Self.outputURL(for: url)
        let metadata = originalMetadata
        let writer = self.writer

        let writeResult: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
            do {
                try writer.write(buffer: buffer, metadata: metadata, to: dest)
                return .success(())
            } catch {
                return .failure(error)
            }
        }.value

        switch writeResult {
        case .success:
            lastError = nil
        case .failure(let error):
            lastError = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Output URL for `Apply & Save`: `<dir>/<stem>_enhanced.<ext>`. Keeps the
    /// file in the source folder so the existing folder watcher picks it up.
    static func outputURL(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension
        return dir.appendingPathComponent("\(stem)_enhanced.\(ext)")
    }

    // MARK: - Private

    private func matchesGeneration(_ gen: UInt64) -> Bool {
        gen == loadGeneration
    }

    private func applyPipelineResult(_ result: Result<ImageBuffer, Error>) {
        isProcessing = false
        switch result {
        case .success(let buffer):
            enhancedBuffer = buffer
            // Cache the rendered NSImage so paneView doesn't redo the
            // float16 → CGImage bridge on every body call.
            enhancedNSImage = buffer.makeNSImage()
            lastError = nil
        case .failure(let error):
            // PipelineError.cancelled is expected on rapid edits — don't
            // surface it as a user-facing error.
            if let pErr = error as? PipelineError, case .cancelled = pErr { return }
            if error is CancellationError { return }
            lastError = "Pipeline failed: \(error.localizedDescription)"
        }
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
                stage: AnyStage(FaceRestore(), params: faceRestoreParams),
                enabled: faceRestoreEnabled
                    && StageStatusResolver.faceRestore().isOperational
            ),
            PipelineStep(
                stage: AnyStage(Upscale(), params: upscaleParams),
                enabled: upscaleEnabled
                    && StageStatusResolver.upscale(scale: upscaleParams.scale).isOperational
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

// MARK: - NSImage helper

extension ImageBuffer {
    /// Render the buffer as an NSImage suitable for SwiftUI display. Returns
    /// nil if the bridge fails (shouldn't happen for well-formed working
    /// buffers).
    func makeNSImage() -> NSImage? {
        guard let cg = try? makeCGImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
