import Foundation
import PipelineCore
import PhotoML

/// Run a CoreML image-to-image model over `input` with tile-based execution.
/// If the model file isn't present in the registry, returns input unchanged
/// (identity fallback for stages where preserving dims requires no resampling).
///
/// Used by Denoise and ArtifactRemoval (both are scale-1 transforms whose
/// natural fallback is "do nothing"). Upscale has its own helper because its
/// fallback is Lanczos resize, not identity.
@Sendable
func runModelOrPassthrough(
    input: ImageBuffer,
    modelID: ModelID,
    spec: TensorSpec,
    tileSize: Int,
    progress: ProgressReporter
) async throws -> ImageBuffer {
    let model = try await ModelManager.shared.model(for: modelID, spec: spec)
    guard let model else {
        // No model on disk — degrade gracefully. Stage doesn't claim its
        // strength took effect; downstream stages just see the unmodified
        // pixels. Caller can detect this via ModelRegistry.url(for:) being nil.
        return input
    }
    let executor = TileExecutor(tileSize: tileSize, overlap: 32, scale: 1)
    return try await executor.execute(input: input, progress: progress) { tile in
        try await model.predict(tile)
    }
}
