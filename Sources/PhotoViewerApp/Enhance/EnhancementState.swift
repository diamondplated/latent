import Foundation
import AppKit
import SwiftUI
import PipelineCore
import EnhancementStages
import PhotoIO

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
    internal(set) var currentURL: URL? = nil
    /// Pre-pipeline pixels in the working format. `nil` while loading or on read error.
    internal(set) var originalBuffer: ImageBuffer? = nil
    /// Pipeline output. `nil` until the first run completes (or while one is running).
    internal(set) var enhancedBuffer: ImageBuffer? = nil
    /// Metadata captured at read time; passed back to the writer on save so
    /// EXIF/color-space round-trips correctly.
    internal(set) var originalMetadata: ImageMetadata? = nil

    /// Fast-path full-resolution CGImage shown immediately on selection
    /// change so navigation feels instant. Decoded via CGImageSource (no
    /// NSImage middleman that can pick a smaller representation, and
    /// preserves the source's color space — Display P3 / Adobe RGB photos
    /// stay in their native gamut all the way to the SwiftUI Image view).
    internal(set) var previewCGImage: CGImage? = nil
    /// CGImage of `originalBuffer`, cached so SwiftUI doesn't redo the
    /// float16 → CGImage bridge on every body() call. nil before the
    /// working buffer is ready; `originalDisplayImage` falls back to
    /// `previewCGImage`.
    internal(set) var originalCGImage: CGImage? = nil
    /// CGImage of `enhancedBuffer`, cached likewise.
    internal(set) var enhancedCGImage: CGImage? = nil

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
    internal(set) var isProcessing: Bool = false
    /// Last error the pipeline or I/O surfaced; nil if none.
    internal(set) var lastError: String? = nil
    /// Non-fatal recipe persistence problem. Kept separate from processing
    /// errors so a successful pipeline run cannot erase an important warning
    /// about a sidecar the app could not read or update.
    internal(set) var recipeWarning: String? = nil
    /// Destination of the most recent successful export for this image. The
    /// panel uses it as explicit success feedback instead of making a silent
    /// filesystem write.
    internal(set) var lastExportedURL: URL? = nil
    /// True while an export is preparing or committing its output file.
    internal(set) var isExporting: Bool = false

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
    let writer = ImageWriter()
    let fullBufferReadCoordinator = FullBufferReadCoordinator()

    /// In-flight pipeline run, if any. Replaced (and cancelled) on every edit.
    var pipelineTask: Task<Void, Never>? = nil
    /// Token for the newest pipeline run. Separate from loadGeneration so
    /// cancelled edits for the same image can't clear a newer run's state.
    var pipelineGeneration: UInt64 = 0
    /// Token for the most recent `loadInput` so a slow read for an old URL
    /// can't clobber state set by a later URL.
    var loadGeneration: UInt64 = 0
    /// Shared full-buffer load so compare-mode switches and slider edits do
    /// not pile up duplicate ImageReader work for the same image.
    var fullBufferLoadTask: Task<Void, Never>? = nil
    var fullBufferLoadGeneration: UInt64? = nil
    var fullBufferLoadURL: URL? = nil
    /// Sidecar originally loaded for this image. Retained so a save can replace
    /// known stages while round-tripping stages introduced by newer versions.
    var loadedSidecar: EnhanceSidecar? = nil
    var recipeDirty = false
    var suppressRecipeTracking = false
    /// Keeps controls disabled while the selected image's recipe is loading,
    /// preventing a fast edit from being overwritten by a late sidecar read.
    internal(set) var isLoadingRecipe = false
    /// A sidecar that failed to decode may contain newer top-level data. Do not
    /// overwrite it merely because this older build changed a slider.
    var recipePersistenceBlocked = false
    var currentMediaSupportsEnhancements = false
    var exportGeneration: UInt64 = 0

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
