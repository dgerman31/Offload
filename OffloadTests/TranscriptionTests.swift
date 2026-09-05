import Testing
import Foundation
@testable import Offload

/// The seam between dictation segments.
///
/// `SFSpeechRecognizer` finalises a recognition request after roughly a minute and each new one
/// starts from an empty transcript, so a long dictation is really a chain of segments stitched back
/// together. This is the stitch — and a dropped or doubled space here shows up in the user's own
/// captured words, which is the last place anyone wants to find a bug.
struct TranscriptionTests {

    @Test("Segments are joined with exactly one space")
    func joinsWithOneSpace() {
        #expect(TranscriptionService.join("I need to email the PI", "about the dataset")
                == "I need to email the PI about the dataset")
    }

    @Test("Whitespace at the seam is normalised, never doubled")
    func trimsTheSeam() {
        // Both sides arrive from the recognizer, and either can carry trailing or leading space.
        #expect(TranscriptionService.join("first part  ", "  second part") == "first part second part")
        #expect(TranscriptionService.join("first part\n", "\nsecond part") == "first part second part")
    }

    @Test("An empty side contributes nothing, and adds no space")
    func emptiesDisappear() {
        // The first segment of a session joins onto nothing, and a silent segment finalises with an
        // empty string — a leading or trailing space from either would be visible in the field.
        #expect(TranscriptionService.join("", "the whole thing") == "the whole thing")
        #expect(TranscriptionService.join("the whole thing", "") == "the whole thing")
        #expect(TranscriptionService.join("", "") == "")
        #expect(TranscriptionService.join("   ", "  ") == "")
    }

    @Test("Punctuation and casing are left exactly as dictated")
    func doesNotRewrite() {
        // The recognizer punctuates; this must not second-guess it or the seam would read
        // differently from the rest of the sentence.
        #expect(TranscriptionService.join("Call mom.", "Then buy milk.") == "Call mom. Then buy milk.")
    }

    @Test("Chaining many segments reads as one continuous dictation")
    func chainsCleanly() {
        // What a three-minute capture actually is: three or four segments, invisible from outside.
        let segments = ["So the plan for tomorrow", "is to finish the cardio deck", "and email the PI"]
        let joined = segments.reduce("") { TranscriptionService.join($0, $1) }
        #expect(joined == "So the plan for tomorrow is to finish the cardio deck and email the PI")
    }
}
