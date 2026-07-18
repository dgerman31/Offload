import Foundation

/// Finds near-duplicate tasks by embedding similarity (spec §3.5). Brute-force cosine over
/// existing vectors — fine for personal-scale datasets; no RTREE (that's a spatial index,
/// not for cosine). At larger scale this moves to `sqlite-vec` behind the same call site.
enum DuplicateDetector {

    struct Match: Equatable, Sendable {
        let id: String
        let score: Double
    }

    /// Default similarity threshold (spec §3.5); tunable in Settings later.
    static let defaultThreshold = 0.82

    /// Existing tasks whose embedding is at least `threshold` similar to `vector`,
    /// most-similar first.
    static func nearMatches(
        to vector: [Double],
        among existing: [(id: String, vector: [Double])],
        threshold: Double = defaultThreshold
    ) -> [Match] {
        existing
            .map { Match(id: $0.id, score: VectorMath.cosineSimilarity(vector, $0.vector)) }
            .filter { $0.score >= threshold }
            .sorted { $0.score > $1.score }
    }
}
