import Testing
@testable import Offload

struct DuplicateDetectorTests {

    @Test("Cosine similarity: identical = 1, orthogonal = 0, opposite = -1")
    func cosine() {
        #expect(abs(VectorMath.cosineSimilarity([1, 0, 0], [1, 0, 0]) - 1) < 1e-9)
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [0, 1]) - 0) < 1e-9)
        #expect(abs(VectorMath.cosineSimilarity([1, 0], [-1, 0]) - (-1)) < 1e-9)
        // Mismatched lengths / empty => 0, not a crash.
        #expect(VectorMath.cosineSimilarity([1, 2, 3], [1, 2]) == 0)
        #expect(VectorMath.cosineSimilarity([], []) == 0)
    }

    @Test("nearMatches keeps only above-threshold, sorted most-similar first")
    func nearMatches() {
        let existing: [(id: String, vector: [Double])] = [
            ("a", [1, 0]),        // identical -> 1.0
            ("b", [0.9, 0.1]),    // very similar
            ("c", [0, 1])         // orthogonal -> 0
        ]
        let matches = DuplicateDetector.nearMatches(to: [1, 0], among: existing, threshold: 0.82)
        #expect(matches.map(\.id) == ["a", "b"])           // c excluded, a before b
        #expect(matches.first?.score ?? 0 > matches.last?.score ?? 1)
    }

    @Test("No matches below threshold")
    func noMatches() {
        let existing: [(id: String, vector: [Double])] = [("x", [0, 1])]
        #expect(DuplicateDetector.nearMatches(to: [1, 0], among: existing).isEmpty)
    }
}
