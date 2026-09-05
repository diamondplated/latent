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
    public enum TransferFunction: Sendable {
        /// Tensor values represent linear-light RGB.
        case linear
        /// Tensor values represent IEC 61966-2-1 nonlinear sRGB.
        case sRGB
    }
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
    /// Pixel value range produced by an image output. Defaults to inputRange.
    public let outputRange: (Float, Float)
    /// Transfer functions are explicit because `ImageBuffer.working` is
    /// linear-light while the standard PyTorch image tensors are nonlinear.
    public let inputTransferFunction: TransferFunction
    public let outputTransferFunction: TransferFunction

    public init(
        inputName: String,
        outputName: String,
        channelOrder: ChannelOrder = .rgb,
        dataType: DataType = .float32,
        layout: Layout = .nchw,
        inputRange: (Float, Float) = (0, 1),
        outputRange: (Float, Float)? = nil,
        inputTransferFunction: TransferFunction = .sRGB,
        outputTransferFunction: TransferFunction = .sRGB
    ) {
        self.inputName = inputName
        self.outputName = outputName
        self.channelOrder = channelOrder
        self.dataType = dataType
        self.layout = layout
        self.inputRange = inputRange
        self.outputRange = outputRange ?? inputRange
        self.inputTransferFunction = inputTransferFunction
        self.outputTransferFunction = outputTransferFunction
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

    /// FBCNN artifact-removal default spec. The converted model estimates its
    /// own quality factor internally and exposes only its RGB image output.
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
        return try ModelTensorConverter.makeImageBuffer(
            from: output,
            preservingAlphaFrom: input,
            spec: spec
        )
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
        guard !shape.isEmpty, shape.allSatisfy({ $0 > 0 }) else {
            throw CoreMLModelError.unexpectedOutputType("invalid tensor shape \(shape)")
        }
        var total = 1
        for dimension in shape {
            let (next, overflow) = total.multipliedReportingOverflow(by: dimension)
            guard !overflow else {
                throw CoreMLModelError.unexpectedOutputType("tensor element count overflow for shape \(shape)")
            }
            total = next
        }
        var values = [Float](repeating: 0, count: total)
        let ptr = outputArray.dataPointer
        let strides = outputArray.strides.map { $0.intValue }

        // Core ML commonly returns a contiguous array, but MLMultiArray also
        // permits slices and padded strides. Flatten in logical row-major order
        // in either case instead of assuming dataPointer[i] is always valid.
        var expectedStride = 1
        var isContiguous = true
        for dimension in shape.indices.reversed() {
            if strides[dimension] != expectedStride { isContiguous = false }
            expectedStride *= shape[dimension]
        }
        @inline(__always)
        func sourceOffset(for linearIndex: Int) -> Int {
            guard !isContiguous else { return linearIndex }
            var remainder = linearIndex
            var offset = 0
            for dimension in shape.indices.reversed() {
                let coordinate = remainder % shape[dimension]
                remainder /= shape[dimension]
                offset += coordinate * strides[dimension]
            }
            return offset
        }

        switch outputArray.dataType {
        case .float32:
            let typed = ptr.assumingMemoryBound(to: Float32.self)
            for i in 0..<total { values[i] = typed[sourceOffset(for: i)] }
        case .float16:
            let typed = ptr.assumingMemoryBound(to: Float16.self)
            for i in 0..<total { values[i] = Float(typed[sourceOffset(for: i)]) }
        case .double:
            let typed = ptr.assumingMemoryBound(to: Double.self)
            for i in 0..<total { values[i] = Float(typed[sourceOffset(for: i)]) }
        case .int32:
            let typed = ptr.assumingMemoryBound(to: Int32.self)
            for i in 0..<total { values[i] = Float(typed[sourceOffset(for: i)]) }
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

        let values = try ModelTensorConverter.makeInputValues(from: buffer, spec: spec)

        // Capture raw pointer so the closure doesn't capture the MLMultiArray
        // (which is non-Sendable). The pointer is bound to `array`'s lifetime.
        let dstRaw = array.dataPointer
        switch spec.dataType {
        case .float32:
            let destination = dstRaw.assumingMemoryBound(to: Float32.self)
            values.withUnsafeBufferPointer { source in
                destination.update(from: source.baseAddress!, count: source.count)
            }
        case .float16:
            let destination = dstRaw.assumingMemoryBound(to: Float16.self)
            for index in values.indices {
                destination[index] = Float16(values[index])
            }
        }

        return array
    }
}

// MARK: - Model-free pixel/tensor conversion

/// Pure conversion routines shared by inference and deterministic tests. The
/// pipeline's working storage is linear-light, premultiplied RGBA; image models
/// consume and produce straight RGB tensors with an explicit transfer function.
enum ModelTensorConverter {
    @inline(__always)
    static func linearToSRGB(_ value: Float) -> Float {
        let linear = min(1, max(0, value))
        if linear <= 0.0031308 { return 12.92 * linear }
        return 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    @inline(__always)
    static func sRGBToLinear(_ value: Float) -> Float {
        let nonlinear = min(1, max(0, value))
        if nonlinear <= 0.04045 { return nonlinear / 12.92 }
        return pow((nonlinear + 0.055) / 1.055, 2.4)
    }

    static func makeInputValues(from buffer: ImageBuffer, spec: TensorSpec) throws -> [Float] {
        guard buffer.format == .working else {
            throw CoreMLModelError.incompatibleSpec("tensor conversion requires the linear-sRGB working format")
        }
        let lowRange = spec.inputRange.0
        let highRange = spec.inputRange.1
        guard lowRange.isFinite, highRange.isFinite, lowRange != highRange else {
            throw CoreMLModelError.incompatibleSpec("input range must contain two distinct finite values")
        }

        let pixelCount = buffer.width * buffer.height
        let rangeScale = highRange - lowRange
        let channelOrder: [Int] = spec.channelOrder == .rgb ? [0, 1, 2] : [2, 1, 0]
        var values = [Float](repeating: 0, count: pixelCount * 3)

        buffer.pixels.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Float16.self).baseAddress!
            for p in 0..<pixelCount {
                let alpha = min(1, max(0, Float(source[p * 4 + 3])))
                let inverseAlpha = alpha > 1e-6 ? 1 / alpha : 0
                for tensorChannel in 0..<3 {
                    let sourceChannel = channelOrder[tensorChannel]
                    let straightLinear = Float(source[p * 4 + sourceChannel]) * inverseAlpha
                    let normalized: Float = switch spec.inputTransferFunction {
                    case .linear: min(1, max(0, straightLinear))
                    case .sRGB: linearToSRGB(straightLinear)
                    }
                    let destinationIndex = switch spec.layout {
                    case .nchw: tensorChannel * pixelCount + p
                    case .nhwc: p * 3 + tensorChannel
                    }
                    values[destinationIndex] = lowRange + normalized * rangeScale
                }
            }
        }
        return values
    }

    static func makeImageBuffer(
        from output: CoreMLImageModel.TensorOutput,
        preservingAlphaFrom source: ImageBuffer,
        spec: TensorSpec
    ) throws -> ImageBuffer {
        let shape = output.shape
        let (h, w): (Int, Int)
        switch spec.layout {
        case .nchw:
            guard shape.count == 4, shape[0] == 1, shape[1] == 3 else {
                throw CoreMLModelError.unexpectedOutputType("expected NCHW [1,3,H,W], got \(shape)")
            }
            h = shape[2]; w = shape[3]
        case .nhwc:
            guard shape.count == 4, shape[0] == 1, shape[3] == 3 else {
                throw CoreMLModelError.unexpectedOutputType("expected NHWC [1,H,W,3], got \(shape)")
            }
            h = shape[1]; w = shape[2]
        }
        let (pixelCount, pixelCountOverflow) = w.multipliedReportingOverflow(by: h)
        let (expectedValueCount, valueCountOverflow) = pixelCount.multipliedReportingOverflow(by: 3)
        let (rgbaComponentCount, componentCountOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        let (outputByteCount, byteCountOverflow) = rgbaComponentCount.multipliedReportingOverflow(
            by: MemoryLayout<Float16>.size
        )
        guard h > 0, w > 0,
              !pixelCountOverflow, !valueCountOverflow,
              !componentCountOverflow, !byteCountOverflow,
              output.values.count == expectedValueCount else {
            throw CoreMLModelError.unexpectedOutputType(
                "image tensor shape \(shape) does not match \(output.values.count) values"
            )
        }
        guard source.format == .working else {
            throw CoreMLModelError.incompatibleSpec("alpha preservation requires the working image format")
        }

        var pixels = Data(count: outputByteCount)

        let lowRange = spec.outputRange.0
        let scaleRange = spec.outputRange.1 - lowRange
        guard lowRange.isFinite, scaleRange.isFinite, scaleRange != 0 else {
            throw CoreMLModelError.incompatibleSpec("output range must contain two distinct finite values")
        }
        let invScale = 1 / scaleRange

        let channelOrder: [Int] = spec.channelOrder == .rgb ? [0, 1, 2] : [2, 1, 0]
        let layout = spec.layout

        pixels.withUnsafeMutableBytes { rawPtr in
            let dst = rawPtr.bindMemory(to: Float16.self).baseAddress!
            source.pixels.withUnsafeBytes { sourceRaw in
                let sourcePixels = sourceRaw.bindMemory(to: Float16.self).baseAddress!
                output.values.withUnsafeBufferPointer { srcBuf in
                    let tensor = srcBuf.baseAddress!

                    for y in 0..<h {
                        for x in 0..<w {
                            let p = y * w + x
                            let alpha = resampledAlpha(
                                x: x, y: y, outputWidth: w, outputHeight: h,
                                sourceWidth: source.width, sourceHeight: source.height,
                                sourcePixels: sourcePixels
                            )
                            for destinationChannel in 0..<3 {
                                let tensorChannel = channelOrder[destinationChannel]
                                let sourceIndex = switch layout {
                                case .nchw: tensorChannel * pixelCount + p
                                case .nhwc: p * 3 + tensorChannel
                                }
                                let normalized = (tensor[sourceIndex] - lowRange) * invScale
                                let straightLinear: Float = switch spec.outputTransferFunction {
                                case .linear: min(1, max(0, normalized))
                                case .sRGB: sRGBToLinear(normalized)
                                }
                                dst[p * 4 + destinationChannel] = Float16(straightLinear * alpha)
                            }
                            dst[p * 4 + 3] = Float16(alpha)
                        }
                    }
                }
            }
        }

        return ImageBuffer(width: w, height: h, format: .working, pixels: pixels)
    }

    /// Bilinear alpha resampling aligns pixel centers. It is exact for scale-1
    /// restoration and avoids jagged transparency when a model changes size.
    private static func resampledAlpha(
        x: Int,
        y: Int,
        outputWidth: Int,
        outputHeight: Int,
        sourceWidth: Int,
        sourceHeight: Int,
        sourcePixels: UnsafePointer<Float16>
    ) -> Float {
        let sourceX = (Float(x) + 0.5) * Float(sourceWidth) / Float(outputWidth) - 0.5
        let sourceY = (Float(y) + 0.5) * Float(sourceHeight) / Float(outputHeight) - 0.5
        let clampedX = min(Float(sourceWidth - 1), max(0, sourceX))
        let clampedY = min(Float(sourceHeight - 1), max(0, sourceY))
        let x0 = Int(clampedX.rounded(.down))
        let y0 = Int(clampedY.rounded(.down))
        let x1 = min(sourceWidth - 1, x0 + 1)
        let y1 = min(sourceHeight - 1, y0 + 1)
        let fx = clampedX - Float(x0)
        let fy = clampedY - Float(y0)

        func alpha(_ sampleX: Int, _ sampleY: Int) -> Float {
            min(1, max(0, Float(sourcePixels[(sampleY * sourceWidth + sampleX) * 4 + 3])))
        }
        let top = alpha(x0, y0) + (alpha(x1, y0) - alpha(x0, y0)) * fx
        let bottom = alpha(x0, y1) + (alpha(x1, y1) - alpha(x0, y1)) * fx
        return top + (bottom - top) * fy
    }
}
