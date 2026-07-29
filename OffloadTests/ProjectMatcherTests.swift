import Testing
import Foundation
@testable import Offload

/// Fuzzy project matching: the same project said differently should land in the one that already
/// exists, and two genuinely different projects should stay apart no matter how alike they read.
struct ProjectMatcherTests {

    private let jury = Project(id: "p-jury", title: "Jury 3")
    private let thesis = Project(id: "p-thesis", title: "Thesis")

    private var projects: [Project] { [jury, thesis] }

    // MARK: Normalization

    @Test("Case, punctuation, and spelled-out numbers all normalize to one form")
    func normalization() {
        #expect(ProjectMatcher.normalize("Jury 3") == "jury 3")
        #expect(ProjectMatcher.normalize("jury-3") == "jury 3")
        #expect(ProjectMatcher.normalize("  JURY   3  ") == "jury 3")
        #expect(ProjectMatcher.normalize("jury three") == "jury 3")
        #expect(ProjectMatcher.normalize("the Jury 3 project") == "the jury 3")
    }

    @Test("A trailing container noun is dropped, a leading one kept")
    func containerNouns() {
        #expect(ProjectMatcher.normalize("Thesis project") == "thesis")
        #expect(ProjectMatcher.normalize("Shopping list") == "shopping")
        // "Project Apollo" is a name that happens to start with the word.
        #expect(ProjectMatcher.normalize("Project Apollo") == "project apollo")
    }

    // MARK: Exact and close

    @Test("A differently-typed version of the same name matches exactly")
    func exactAfterNormalizing() {
        for spoken in ["jury 3", "JURY 3", "Jury-3", "jury three", "Jury 3 project"] {
            let match = ProjectMatcher.best(for: spoken, among: projects)
            #expect(match?.project.id == jury.id, "\(spoken) should find Jury 3")
            #expect(match?.confidence == .exact, "\(spoken) should be an exact match")
        }
    }

    @Test("A misspelling is a close match")
    func misspelling() {
        let match = ProjectMatcher.best(for: "Thesus", among: projects)
        #expect(match?.project.id == thesis.id)
        #expect(match?.confidence == .close)
    }

    @Test("The same name inside a longer phrase is a close match")
    func nameWithinLongerPhrase() {
        let match = ProjectMatcher.best(for: "Jury 3 trial prep", among: projects)
        #expect(match?.project.id == jury.id)
        #expect(match?.confidence == .close)
    }

    // MARK: What must never merge

    @Test("Names differing only by their number never match")
    func differentNumbersNeverMerge() {
        // One character apart, and the one thing fuzzy matching most needs to keep apart.
        #expect(ProjectMatcher.best(for: "Jury 4", among: projects) == nil)
        #expect(ProjectMatcher.best(for: "jury four", among: projects) == nil)
        #expect(ProjectMatcher.numbersAgree("jury 3", "jury 4") == false)
        #expect(ProjectMatcher.numbersAgree("jury 3", "jury 3") == true)
        #expect(ProjectMatcher.numbersAgree("thesis", "thesus") == true)   // no digits either side
    }

    @Test("A genuinely new project doesn't match anything")
    func newProject() {
        #expect(ProjectMatcher.best(for: "Kitchen remodel", among: projects) == nil)
    }

    @Test("Short names tolerate no edits at all")
    func shortNamesAreStrict() {
        #expect(ProjectMatcher.editTolerance(for: 4) == 0)
        #expect(ProjectMatcher.editTolerance(for: 6) == 1)
        #expect(ProjectMatcher.editTolerance(for: 12) == 2)
        // "Labs" vs "Lab5" is one edit and two different things.
        let labs = [Project(id: "p", title: "Labs")]
        #expect(ProjectMatcher.best(for: "Lab5", among: labs) == nil)
    }

    @Test("A deleted project is never matched into")
    func deletedProjectsIgnored() {
        var gone = jury
        gone.deleted = true
        #expect(ProjectMatcher.best(for: "Jury 3", among: [gone]) == nil)
    }

    @Test("An empty or whitespace-only name matches nothing")
    func emptyName() {
        #expect(ProjectMatcher.best(for: "   ", among: projects) == nil)
    }

    // MARK: The meaning tier

    /// Vectors are injected, so the tier is tested for its thresholds rather than for whatever
    /// `NLEmbedding` happens to think this month.
    private struct FakeEmbedder: TextEmbedding {
        let vectors: [String: [Double]]
        func vector(for text: String) -> [Double]? { vectors[text] }
    }

    @Test("Different words for the same thing merge only when the model is very sure")
    func embeddingTiers() {
        let dissertation = Project(id: "p-diss", title: "Dissertation")
        // Cosine 1.0 — identical vectors, well past `closeSimilarity`.
        let sure = FakeEmbedder(vectors: ["Doctoral thesis": [1, 0], "Dissertation": [1, 0]])
        let sureMatch = ProjectMatcher.best(for: "Doctoral thesis", among: [dissertation], embedder: sure)
        #expect(sureMatch?.confidence == .close)

        // Cosine ≈ 0.8 — between the two thresholds, so it's a question, not an action.
        let unsure = FakeEmbedder(vectors: ["Doctoral thesis": [0.8, 0.6], "Dissertation": [1, 0]])
        let unsureMatch = ProjectMatcher.best(for: "Doctoral thesis", among: [dissertation], embedder: unsure)
        #expect(unsureMatch?.confidence == .related)

        // Cosine 0 — unrelated.
        let unrelated = FakeEmbedder(vectors: ["Doctoral thesis": [0, 1], "Dissertation": [1, 0]])
        #expect(ProjectMatcher.best(for: "Doctoral thesis", among: [dissertation], embedder: unrelated) == nil)
    }

    @Test("The meaning tier still can't cross a number boundary")
    func embeddingRespectsNumbers() {
        let identical = FakeEmbedder(vectors: ["Jury 4": [1, 0], "Jury 3": [1, 0]])
        #expect(ProjectMatcher.best(for: "Jury 4", among: [jury], embedder: identical) == nil)
    }

    @Test("Edit distance is the plain thing")
    func levenshtein() {
        #expect(ProjectMatcher.levenshtein("thesis", "thesis") == 0)
        #expect(ProjectMatcher.levenshtein("thesis", "thesus") == 1)
        #expect(ProjectMatcher.levenshtein("", "abc") == 3)
        #expect(ProjectMatcher.levenshtein("abc", "") == 3)
    }
}
