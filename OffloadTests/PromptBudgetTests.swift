import Testing
import Foundation
@testable import Offload

/// Guards against the bug that let extraction fail with "exceeded context window": the system
/// prompt had grown to ~12k characters, and the on-device model's window (~4k tokens, shared
/// with the capture and the output schema) couldn't hold prompt + input + schema at once.
///
/// This isn't about exact tokens — it's a tripwire. If a future change pushes the prompt back
/// over a sane budget, this fails in CI instead of on someone's phone at 1 AM.
struct PromptBudgetTests {

    @Test("The extraction system prompt stays within a safe size budget")
    func promptWithinBudget() {
        // A rough char→token ratio of ~4 means 4000 chars ≈ 1000 tokens, leaving ample room
        // for the capture text and the generated schema inside a ~4k-token window.
        let maxChars = 4000
        let prompt = ExtractionService.instructions(now: Date(), categories: CustomCategories.builtIn)
        #expect(prompt.count < maxChars, "System prompt is \(prompt.count) chars — trim it back under \(maxChars)")
    }

    @Test("The prompt still carries its load-bearing rules after trimming")
    func promptKeepsEssentials() {
        let prompt = ExtractionService.instructions(now: Date(), categories: CustomCategories.builtIn).lowercased()
        // The things that were actual bugs must still be addressed, even in the compact form.
        #expect(prompt.contains("never invent"))       // no invented tasks/dates
        #expect(prompt.contains("nil unless"))          // no date without stated timing
        #expect(prompt.contains("arranging"))           // "schedule a meeting" isn't an appointment
        #expect(prompt.contains("deadline"))            // due date vs do date
    }
}
