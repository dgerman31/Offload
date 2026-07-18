import Foundation
import NaturalLanguage

/// Produces an on-device vector embedding for a piece of text. Behind a protocol so the
/// dedup logic is testable with injected vectors.
protocol TextEmbedding: Sendable {
    func vector(for text: String) -> [Double]?
}

/// On-device sentence embeddings for deduplication (spec §3.5). Uses
/// `NLEmbedding.sentenceEmbedding` — fully on-device, no download. (The spec suggests
/// `NLContextualEmbedding`; it can be swapped in behind this same protocol later.)
struct EmbeddingService: TextEmbedding {
    func vector(for text: String) -> [Double]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        else { return nil }
        return embedding.vector(for: trimmed)
    }
}

/// Vector math helpers (pure, testable).
enum VectorMath {
    /// Cosine similarity in [-1, 1]; 0 for mismatched or empty vectors.
    static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in a.indices {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        return denom == 0 ? 0 : dot / denom
    }
}
