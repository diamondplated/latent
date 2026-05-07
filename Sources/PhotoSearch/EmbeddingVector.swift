import Foundation

/// Fixed-dimensional embedding vector. Stored as Float32 to match what CLIP
/// produces; switching to Float16 for storage would halve the index size at
/// some accuracy cost (likely negligible for cosine similarity).
public struct EmbeddingVector: Sendable, Hashable, Codable {
    public let values: [Float]

    public init(_ values: [Float]) {
        self.values = values
    }

    public var dimension: Int { values.count }

    /// L2-normalize. CLIP's contrastive training already produces unit-norm
    /// outputs, but we re-normalize defensively so cosine similarity is just
    /// a dot product.
    public func normalized() -> EmbeddingVector {
        var sumSq: Float = 0
        for v in values { sumSq += v * v }
        let norm = sqrt(sumSq)
        guard norm > 1e-12 else { return self }
        return EmbeddingVector(values.map { $0 / norm })
    }

    /// Cosine similarity assuming both vectors are unit-norm.
    public func cosineSimilarity(_ other: EmbeddingVector) -> Float {
        precondition(values.count == other.values.count,
                     "vectors must have matching dimensions: \(values.count) vs \(other.values.count)")
        var dot: Float = 0
        for i in 0..<values.count {
            dot += values[i] * other.values[i]
        }
        return dot
    }
}
