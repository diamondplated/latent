import Foundation
import CoreML
import PhotoML

public enum CLIPTextEncoderError: Error, CustomStringConvertible {
    case modelNotAvailable
    case tokenizerNotImplemented
    case predictionFailed(any Error)

    public var description: String {
        switch self {
        case .modelNotAvailable:
            return "OpenCLIP text encoder not found. Run scripts/convert_openclip.py."
        case .tokenizerNotImplemented:
            return """
            CLIP BPE tokenizer not yet implemented in Swift. Currently only \
            image-to-image search works. To enable text queries, port \
            simple_tokenizer.py from openai/CLIP — ~200 lines including \
            vocab.json and merges.txt loading. Track in TODO milestone 5.1.
            """
        case .predictionFailed(let err): return "Text encoder prediction failed: \(err)"
        }
    }
}

/// OpenCLIP ViT-B/32 text encoder. **Currently a stub** for the tokenizer
/// path: the CoreML model itself converts cleanly (see scripts/convert_openclip.py),
/// but BPE tokenization in Swift is its own ~200-line milestone (port of
/// `clip.simple_tokenizer`). Image-to-image search via `CLIPImageEncoder`
/// works fully without the text path.
///
/// When the tokenizer lands, this becomes a real `encode(_ text: String)` that:
///   1. Lowercases + ASCII-cleans input
///   2. Whitespace-tokenizes into words
///   3. Applies BPE merges per word
///   4. Looks up token IDs from vocab
///   5. Pads to context length 77
///   6. Runs the CoreML text encoder → 512-dim embedding
public actor CLIPTextEncoder {
    private let model: CoreMLImageModel?  // nil means model file missing

    public init() async {
        // Don't throw if missing — text search is optional in v1.
        self.model = try? await ModelManager.shared.model(for: .openCLIPTextEncoder, spec: .openCLIPImage)
    }

    public var isAvailable: Bool { model != nil }

    public func encode(_ text: String) async throws -> EmbeddingVector {
        // Tokenizer path requires Swift port of simple_tokenizer.py — not yet
        // shipped. This is the one piece of search infra that's not real yet.
        _ = text
        throw CLIPTextEncoderError.tokenizerNotImplemented
    }
}
