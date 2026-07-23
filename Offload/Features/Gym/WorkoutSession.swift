import Foundation
import GRDB

/// One planned workout — a day's session in the Gym tab's weekly organizer. Fully AI-planned:
/// Gemini decides the type, muscle groups, and every exercise's sets/reps; the app just stores
/// and displays what it returns.
struct WorkoutSession: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var title: String                // "Push Day", "Leg Day", "Mobility — Hips & Ankles"
    var date: String                 // ISO date the session falls on (no time — see startMinute)
    var startMinute: Int?            // preferred minutes-since-midnight; nil = unscheduled that day
    var durationMinutes: Int
    var workoutType: String          // strength | cardio | mobility | stretching | hiit | rest
    var muscleGroups: String?        // JSON array, e.g. ["chest","triceps","shoulders"]
    var exercises: String?           // JSON array of GymExercise
    var notes: String?
    var status: String               // planned | completed | skipped
    var completedAt: String?
    /// The linked lightweight TaskItem that blocks this session's time on Home/Day.
    var taskId: String?
    var createdAt: String
    var deleted: Bool

    static let databaseTableName = "workout_sessions"

    enum CodingKeys: String, CodingKey {
        case id, title, date, notes, status, deleted
        case startMinute = "start_minute"
        case durationMinutes = "duration_minutes"
        case workoutType = "workout_type"
        case muscleGroups = "muscle_groups"
        case exercises
        case completedAt = "completed_at"
        case taskId = "task_id"
        case createdAt = "created_at"
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        date: String,
        startMinute: Int? = nil,
        durationMinutes: Int = 45,
        workoutType: String = "strength",
        muscleGroups: [String] = [],
        exercises: [GymExercise] = [],
        notes: String? = nil,
        status: String = "planned",
        completedAt: String? = nil,
        taskId: String? = nil,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        deleted: Bool = false
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.workoutType = workoutType
        self.muscleGroups = Self.encode(muscleGroups)
        self.exercises = Self.encode(exercises)
        self.notes = notes
        self.status = status
        self.completedAt = completedAt
        self.taskId = taskId
        self.createdAt = createdAt
        self.deleted = deleted
    }

    var muscleGroupList: [String] { Self.decode(muscleGroups) }
    var exerciseList: [GymExercise] { Self.decode(exercises) }

    /// Replace the exercise list, re-encoding the JSON blob — the one write path for anything
    /// that edits exercises after a session is created (currently: per-set logging).
    mutating func setExerciseList(_ list: [GymExercise]) {
        exercises = Self.encode(list)
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value), let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
    static func decode<T: Decodable>(_ json: String?) -> [T] {
        guard let json, let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return value
    }
}

/// One exercise (or mobility/stretching item) inside a session. `isMobility` separates lifting
/// work from stretching/mobility so the UI can group them distinctly, per the feature's ask for
/// a dedicated mobility/stretching presence rather than burying it in the exercise list.
///
/// `completedSets`/`loggedWeightNote` turn a session from a static prescription into something
/// you can actually log against as you train — checked off per set, with what you actually used
/// noted alongside what was planned. New fields with default values decode fine against JSON
/// from before they existed (same as `isMobility` before it), so no migration is needed — this
/// whole struct round-trips through a single `TEXT` column as JSON, not individual DB columns.
struct GymExercise: Codable, Equatable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var sets: Int?
    var reps: String?          // free text: "8-12", "AMRAP", "30 sec hold"
    var weightNote: String?    // "bodyweight", "add 5lb from last week", "RPE 8"
    var restSeconds: Int?
    var notes: String?
    var isMobility: Bool = false
    /// How many of `sets` have actually been done this session — the active-workout log.
    var completedSets: Int = 0
    /// What was actually used, if different from — or simply confirming — `weightNote`.
    var loggedWeightNote: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, sets, reps, notes
        case weightNote = "weight_note"
        case restSeconds = "rest_seconds"
        case isMobility = "is_mobility"
        case completedSets = "completed_sets"
        case loggedWeightNote = "logged_weight_note"
    }

    /// Fully logged once every prescribed set is checked off. A rep-only item with no set count
    /// (e.g. a mobility hold) counts as done the moment it's touched at all.
    var isLogged: Bool {
        guard let sets, sets > 0 else { return completedSets > 0 }
        return completedSets >= sets
    }
}
