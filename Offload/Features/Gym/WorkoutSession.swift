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
struct GymExercise: Codable, Equatable, Sendable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var sets: Int?
    var reps: String?          // free text: "8-12", "AMRAP", "30 sec hold"
    var weightNote: String?    // "bodyweight", "add 5lb from last week", "RPE 8"
    var restSeconds: Int?
    var notes: String?
    var isMobility: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, name, sets, reps, notes
        case weightNote = "weight_note"
        case restSeconds = "rest_seconds"
        case isMobility = "is_mobility"
    }
}
