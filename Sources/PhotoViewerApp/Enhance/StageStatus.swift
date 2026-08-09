import SwiftUI
import EnhancementStages
import PhotoML

/// What a stage will actually do on the next pipeline run, based on whether
/// its CoreML model is installed. Drives the per-stage status badge so the
/// user can tell at a glance which toggles are real vs placebo.
enum StageStatus: Equatable {
    /// Classical algorithm; no model needed. Always real.
    case classical
    /// ML model installed — full inference path active.
    case mlActive
    /// ML model missing, but the stage degrades gracefully to a useful
    /// non-ML fallback (e.g., Upscale → Lanczos resize). Honest: it does
    /// SOMETHING, just not what the model name implies.
    case mlMissingWithFallback(fallbackName: String)
    /// ML model missing and there's no fallback — the toggle does nothing.
    /// We disable it in the UI so the user isn't lied to.
    case mlMissingPlacebo

    /// Color for the per-stage indicator dot.
    var dotColor: Color {
        switch self {
        case .classical, .mlActive: .green
        case .mlMissingWithFallback: .orange
        case .mlMissingPlacebo: .gray
        }
    }

    /// Short label shown in the section header alongside the title.
    var badge: String? {
        switch self {
        case .classical: nil
        case .mlActive: "model installed"
        case .mlMissingWithFallback(let name): "\(name) fallback"
        case .mlMissingPlacebo: "no model — disabled"
        }
    }

    /// True when the stage's toggle should actually be interactive. False
    /// for placebo stages (the toggle would do literally nothing).
    var isOperational: Bool {
        switch self {
        case .classical, .mlActive, .mlMissingWithFallback: true
        case .mlMissingPlacebo: false
        }
    }
}

/// Resolve the live status of each pipeline stage based on which `.mlpackage`
/// files are currently in the model registry. Re-runs cheap-ish (one fs stat
/// per stage) so it's safe to call from a SwiftUI view body.
enum StageStatusResolver {
    static func artifactRemoval() -> StageStatus {
        ModelRegistry.url(for: .artifactRemovalFBCNN) != nil
            ? .mlActive
            : .mlMissingPlacebo
    }

    static func denoise() -> StageStatus {
        ModelRegistry.url(for: .denoiseNAFNet) != nil
            ? .mlActive
            : .mlMissingPlacebo
    }


    /// Upscale degrades to Lanczos resize when no model is present — real
    /// resampling, just not ML super-resolution. Worth distinguishing from
    /// the pure placebo cases so the user knows pixel dims will still change.
    static func upscale(params: Upscale.Params) -> StageStatus {
        if ModelRegistry.url(for: upscaleModelID(for: params)) != nil {
            return .mlActive
        }
        return params.scale == 1 ? .classical : .mlMissingWithFallback(fallbackName: "Lanczos")
    }

    /// Always classical — Sharpen uses Core Image's CIUnsharpMask, no ML.
    static func sharpen() -> StageStatus { .classical }

    private static func upscaleModelID(for params: Upscale.Params) -> ModelID {
        switch (params.model, params.scale) {
        case (.realESRGANx4plus, 4): .upscaleRealESRGANx4
        case (.realESRGANx4plus, 2): .upscaleRealESRGANx2
        case (.swinIRLarge, _):       .upscaleSwinIRLarge
        default:                      .upscaleRealESRGANx2
        }
    }
}
