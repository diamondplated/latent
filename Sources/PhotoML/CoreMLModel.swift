import Foundation
import CoreML
import PipelineCore

public enum CoreMLModelError: Error, CustomStringConvertible {
    case modelNotFound(ModelID)
    case modelLoadFailed(URL, any Error)
    case predictionFailed(any Error)
    case unexpectedOutputType(String)
    case incompatibleSpec(String)

    public var description: String {
        switch self {
        case .modelNotFound(let id):
            return "Model not available: \(id.rawValue). Run scripts/convert_realesrgan.py or download to ~/Library/Application Support/photo-viewer/Models/."
        case .modelLoadFailed(let url, let err):
            return "Failed to load model at \(url.path): \(err)"
        case .predictionFailed(let err):
            return "CoreML prediction failed: \(err)"
        case .unexpectedOutputType(let detail):
            return "Unexpected output: \(detail)"
        case .incompatibleSpec(let detail):
            return "Incompatible model spec: \(detail)"
        }
    }
}

/// How the model expects its input tensor laid out. Different conversions of
/// the same underlying network produce different specs, so we make this
/// explicit per model rather than baking in assumptions.
public struct TensorSpec: Sendable {
    public enum ChannelOrder: Sendable { case rgb, bgr }
    public enum DataType: Sendable { case float32, float16 }
    public enum Layout: Sendable {
        /// `[batch, channels, height, width]` — most PyTorch conversions.
        case nchw
        /// `[batch, height, width, channels]` — TensorFlow conversions.
        case nhwc
    }

    public let inputName: String
    public let outputName: String
    public let channelOrder: ChannelOrder
    public let dataType: DataType
    public let layout: Layout
    /// Pixel value range expected at input. (0, 1) is most common; (-1, 1) for
    /// some GAN-trained networks.
    public let inputRange: (Float, Float)

    public init(
        inputName: String,
        outputName: String,
        channelOrder: ChannelOrder = .rgb,
        dataType: DataType = .float32,
        layout: Layout = .nchw,
        inputRange: (Float, Float) = (0, 1)
    ) {
        self.inputName = inputName
        self.outputName = outputName
        self.channelOrder = channelOrder
        self.dataType = dataType
        self.layout = layout
        self.inputRange = inputRange
    }

    /// Default Real-ESRGAN spec from the standard PyTorch → CoreML conversion.
    public static let realESRGANx2 = TensorSpec(
        inputName: "input",
        outputName: "output",
        channelOrder: .rgb,
        dataType: .float32,
        layout: .nchw,
        inputRange: (0, 1)
    )

    /// NAFNet denoise default spec. Matches the standard basicsr-trained
    /// NAFNet weights converted via the bundled scripts/convert_nafnet.py.
    public static let nafnet = TensorSpec(
        inputName: "input",
        outputName: "output",
        channelOrder: .rgb,
        dataType: .float32,
        layout: .nchw,
        inputRange: (0, 1)
    )

    /// FBCNN artifact-removal default spec. Single-channel quality factor
    /// input is supplied internally; the model's image input is RGB NCHW.
    public static let fbcnn = TensorSpec(
        inputName: "input",
        outputName: "output",
        channelOrder: .rgb,
        dataType: .float32,
        layout: .nchw,
        inputRange: (0, 1)
    )

    /// OpenCLIP ViT-B/32 image encoder. The conversion script bakes CLIP's
    /// per-channel mean/std normalization into the model so this side only
    /// sends [0, 1] images. Output is a 512-dim embedding tensor.
    public static let openCLIPImage = TensorSpec(
        inputName: "image",
        outputName: "embedding",
        channelOrder: .rgb,
        dataType: .float32,
        layout: .nchw,
        inputRange: (0, 1)
    )
}

/// Image-to-image CoreML model wrapper. Loads an `.mlpackage` (or compiled
/// `.mlmodelc`), converts `ImageBuffer` to/from the model's expected tensor
/// format per `TensorSpec`, runs prediction, returns a new `ImageBuffer`.
public actor CoreMLImageModel {
    private let model: MLModel
    public let spec: TensorSpec
    public let url: URL

    public init(
        id: ModelID,
        spec: TensorSpec,
        computeUnits: MLComputeUnits = .all
    ) async throws {
        guard let url = ModelRegistry.url(for: id) else {
            throw CoreMLModelError.modelNotFound(id)
        }
        self.url = url
        self.spec = spec

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        do {
            // .mlpackage needs compilation; .mlmodelc can load directly.
            let compiledURL: URL
            if url.pathExtension == "mlmodelc" {
                compiledURL = url
            } else {
                compiledURL = try await MLModel.compileModel(at: url)
            }
            self.model = try MLModel(contentsOf: compiledURL, configuration: config)
        } catch {
            throw CoreMLModelError.modelLoadFailed(url, error)
        }
    }

    /// Run inference, returning the output as an `ImageBuffer`. Use for
    /// image-to-image models (super-res, denoise, restore, etc.) where the
    /// output tensor matches an NCHW/NHWC RGB image shape.
    public func predict(_ input: ImageBuffer) throws -> ImageBuffer {
        let output = try predictTensor(input)
        return try makeImageBuffer(from: output)
    }

    /// Output of a tensor prediction: flat values + shape. Sendable, so it
    /// crosses actor boundaries cleanly (raw MLMultiArray doesn't).
    public struct TensorOutput: Sendable {
        public let values: [Float]
        public let shape: [Int]

        public var totalCount: Int { values.count }
    }

    /// Run inference with an `ImageBuffer` input, returning a raw tensor output.
    /// Use for image-input models whose output isn't image-shaped — embedding
    /// encoders, classifiers, etc.
    public func predictTensor(_ input: ImageBuffer) throws -> TensorOutput {
        precondition(input.format == .working, "predict requires working format")
        let mlInput = try makeMLMultiArray(from: input)
        let provider = try MLDictionaryFeatureProvider(dictionary: [spec.inputName: mlInput])
        return try predictRaw(provider: provider, outputName: spec.outputName)
    }

    /// Run inference with a caller-built feature provider, returning raw tensor
    /// output. Use for models whose input shape doesn't match the
    /// `ImageBuffer → NCHW image` flow — e.g., the CLIP text encoder takes
    /// `[1, 77]` int32 tokens. Bypasses `TensorSpec`'s image-conversion path.
    public func predictRaw(provider: MLFeatureProvider, outputName: String) throws -> TensorOutput {
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: provider)
        } catch {
            throw CoreMLModelError.predictionFailed(error)
        }

        guard let outputArray = output.featureValue(for: outputName)?.multiArrayValue else {
            throw CoreMLModelError.unexpectedOutputType("missing or non-array output for \(outputName)")
        }

        return try Self.extractTensor(from: outputArray)
    }

    private static func extractTensor(from outputArray: MLMultiArray) throws -> TensorOutput {
        let shape = outputArray.shape.map { $0.intValue }
        let total = shape.reduce(1, *)
        var values = [Float](repeating: 0, count: total)
        let ptr = outputArray.dataPointer

        switch outputArray.dataType {
        case .float32:
            let typed = ptr.assumingMemoryBound(to: Float32.self)
            for i in 0..<total { values[i] = typed[i] }
        case .float16:
            let typed = ptr.assumingMemoryBound(to: Float16.self)
            for i in 0..<total { values[i] = Float(typed[i]) }
        case .double:
            let typed = ptr.assumingMemoryBound(to: Double.self)
            for i in 0..<total { values[i] = Float(typed[i]) }
        case .int32:
            let typed = ptr.assumingMemoryBound(to: Int32.self)
            for i in 0..<total { values[i] = Float(typed[i]) }
        default:
            // Deliberately not `@unknown default` with a named `.int8` case:
            // MLMultiArrayDataType.int8 does not exist in the macOS 15 SDK, so
            // naming it breaks the build there. Quantized outputs land here.
            throw CoreMLModelError.unexpectedOutputType(
                "unsupported MLMultiArrayDataType (raw \(outputArray.dataType.rawValue)) — "
                + "if this is a quantized (int8) model, re-convert it with float16 or float32 precision")
        }

        return TensorOutput(values: values, shape: shape)
    }

    // MARK: - Tensor conversion

    private func makeMLMultiArray(from buffer: ImageBuffer) throws -> MLMultiArray {
        let w = buffer.width, h = buffer.height
        let shape: [NSNumber] = switch spec.layout {
        case .nchw: [1, 3, NSNumber(value: h), NSNumber(value: w)]
        case .nhwc: [1, NSNumber(value: h), NSNumber(value: w), 3]
        }
        let dtype: MLMultiArrayDataType = spec.dataType == .float32 ? .float32 : .float16
        let array = try MLMultiArray(shape: shape, dataType: dtype)

        // Capture raw pointer outside the Data closure so the closure doesn't
        // capture the MLMultiArray (which is non-Sendable). The pointer's
        // lifetime is bound to `array` which outlives this function.
        let dstRaw = array.dataPointer
        let pixelCount = w * h
        let lowRange = spec.inputRange.0
        let highRange = spec.inputRange.1
        let scaleRange = highRange - lowRange
        let channelOrder: [Int] = spec.channelOrder == .rgb ? [0, 1, 2] : [2, 1, 0]
        let dataType = spec.dataType
        let layout = spec.layout

        buffer.pixels.withUnsafeBytes { rawPtr in
            let src = rawPtr.bindMemory(to: Float16.self).baseAddress!

            switch (dataType, layout) {
            case (.float32, .nchw):
                let dst = dstRaw.assumingMemoryBound(to: Float32.self)
                for c in 0..<3 {
                    let srcChannel = channelOrder[c]
                    for p in 0..<pixelCount {
                        let v = Float(src[p * 4 + srcChannel])
                        dst[c * pixelCount + p] = lowRange + scaleRange * v
                    }
                }
            case (.float16, .nchw):
                let dst = dstRaw.assumingMemoryBound(to: Float16.self)
                for c in 0..<3 {
                    let srcChannel = channelOrder[c]
                    for p in 0..<pixelCount {
                        let v = Float(src[p * 4 + srcChannel])
                        dst[c * pixelCount + p] = Float16(lowRange + scaleRange * v)
                    }
                }
            case (.float32, .nhwc):
                let dst = dstRaw.assumingMemoryBound(to: Float32.self)
                for p in 0..<pixelCount {
                    for c in 0..<3 {
                        let srcChannel = channelOrder[c]
                        let v = Float(src[p * 4 + srcChannel])
                        dst[p * 3 + c] = lowRange + scaleRange * v
                    }
                }
            case (.float16, .nhwc):
                let dst = dstRaw.assumingMemoryBound(to: Float16.self)
                for p in 0..<pixelCount {
                    for c in 0..<3 {
                        let srcChannel = channelOrder[c]
                        let v = Float(src[p * 4 + srcChannel])
                        dst[p * 3 + c] = Float16(lowRange + scaleRange * v)
                    }
                }
            }
        }

        return array
    }

    private func makeImageBuffer(from output: TensorOutput) throws -> ImageBuffer {
        let shape = output.shape
        let (h, w): (Int, Int)
        switch spec.layout {
        case .nchw:
            guard shape.count == 4, shape[1] == 3 else {
                throw CoreMLModelError.unexpectedOutputType("expected NCHW [1,3,H,W], got \(shape)")
            }
            h = shape[2]; w = shape[3]
        case .nhwc:
            guard shape.count == 4, shape[3] == 3 else {
                throw CoreMLModelError.unexpectedOutputType("expected NHWC [1,H,W,3], got \(shape)")
            }
            h = shape[1]; w = shape[2]
        }

        let pixelCount = w * h
        var pixels = Data(count: pixelCount * 4 * MemoryLayout<Float16>.size)

        let lowRange = spec.inputRange.0
        let scaleRange = spec.inputRange.1 - lowRange
        let invScale = scaleRange == 0 ? 1.0 : 1.0 / scaleRange

        let channelOrder: [Int] = spec.channelOrder == .rgb ? [0, 1, 2] : [2, 1, 0]
        let layout = spec.layout

        pixels.withUnsafeMutableBytes { rawPtr in
            let dst = rawPtr.bindMemory(to: Float16.self).baseAddress!
            output.values.withUnsafeBufferPointer { srcBuf in
                let src = srcBuf.baseAddress!

                switch layout {
                case .nchw:
                    for p in 0..<pixelCount {
                        for c in 0..<3 {
                            let srcChannel = channelOrder[c]
                            let v = (src[srcChannel * pixelCount + p] - lowRange) * invScale
                            dst[p * 4 + c] = Float16(v)
                        }
                        dst[p * 4 + 3] = 1.0  // opaque alpha
                    }
                case .nhwc:
                    for p in 0..<pixelCount {
                        for c in 0..<3 {
                            let srcChannel = channelOrder[c]
                            let v = (src[p * 3 + srcChannel] - lowRange) * invScale
                            dst[p * 4 + c] = Float16(v)
                        }
                        dst[p * 4 + 3] = 1.0
                    }
                }
            }
        }

        return ImageBuffer(width: w, height: h, format: .working, pixels: pixels)
    }
}
