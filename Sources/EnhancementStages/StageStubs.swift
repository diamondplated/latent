import Foundation
import PipelineCore

/// All stages currently return their input unchanged. The DAG, caching,
/// progress reporting, and sidecar serialization are exercised end-to-end;
/// the actual ML inference is the next milestone (CoreML model loading,
/// tile-based execution, alpha-blending for face restore).
///
/// Each stage's parameters are real and final — adding ML below them does
/// not change the public surface.

// MARK: - Compression artifact removal (FBCNN)

public struct ArtifactRemoval: Stage {
    public struct Params: StageParameters, Codable {
        public var strength: Double  // 0.0 = bypass-equivalent, 1.0 = max removal
        public var qualityHint: Int? // pre-computed JPEG quality if known

        public init(strength: Double = 0.7, qualityHint: Int? = nil) {
            self.strength = strength
            self.qualityHint = qualityHint
        }
    }

    public let id: StageID = "artifact-removal-fbcnn"
    public let displayName = "Artifact Removal"
    public init() {}

    public func process(input: ImageBuffer, params: Params, progress: ProgressReporter) async throws -> ImageBuffer {
        progress.report(0.0)
        try await Task.sleep(nanoseconds: 1_000_000) // simulate work; replaced by FBCNN inference
        progress.report(1.0)
        return input
    }
}

// MARK: - Denoise (NAFNet)

public struct Denoise: Stage {
    public struct Params: StageParameters, Codable {
        public var strength: Double          // 0.0 = bypass, 1.0 = max
        public var preserveDetailBias: Double // 0.0 = clean, 1.0 = preserve grain/detail

        public init(strength: Double = 0.6, preserveDetailBias: Double = 0.5) {
            self.strength = strength
            self.preserveDetailBias = preserveDetailBias
        }
    }

    public let id: StageID = "denoise-nafnet"
    public let displayName = "Denoise"
    public init() {}

    public func process(input: ImageBuffer, params: Params, progress: ProgressReporter) async throws -> ImageBuffer {
        progress.report(0.0)
        try await Task.sleep(nanoseconds: 1_000_000)
        progress.report(1.0)
        return input
    }
}

// MARK: - Face restore (GFPGAN)

public struct FaceRestore: Stage {
    public struct Params: StageParameters, Codable {
        public var strength: Double            // 0.0 = bypass, 1.0 = max
        public var minFaceSize: Int            // pixels; faces smaller than this are skipped
        public var identityPreserveBias: Double // 0.0 = enhance more, 1.0 = preserve identity

        public init(strength: Double = 0.7, minFaceSize: Int = 64, identityPreserveBias: Double = 0.7) {
            self.strength = strength
            self.minFaceSize = minFaceSize
            self.identityPreserveBias = identityPreserveBias
        }
    }

    public let id: StageID = "face-restore-gfpgan"
    public let displayName = "Face Restore"
    public init() {}

    public func process(input: ImageBuffer, params: Params, progress: ProgressReporter) async throws -> ImageBuffer {
        progress.report(0.0)
        try await Task.sleep(nanoseconds: 1_000_000)
        progress.report(1.0)
        return input
    }
}

// MARK: - Upscale (Real-ESRGAN)

public struct Upscale: Stage {
    public enum Model: String, Codable, Sendable {
        case realESRGANx4plus
        case swinIRLarge
    }

    public struct Params: StageParameters, Codable {
        public var scale: Int       // 2 or 4
        public var model: Model
        public var tileSize: Int    // px; larger = fewer seams, more memory

        public init(scale: Int = 2, model: Model = .realESRGANx4plus, tileSize: Int = 512) {
            precondition(scale == 2 || scale == 4, "Only 2x and 4x are supported")
            self.scale = scale
            self.model = model
            self.tileSize = tileSize
        }
    }

    public let id: StageID = "upscale"
    public let displayName = "Upscale"
    public init() {}

    public func process(input: ImageBuffer, params: Params, progress: ProgressReporter) async throws -> ImageBuffer {
        progress.report(0.0)
        try await Task.sleep(nanoseconds: 1_000_000)
        progress.report(1.0)
        // Real impl will produce a buffer of size (input.width * scale, input.height * scale).
        // Stub returns input unchanged so the pipeline plumbing is testable without ML.
        return input
    }
}

// MARK: - Sharpen (final, classical unsharp mask)

public struct Sharpen: Stage {
    public struct Params: StageParameters, Codable {
        public var amount: Double  // 0.0 = bypass, 2.0 = aggressive
        public var radius: Double  // px
        public var threshold: Double // 0.0 = sharpen everything, higher = skip flat areas

        public init(amount: Double = 0.6, radius: Double = 1.0, threshold: Double = 0.0) {
            self.amount = amount
            self.radius = radius
            self.threshold = threshold
        }
    }

    public let id: StageID = "sharpen-unsharp-mask"
    public let displayName = "Sharpen"
    public init() {}

    public func process(input: ImageBuffer, params: Params, progress: ProgressReporter) async throws -> ImageBuffer {
        progress.report(0.0)
        try await Task.sleep(nanoseconds: 1_000_000)
        progress.report(1.0)
        return input
    }
}

// MARK: - Default pipeline factory

public enum StandardPipeline {
    /// Builds the canonical 5-stage pipeline in correct order with default parameters.
    public static func defaultSteps() -> [PipelineStep] {
        [
            PipelineStep(stage: AnyStage(ArtifactRemoval(), params: .init())),
            PipelineStep(stage: AnyStage(Denoise(), params: .init())),
            PipelineStep(stage: AnyStage(FaceRestore(), params: .init())),
            PipelineStep(stage: AnyStage(Upscale(), params: .init(scale: 2))),
            PipelineStep(stage: AnyStage(Sharpen(), params: .init())),
        ]
    }
}
