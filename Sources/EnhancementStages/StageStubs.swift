import Foundation
import CoreImage
import CoreGraphics
import PipelineCore
import PhotoML

/// Concrete stages used by the standard enhancement pipeline.

// MARK: - Compression artifact removal (FBCNN)

public struct ArtifactRemoval: Stage {
    public struct Params: StageParameters, Codable {
        public var strength: Double  // 0.0 = bypass-equivalent, 1.0 = max removal

        public init(strength: Double = 0.7) {
            self.strength = strength
        }
    }

    public let id: StageID = "artifact-removal-fbcnn"
    public let displayName = "Artifact Removal"
    public init() {}

    public func process(input: ImageBuffer, params: Params, progress: ProgressReporter) async throws -> ImageBuffer {
        let strength = normalizedUnitParameter(params.strength)
        if strength == 0 { return input }
        let restored = try await runModelOrPassthrough(
            input: input,
            modelID: .artifactRemovalFBCNN,
            spec: .fbcnn,
            tileSize: 256,
            progress: progress
        )
        return try blendRestoration(original: input, processed: restored, strength: strength)
    }
}

// MARK: - Denoise (NAFNet)

public struct Denoise: Stage {
    public struct Params: StageParameters, Codable {
        public var strength: Double          // 0.0 = bypass, 1.0 = max
        public var preserveDetailBias: Double // 0.0 = uniform denoise, 1.0 = protect strong edges

        public init(strength: Double = 0.6, preserveDetailBias: Double = 0.5) {
            self.strength = strength
            self.preserveDetailBias = preserveDetailBias
        }
    }

    public let id: StageID = "denoise-nafnet"
    public let displayName = "Denoise"
    public init() {}

    public func process(input: ImageBuffer, params: Params, progress: ProgressReporter) async throws -> ImageBuffer {
        let strength = normalizedUnitParameter(params.strength)
        if strength == 0 { return input }
        let denoised = try await runModelOrPassthrough(
            input: input,
            modelID: .denoiseNAFNet,
            spec: .nafnet,
            tileSize: 256,
            progress: progress
        )
        return try blendRestoration(
            original: input,
            processed: denoised,
            strength: strength,
            preserveDetailBias: normalizedUnitParameter(params.preserveDetailBias)
        )
    }
}

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
        let amount = max(0, params.amount.isFinite ? params.amount : 0)
        if amount == 0 { return input }
        let radius = max(0, params.radius.isFinite ? params.radius : 0)
        let threshold = normalizedUnitParameter(params.threshold)

        let inputCG = try input.makeCGImage()
        let ciImage = CIImage(cgImage: inputCG)
        // Core Image's unsharp mask: subtracts a Gaussian-blurred copy from
        // the original, scaled by intensity. Standard photographic sharpening.
        let sharpened = ciImage.applyingFilter("CIUnsharpMask", parameters: [
            kCIInputRadiusKey: radius,
            kCIInputIntensityKey: amount,
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
        let sharpenedBuffer = try ImageBuffer.fromCGImage(outCG)
        return try applySharpenThreshold(
            original: input,
            sharpened: sharpenedBuffer,
            amount: amount,
            threshold: threshold
        )
    }
}

// MARK: - Pixel mixing

enum EnhancementStageError: Error, CustomStringConvertible {
    case incompatibleBuffers

    var description: String {
        switch self {
        case .incompatibleBuffers:
            "Enhancement result does not match its input dimensions and format"
        }
    }
}

/// Clamp a user/sidecar value without allowing NaN or infinity into pixel math.
@inline(__always)
func normalizedUnitParameter(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(1, max(0, value))
}

/// Mix a scale-1 restoration into its source. Working-format pixels are
/// premultiplied, so interpolating RGB is correct as long as the original alpha
/// is retained. `preserveDetailBias` protects locally high-contrast pixels,
/// allowing flat areas to receive full denoising while edges keep more of the
/// source. A contrast of 0.125 linear-light units or more receives the maximum
/// requested protection.
func blendRestoration(
    original: ImageBuffer,
    processed: ImageBuffer,
    strength: Double,
    preserveDetailBias: Double = 0
) throws -> ImageBuffer {
    guard original.width == processed.width,
          original.height == processed.height,
          original.format == .working,
          processed.format == .working else {
        throw EnhancementStageError.incompatibleBuffers
    }

    let mixStrength = Float(normalizedUnitParameter(strength))
    guard mixStrength > 0, original.contentHash != processed.contentHash else {
        return original
    }
    let detailBias = Float(normalizedUnitParameter(preserveDetailBias))
    let width = original.width
    let height = original.height

    var output = Data(count: original.pixels.count)
    original.pixels.withUnsafeBytes { originalRaw in
        processed.pixels.withUnsafeBytes { processedRaw in
            output.withUnsafeMutableBytes { outputRaw in
                let source = originalRaw.bindMemory(to: Float16.self).baseAddress!
                let result = processedRaw.bindMemory(to: Float16.self).baseAddress!
                let destination = outputRaw.bindMemory(to: Float16.self).baseAddress!

                // Only three straight-alpha luminance scanlines are needed to
                // evaluate the four-neighbor contrast below. This preserves the
                // exact edge metric while avoiding a full Float plane (about
                // 96 MiB for a 24 MP photo).
                var previousLuminance = detailBias > 0
                    ? [Float](repeating: 0, count: width) : []
                var currentLuminance = detailBias > 0
                    ? [Float](repeating: 0, count: width) : []
                var nextLuminance = detailBias > 0
                    ? [Float](repeating: 0, count: width) : []

                func loadLuminanceRow(_ row: Int, into values: inout [Float]) {
                    let rowStart = row * width
                    for x in 0..<width {
                        let base = (rowStart + x) * 4
                        let alpha = Float(source[base + 3])
                        let inverseAlpha = alpha > 1e-6 ? 1 / alpha : 0
                        let r = Float(source[base]) * inverseAlpha
                        let g = Float(source[base + 1]) * inverseAlpha
                        let b = Float(source[base + 2]) * inverseAlpha
                        values[x] = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    }
                }

                if detailBias > 0 {
                    loadLuminanceRow(0, into: &currentLuminance)
                    if height > 1 { loadLuminanceRow(1, into: &nextLuminance) }
                }

                for y in 0..<height {
                    for x in 0..<width {
                        let p = y * width + x
                        var localContrast: Float = 0
                        if detailBias > 0 {
                            let center = currentLuminance[x]
                            if x > 0 {
                                localContrast = max(localContrast, abs(center - currentLuminance[x - 1]))
                            }
                            if x + 1 < width {
                                localContrast = max(localContrast, abs(center - currentLuminance[x + 1]))
                            }
                            if y > 0 {
                                localContrast = max(localContrast, abs(center - previousLuminance[x]))
                            }
                            if y + 1 < height {
                                localContrast = max(localContrast, abs(center - nextLuminance[x]))
                            }
                        }
                        let edgeProtection = min(1, localContrast / 0.125) * detailBias
                        let mix = mixStrength * (1 - edgeProtection)
                        let base = p * 4
                        for channel in 0..<3 {
                            let sourceValue = Float(source[base + channel])
                            let resultValue = Float(result[base + channel])
                            destination[base + channel] = Float16(
                                sourceValue + (resultValue - sourceValue) * mix
                            )
                        }
                        // Restoration models operate on RGB only. Alpha is an
                        // image property, not something they are allowed to alter.
                        destination[base + 3] = source[base + 3]
                    }

                    if detailBias > 0, y + 1 < height {
                        swap(&previousLuminance, &currentLuminance)
                        swap(&currentLuminance, &nextLuminance)
                        if y + 2 < height {
                            loadLuminanceRow(y + 2, into: &nextLuminance)
                        }
                    }
                }
            }
        }
    }

    return ImageBuffer(width: width, height: height, format: .working, pixels: output)
}

/// Apply an unsharp-mask threshold after Core Image has produced the candidate
/// sharpened pixels. The comparison uses the underlying (amount-independent)
/// straight-RGB high-pass magnitude, so changing amount does not silently move
/// the threshold. Source alpha is always preserved.
func applySharpenThreshold(
    original: ImageBuffer,
    sharpened: ImageBuffer,
    amount: Double,
    threshold: Double
) throws -> ImageBuffer {
    guard original.width == sharpened.width,
          original.height == sharpened.height,
          original.format == .working,
          sharpened.format == .working else {
        throw EnhancementStageError.incompatibleBuffers
    }

    let safeAmount = Float(max(amount.isFinite ? amount : 0, 1e-6))
    let safeThreshold = Float(normalizedUnitParameter(threshold))
    let pixelCount = original.width * original.height
    var output = Data(count: original.pixels.count)

    original.pixels.withUnsafeBytes { originalRaw in
        sharpened.pixels.withUnsafeBytes { sharpenedRaw in
            output.withUnsafeMutableBytes { outputRaw in
                let source = originalRaw.bindMemory(to: Float16.self).baseAddress!
                let candidate = sharpenedRaw.bindMemory(to: Float16.self).baseAddress!
                let destination = outputRaw.bindMemory(to: Float16.self).baseAddress!

                for p in 0..<pixelCount {
                    let base = p * 4
                    let alpha = Float(source[base + 3])
                    let inverseAlpha = alpha > 1e-6 ? 1 / alpha : 0
                    var highPassMagnitude: Float = 0
                    for channel in 0..<3 {
                        let difference = abs(
                            Float(candidate[base + channel]) - Float(source[base + channel])
                        ) * inverseAlpha / safeAmount
                        highPassMagnitude = max(highPassMagnitude, difference)
                    }
                    let selected = highPassMagnitude >= safeThreshold ? candidate : source
                    destination[base] = selected[base]
                    destination[base + 1] = selected[base + 1]
                    destination[base + 2] = selected[base + 2]
                    destination[base + 3] = source[base + 3]
                }
            }
        }
    }

    return ImageBuffer(
        width: original.width,
        height: original.height,
        format: .working,
        pixels: output
    )
}

// MARK: - Default pipeline factory

public enum StandardPipeline {
    /// Builds the canonical 4-stage pipeline in correct order with default parameters.
    public static func defaultSteps() -> [PipelineStep] {
        [
            PipelineStep(stage: AnyStage(ArtifactRemoval(), params: .init())),
            PipelineStep(stage: AnyStage(Denoise(), params: .init())),
            PipelineStep(stage: AnyStage(Upscale(), params: .init(scale: 2))),
            PipelineStep(stage: AnyStage(Sharpen(), params: .init())),
        ]
    }
}
