import Foundation
import CoreML
import PhotoML

public enum CLIPTextEncoderError: Error, CustomStringConvertible {
    case modelNotAvailable
    case tokenizerNotAvailable
    case predictionFailed(any Error)
    case tokenizerError(any Error)
    case unexpectedOutputShape([Int])

    public var description: String {
        switch self {
        case .modelNotAvailable:
            return "OpenCLIP text encoder not found. Run scripts/convert_openclip.py."
        case .tokenizerNotAvailable:
            return CLIPTokenizerError.vocabFileNotFound.description
        case .predictionFailed(let err): return "Text encoder prediction failed: \(err)"
        case .tokenizerError(let err): return "Tokenizer failed: \(err)"
        case .unexpectedOutputShape(let s): return "Unexpected text-encoder output shape: \(s)"
        }
    }
}

/// OpenCLIP ViT-B/32 text encoder. Tokenizes text via `CLIPBPETokenizer`,
/// runs the encoder model, returns a 512-dim normalized embedding.
///
/// Model and tokenizer are both lazy-loaded. If either is missing,
/// `isAvailable` reports false and `encode` throws — the search engine
/// surfaces this as "text-search needs setup" without crashing.
public actor CLIPTextEncoder {
    private let model: CoreMLImageModel?
    private let tokenizer: CLIPBPETokenizer?
    public static let embeddingDimension = 512

    public init() async {
        // We pass `.openCLIPImage` as a placeholder spec — it's only used by
        // the image-input predict() path which we never call. The text path
        // uses predictRaw() with a custom feature provider.
        self.model = try? await ModelManager.shared.model(
            for: .openCLIPTextEncoder,
            spec: .openCLIPImage
        )

        if let mergesURL = CLIPBPETokenizer.locateMergesFile() {
            self.tokenizer = try? CLIPBPETokenizer(mergesFileURL: mergesURL)
        } else {
            self.tokenizer = nil
        }
    }

    public var isAvailable: Bool {
        model != nil && tokenizer != nil
    }

    public func encode(_ text: String) async throws -> EmbeddingVector {
        guard let model else { throw CLIPTextEncoderError.modelNotAvailable }
        guard let tokenizer else { throw CLIPTextEncoderError.tokenizerNotAvailable }

        let tokenIDs: [Int32]
        do {
            tokenIDs = try tokenizer.encode(text)
        } catch {
            throw CLIPTextEncoderError.tokenizerError(error)
        }

        // Build a 1×77 Int32 MLMultiArray from token IDs.
        let array: MLMultiArray
        do {
            array = try MLMultiArray(shape: [1, NSNumber(value: tokenIDs.count)], dataType: .int32)
        } catch {
            throw CLIPTextEncoderError.predictionFailed(error)
        }
        let dst = array.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<tokenIDs.count { dst[i] = tokenIDs[i] }

        let provider: MLDictionaryFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: ["tokens": array])
        } catch {
            throw CLIPTextEncoderError.predictionFailed(error)
        }

        let output: CoreMLImageModel.TensorOutput
        do {
            output = try await model.predictRaw(provider: provider, outputName: "embedding")
        } catch {
            throw CLIPTextEncoderError.predictionFailed(error)
        }

        guard output.totalCount == Self.embeddingDimension else {
            throw CLIPTextEncoderError.unexpectedOutputShape(output.shape)
        }
        return EmbeddingVector(output.values).normalized()
    }
}
