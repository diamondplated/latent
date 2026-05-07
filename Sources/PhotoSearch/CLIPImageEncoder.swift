import Foundation
import CoreImage
import CoreGraphics
import CoreML
import PipelineCore
import PhotoML

public enum CLIPImageEncoderError: Error, CustomStringConvertible {
    case modelNotAvailable
    case bridgeError(any Error)
    case predictionFailed(any Error)
    case unexpectedOutputShape([Int])

    public var description: String {
        switch self {
        case .modelNotAvailable:
            return "OpenCLIP image encoder not found. Run scripts/convert_openclip.py."
        case .bridgeError(let err): return "Image bridge failed: \(err)"
        case .predictionFailed(let err): return "CLIP prediction failed: \(err)"
        case .unexpectedOutputShape(let shape): return "Unexpected embedding shape: \(shape)"
        }
    }
}

/// Encodes an image into an embedding using OpenCLIP ViT-B/32 (512 dims).
/// Conversion script bakes CLIP's per-channel mean/std normalization into the
/// CoreML model so this side only deals in [0, 1] inputs.
public actor CLIPImageEncoder {
    private let model: CoreMLImageModel
    private static let modelInputSize = 224
    public static let embeddingDimension = 512

    public init() async throws {
        guard let underlying = try await ModelManager.shared.model(for: .openCLIPImageEncoder, spec: .openCLIPImage) else {
            throw CLIPImageEncoderError.modelNotAvailable
        }
        self.model = underlying
    }

    /// Encode a buffer into a normalized embedding vector. Resizes + center-crops
    /// to 224×224 internally.
    public func encode(_ buffer: ImageBuffer) async throws -> EmbeddingVector {
        let resized: ImageBuffer
        do {
            resized = try centerCropAndResize(buffer)
        } catch {
            throw CLIPImageEncoderError.bridgeError(error)
        }

        let output: CoreMLImageModel.TensorOutput
        do {
            output = try await model.predictTensor(resized)
        } catch {
            throw CLIPImageEncoderError.predictionFailed(error)
        }

        guard output.totalCount == Self.embeddingDimension else {
            throw CLIPImageEncoderError.unexpectedOutputShape(output.shape)
        }
        return EmbeddingVector(output.values).normalized()
    }

    private func centerCropAndResize(_ buffer: ImageBuffer) throws -> ImageBuffer {
        if buffer.width == Self.modelInputSize && buffer.height == Self.modelInputSize {
            return buffer
        }
        let cgImage = try buffer.makeCGImage()

        // Scale so the smaller dim becomes 224, then crop the center.
        let scale = CGFloat(Self.modelInputSize) / CGFloat(min(buffer.width, buffer.height))
        let scaledW = Int((CGFloat(buffer.width) * scale).rounded())
        let scaledH = Int((CGFloat(buffer.height) * scale).rounded())

        let ci = CIImage(cgImage: cgImage)
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1.0,
            ])

        let cropX = (scaledW - Self.modelInputSize) / 2
        let cropY = (scaledH - Self.modelInputSize) / 2
        let cropRect = CGRect(x: cropX, y: cropY,
                              width: Self.modelInputSize, height: Self.modelInputSize)

        let workingSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let context = CIContext(options: [.workingColorSpace: workingSpace])
        guard let outCG = context.createCGImage(
            ci,
            from: cropRect,
            format: .RGBA16,
            colorSpace: workingSpace
        ) else {
            throw CLIPImageEncoderError.bridgeError(NSError(domain: "CLIPImageEncoder", code: -1))
        }
        return try ImageBuffer.fromCGImage(outCG)
    }

}
