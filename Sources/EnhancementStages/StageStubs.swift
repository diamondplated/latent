import Foundation
import CoreImage
import CoreGraphics
import PipelineCore
import PhotoML

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
        if params.strength == 0 { return input }
        return try await runModelOrPassthrough(
            input: input,
            modelID: .artifactRemovalFBCNN,
            spec: .fbcnn,
            tileSize: 256,
            progress: progress
        )
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
        if params.strength == 0 { return input }
        return try await runModelOrPassthrough(
            input: input,
            modelID: .denoiseNAFNet,
            spec: .nafnet,
            tileSize: 256,
            progress: progress
        )
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

    /// Algorithm:
    ///   1. Detect faces (Apple Vision)
    ///   2. For each face: pad bounds, crop, resize to model input (512×512),
    ///      run model, resize back to crop dims
    ///   3. Composite each restored face into a copy of input with feathered
    ///      alpha at face-region edges
    /// Falls back to identity if (a) no faces detected, (b) all faces below
    /// minFaceSize, or (c) the model file isn't available.
    public func process(input: ImageBuffer, params: Params, progress: ProgressReporter) async throws -> ImageBuffer {
        progress.report(0.0)
        defer { progress.report(1.0) }

        if params.strength == 0 { return input }

        let detector = FaceDetector()
        let faces = try await detector.detect(in: input)
            .filter { Int($0.bounds.width) >= params.minFaceSize && Int($0.bounds.height) >= params.minFaceSize }

        if faces.isEmpty { return input }

        let model = try await ModelManager.shared.model(for: .faceRestoreGFPGAN, spec: .gfpgan)
        guard let model else { return input }

        // GFPGAN's standard input size.
        let modelInputSize = 512
        // The reference identity-preserve bias maps to a strength multiplier:
        // higher bias = lighter blend (more original face preserved). At
        // identityPreserveBias=0, full strength; at 1, blend factor halves.
        let blendStrength = Float(params.strength) * (1.0 - 0.5 * Float(params.identityPreserveBias))

        var result = input
        for (i, face) in faces.enumerated() {
            let rect = FaceComposite.paddedFaceRect(
                face: face,
                imageWidth: input.width,
                imageHeight: input.height
            )
            let crop = FaceComposite.crop(input, rect: rect)
            let modelInput = try FaceComposite.resize(crop, toWidth: modelInputSize, height: modelInputSize)
            let modelOutput = try await model.predict(modelInput)
            let restored = try FaceComposite.resize(modelOutput, toWidth: Int(rect.width), height: Int(rect.height))

            result = FaceComposite.blend(
                base: result,
                restored: restored,
                atRect: rect,
                featherWidth: 16,
                strength: blendStrength
            )
            progress.report(Double(i + 1) / Double(faces.count))
        }
        return result
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
        defer { progress.report(1.0) }

        let modelID = modelID(for: params)

        let model = try await ModelManager.shared.model(for: modelID, spec: .realESRGANx2)

        if let model {
            let executor = TileExecutor(tileSize: params.tileSize, overlap: 32, scale: params.scale)
            return try await executor.execute(input: input, progress: progress) { tile in
                try await model.predict(tile)
            }
        }

        // Fallback: Lanczos resize via Core Image. Same output dimensions as
        // ML path, so the rest of the pipeline doesn't care which ran.
        return try lanczosResize(input: input, scale: params.scale)
    }

    private func lanczosResize(input: ImageBuffer, scale: Int) throws -> ImageBuffer {
        guard scale > 1 else { return input }
        let inputCG = try input.makeCGImage()
        let ciImage = CIImage(cgImage: inputCG)
        let scaled = ciImage.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: Double(scale),
            kCIInputAspectRatioKey: 1.0,
        ])
        let outW = input.width * scale
        let outH = input.height * scale
        let workingSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let context = CIContext(options: [.workingColorSpace: workingSpace])
        guard let outCG = context.createCGImage(
            scaled,
            from: CGRect(x: 0, y: 0, width: outW, height: outH),
            format: .RGBA16,
            colorSpace: workingSpace
        ) else {
            throw CoreMLModelError.predictionFailed(NSError(
                domain: "PhotoUpscale", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Lanczos resize failed"]
            ))
        }
        return try ImageBuffer.fromCGImage(outCG)
    }

    private func modelID(for params: Params) -> ModelID {
        switch (params.model, params.scale) {
        case (.realESRGANx4plus, 4): .upscaleRealESRGANx4
        case (.realESRGANx4plus, 2): .upscaleRealESRGANx2
        case (.swinIRLarge, _):       .upscaleSwinIRLarge
        default:                      .upscaleRealESRGANx2
        }
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
        defer { progress.report(1.0) }

        // Bypass for amount=0 — avoids the CGImage round-trip when stage is a no-op.
        if params.amount == 0 { return input }

        let inputCG = try input.makeCGImage()
        let ciImage = CIImage(cgImage: inputCG)
        // Core Image's unsharp mask: subtracts a Gaussian-blurred copy from
        // the original, scaled by intensity. Standard photographic sharpening.
        let sharpened = ciImage.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: params.radius,
            kCIInputIntensityKey: params.amount,
        ])
        let workingSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let context = CIContext(options: [.workingColorSpace: workingSpace])
        guard let outCG = context.createCGImage(
            sharpened,
            from: CGRect(x: 0, y: 0, width: input.width, height: input.height),
            format: .RGBA16,
            colorSpace: workingSpace
        ) else {
            return input
        }
        return try ImageBuffer.fromCGImage(outCG)
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
