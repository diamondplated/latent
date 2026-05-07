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

    var artifactRemovalEnabled: Bool = true
    var artifactRemovalParams: ArtifactRemoval.Params = .init()

    var denoiseEnabled: Bool = true
    var denoiseParams: Denoise.Params = .init()

    var faceRestoreEnabled: Bool = true
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

    /// User-selected comparison mode. `displayMode` adds the transient blink
    /// override on top.
    var compareMode: CompareMode = .enhanced
    /// True while the user holds the blink key (B). Forces the original view
    /// momentarily; on release falls back to `compareMode`.
    var blinking: Bool = false

    /// What DetailView should actually render right now. Combines compareMode
    /// with the transient blink state.
    var displayMode: CompareMode {
        blinking ? .original : compareMode
    }

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

        currentURL = url
        originalBuffer = nil
        enhancedBuffer = nil
        originalMetadata = nil
        lastError = nil

        // Read off the main actor — decode is CPU-heavy.
        let result: Result<(ImageBuffer, ImageMetadata), Error> = await Task.detached(priority: .userInitiated) { [reader] in
            do {
                let pair = try reader.read(url: url)
                return .success(pair)
            } catch {
                return .failure(error)
            }
        }.value

        // Bail out if a newer load superseded us.
        guard myGen == loadGeneration else { return }

        switch result {
        case .success(let (buffer, metadata)):
            originalBuffer = buffer
            originalMetadata = metadata
            runPipeline()
        case .failure(let error):
            lastError = "Read failed: \(error.localizedDescription)"
        }
    }

    /// Cancel any running pipeline and start a new one with the current
    /// stage state. Safe to call from any UI binding (slider edit, toggle).
    func runPipeline() {
        guard let input = originalBuffer else { return }

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
        guard let url = currentURL,
              let buffer = enhancedBuffer ?? originalBuffer else {
            lastError = "Nothing to save."
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
        // The order here matches StandardPipeline.defaultSteps. Stage IDs are
        // unique within the chain (Pipeline preconditions on this), so we list
        // each stage exactly once and rely on the `enabled` flag to bypass.
        [
            PipelineStep(
                stage: AnyStage(ArtifactRemoval(), params: artifactRemovalParams),
                enabled: artifactRemovalEnabled
            ),
            PipelineStep(
                stage: AnyStage(Denoise(), params: denoiseParams),
                enabled: denoiseEnabled
            ),
            PipelineStep(
                stage: AnyStage(FaceRestore(), params: faceRestoreParams),
                enabled: faceRestoreEnabled
            ),
            PipelineStep(
                stage: AnyStage(Upscale(), params: upscaleParams),
                enabled: upscaleEnabled
            ),
            PipelineStep(
                stage: AnyStage(Sharpen(), params: sharpenParams),
                enabled: sharpenEnabled
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
