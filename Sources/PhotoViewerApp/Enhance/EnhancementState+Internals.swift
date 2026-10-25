import Foundation
import AppKit
import SwiftUI
import PipelineCore
import EnhancementStages
import PhotoIO

// Pipeline runs, recipe persistence and buffer bookkeeping behind the API.

@MainActor
extension EnhancementState {
    // MARK: - Private

    /// True while defaults or a sidecar are being applied programmatically.
    /// Property observers otherwise cannot distinguish that work from a user
    /// dragging a slider.
    func withRecipeTrackingSuppressed(_ body: () -> Void) {
        let wasSuppressed = suppressRecipeTracking
        suppressRecipeTracking = true
        body()
        suppressRecipeTracking = wasSuppressed
    }

    func applyDefaultRecipe() {
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

    func apply(sidecar: EnhanceSidecar) throws {
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

    func recipeSettingDidChange() {
        guard !suppressRecipeTracking else { return }
        recipeDirty = true
        lastExportedURL = nil
    }

    var isUsingDefaultRecipe: Bool {
        !artifactRemovalEnabled
            && artifactRemovalParams == ArtifactRemoval.Params()
            && !denoiseEnabled
            && denoiseParams == Denoise.Params()
            && upscaleEnabled
            && upscaleParams == Upscale.Params()
            && sharpenEnabled
            && sharpenParams == Sharpen.Params()
    }

    func persistRecipeIfNeeded() {
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

    func matchesGeneration(_ gen: UInt64) -> Bool {
        gen == loadGeneration
    }

    func matchesPipelineGeneration(_ gen: UInt64) -> Bool {
        gen == pipelineGeneration
    }

    func cancelPipeline(clearProcessing: Bool) {
        pipelineGeneration &+= 1
        pipelineTask?.cancel()
        pipelineTask = nil
        if clearProcessing {
            isProcessing = false
        }
    }

    func cancelFullBufferLoad() {
        fullBufferReadCoordinator.cancelRequest(for: fullBufferLoadURL)
        fullBufferLoadTask?.cancel()
        fullBufferLoadTask = nil
        fullBufferLoadGeneration = nil
        fullBufferLoadURL = nil
    }

    func applyFullBufferLoadOutcome(
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

    func applyPipelineResult(_ result: Result<ImageBuffer, Error>, pipelineGeneration myPipelineGen: UInt64) {
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

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let pErr = error as? PipelineError, case .cancelled = pErr { return true }
        return false
    }

    func buildSteps() -> [PipelineStep] {
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
