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

    /// The Gemini prompt had every schema field documented under `## Fields` *except*
    /// `suggestedProject`, whose only mention was scoped to the `isCommand: true` branch — so
    /// "working on the X project…" produced tasks and no project, because the model's only
    /// documented route for a non-command project was a chip the user had to tap. Nothing tested
    /// the prompt's field coverage, which is why it shipped.
    // `@MainActor` because `GeminiExtractionService` is main-actor isolated, so reaching its
    // `systemPrompt` from a synchronous nonisolated test body doesn't compile under Swift 6.
    @MainActor
    @Test("Every field in the Gemini schema is documented in the Gemini prompt")
    func geminiPromptDocumentsEverySchemaField() {
        let prompt = GeminiExtractionService.systemPrompt(now: Date(), categories: CustomCategories.builtIn)
        for field in ["reasoning", "isCommand", "suggestedProject", "title", "details",
                      "dueDate", "deadline", "effortMinutes", "priority", "category",
                      "contextTags", "people", "subtasks", "isAppointment",
                      // Added with the capture taxonomy. `kind` decides whether something can be
                      // scheduled at all, so an undocumented one would be the most expensive
                      // omission on the list.
                      "kind", "confidence"] {
            #expect(prompt.contains(field),
                    "The Gemini prompt never mentions `\(field)`, so the model has no instruction for it")
        }
    }

    @MainActor
    @Test("The prompt tells the model to fill suggestedProject even when it isn't a command")
    func geminiPromptDecouplesProjectFromCommand() {
        let prompt = GeminiExtractionService.systemPrompt(now: Date(), categories: CustomCategories.builtIn)
        // The exact phrasing from the bug report needs to be covered by an example.
        #expect(prompt.contains("working on"))
        #expect(prompt.contains("independent of `isCommand`"))
    }
}
