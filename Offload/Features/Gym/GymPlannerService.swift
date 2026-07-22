import Foundation

/// What the Gym tab is asking for: a single day, or the whole week starting from a given Sunday.
enum GymPlanScope: Sendable, Equatable {
    case day(Date)
    case week(Date)
}

/// A one-tap refinement offered after a plan, e.g. "More volume", "Add mobility", "Swap to legs".
/// Unlike a capture chip, a gym chip isn't a deterministic patch — "more volume" genuinely needs
/// exercise-selection judgment — so tapping one re-runs the planner with the chip's intent folded
/// into the request rather than editing fields locally.
struct GymChip: Sendable, Equatable, Identifiable {
    var id = UUID().uuidString
    var label: String
    var instruction: String   // folded into the next planning call verbatim
}

/// The result of a planning call: sessions ready to save, plus hyperspecialization chips.
struct GymPlanResult: Sendable {
    var sessions: [WorkoutSession]
    var chips: [GymChip]
}

/// Plans workouts by asking Gemini to think like a real coach — full use of its judgment on
/// exercise selection, sets/reps, muscle-group sequencing, and working around the day's existing
/// commitments (class, other events already on the schedule). This is deliberately NOT a
/// deterministic template: "hyperspecialize my workout" only works if the model has real freedom.
@MainActor
struct GymPlannerService {
    var client: GeminiClient

    private struct GExercise: Codable {
        var name: String
        var sets: Int?
        var reps: String?
        var weightNote: String?
        var restSeconds: Int?
        var notes: String?
        var isMobility: Bool
    }
    private struct GSession: Codable {
        var day: String              // ISO date, e.g. "2026-07-22"
        var title: String
        var workoutType: String
        var muscleGroups: [String]
        var startMinute: Int?
        var durationMinutes: Int
        var exercises: [GExercise]
        var notes: String?
    }
    private struct GPlan: Codable {
        var reasoning: String?
        var sessions: [GSession]
        var chips: [GChip]?
    }
    private struct GChip: Codable {
        var label: String
        var instruction: String
    }

    private static func schema() -> GSchema {
        let exercise: GSchema = .object(properties: [
            .init("name", .string()),
            .init("sets", .integer(nullable: true)),
            .init("reps", .string(nullable: true)),
            .init("weightNote", .string(nullable: true)),
            .init("restSeconds", .integer(nullable: true)),
            .init("notes", .string(nullable: true)),
            .init("isMobility", .boolean)
        ], required: ["name", "isMobility"])

        let session: GSchema = .object(properties: [
            .init("day", .string()),
            .init("title", .string()),
            .init("workoutType", .string(enumValues: ["strength", "cardio", "mobility", "stretching", "hiit", "rest"])),
            .init("muscleGroups", .array(.string())),
            .init("startMinute", .integer(nullable: true)),
            .init("durationMinutes", .integer()),
            .init("exercises", .array(exercise)),
            .init("notes", .string(nullable: true))
        ], required: ["day", "title", "workoutType", "muscleGroups", "durationMinutes", "exercises"])

        let chip: GSchema = .object(properties: [
            .init("label", .string()),
            .init("instruction", .string())
        ], required: ["label", "instruction"])

        return .object(properties: [
            .init("reasoning", .string(nullable: true)),
            .init("sessions", .array(session)),
            .init("chips", .array(chip))
        ], required: ["sessions"])
    }

    /// Plan a day or a week. `transcript` is the person's free-text ask ("plan my week", "5x/week
    /// gym, afternoons, unless class then campus gym…", "just legs today"); `extra` folds in a
    /// tapped chip's instruction on a refinement call. `busyContext` is a plain-text summary of
    /// what's already on the schedule for the days in scope (classes, events, other tasks), so
    /// the model can route around real commitments instead of guessing blindly.
    func plan(
        scope: GymPlanScope,
        transcript: String,
        extra: String? = nil,
        busyContext: String,
        existing: [WorkoutSession],
        now: Date = Date()
    ) async throws -> GymPlanResult {
        let system = Self.systemPrompt(scope: scope, now: now, busyContext: busyContext, existing: existing)
        var prompt = transcript
        if let extra { prompt += "\n\nRefinement: \(extra)" }

        let plan = try await client.generate(
            system: system, prompt: prompt, schema: Self.schema(), as: GPlan.self, temperature: 0.4
        )
        return GymPlanResult(
            sessions: plan.sessions.map(Self.domain),
            chips: (plan.chips ?? []).prefix(4).map { GymChip(label: $0.label, instruction: $0.instruction) }
        )
    }

    private static func domain(_ g: GSession) -> WorkoutSession {
        WorkoutSession(
            title: g.title,
            date: g.day,
            startMinute: g.startMinute,
            durationMinutes: max(10, g.durationMinutes),
            workoutType: g.workoutType,
            muscleGroups: g.muscleGroups,
            exercises: g.exercises.map {
                GymExercise(name: $0.name, sets: $0.sets, reps: $0.reps, weightNote: $0.weightNote,
                           restSeconds: $0.restSeconds, notes: $0.notes, isMobility: $0.isMobility)
            },
            notes: g.notes
        )
    }

    private static func systemPrompt(scope: GymPlanScope, now: Date, busyContext: String, existing: [WorkoutSession]) -> String {
        let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]
        let localNow = f.string(from: now)
        let tz = TimeZone.current.identifier

        let scopeLine: String
        switch scope {
        case let .day(date):
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            scopeLine = "Plan exactly ONE session, for \(df.string(from: date)) only."
        case let .week(weekStart):
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
            scopeLine = "Plan the full week, \(df.string(from: weekStart)) through \(df.string(from: end)) " +
                "(Sun–Sat) — one session per training day, rest days simply get no session."
        }

        let existingSummary = existing.isEmpty ? "None yet." : existing.map {
            "\($0.date): \($0.title) (\($0.workoutType), \($0.muscleGroupList.joined(separator: "/")))"
        }.joined(separator: "; ")

        return """
        You are a real strength & conditioning coach planning workouts for one specific person
        inside Offload's Gym tab. You have full authority over exercise selection, sets, reps,
        rest, sequencing, and muscle-group split — this is not a template, it's your genuine
        professional judgment, the same as if they'd hired you.

        TIME. Current local time is \(localNow) (timezone \(tz)). \(scopeLine)

        THEIR SCHEDULE. Route around what's already committed — never overlap a class or a real
        event, and respect any stated preference (e.g. "afternoons", "unless I have class that
        day, then the campus gym"). What's already on their calendar/tasks for these days:
        \(busyContext)

        WHAT'S ALREADY PLANNED this week (for continuity — don't repeat the same muscle groups
        two days straight unless they asked for it, and progress sensibly from recent sessions):
        \(existingSummary)

        THINK FIRST. Use `reasoning` as a private scratchpad — work out the split, the sequencing,
        and how to honor their stated constraints, before you commit to sessions. Nobody sees it.

        SESSIONS. For each: `title` (e.g. "Push Day", "Leg Day", "Mobility — Hips & Ankles"),
        `workoutType`, `muscleGroups` (the areas trained), `startMinute` (minutes since midnight —
        set it when you can reasonably infer a time from their stated preference, else null),
        `durationMinutes`. `exercises` is the real prescription: name, sets, reps (free text —
        "8-12", "AMRAP", "30 sec hold"), a weight/intensity note, rest seconds, and `isMobility`
        true for a stretch/mobility/warm-up item as distinct from a lifting set. ALWAYS include
        real mobility/stretching work where it belongs — a warm-up before heavy lifting, a
        cooldown after, or its own dedicated mobility day if they asked for one. Don't pad with
        filler; every exercise should be one you'd genuinely prescribe.

        HYPERSPECIALIZE, don't guess wrong. Offer 0–4 chips for real refinements this person might
        want next: more/less volume, swap the day's focus, add dedicated mobility work, adjust
        intensity, target a specific weak point. Each chip is `label` (button text, 1–4 words) and
        `instruction` (a full sentence you'll act on if it's tapped — e.g. "Add another leg
        exercise and increase the squat's working sets"). Skip chips entirely if the plan is
        already exactly what they asked for.
        """
    }
}
