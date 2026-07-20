import Foundation
import GRDB

/// Buckets today's tasks into time slots and tracks progress (spec §5.4). The AI
/// "next best task" suggestion is deferred to a later increment; this is the
/// deterministic scaffold it will plug into.
@MainActor
@Observable
final class TodayStore {

    enum Slot: String, CaseIterable, Sendable {
        case morning = "Morning"
        case afternoon = "Afternoon"
        case evening = "Evening"
        case anytime = "Anytime"
    }

    struct SlotGroup: Identifiable, Sendable {
        let slot: Slot
        let tasks: [TaskItem]
        var id: String { slot.rawValue }
    }

    struct DayPlan: Sendable {
        var groups: [SlotGroup] = []
        var completedToday = 0
        var openToday = 0
        var progress: Double {
            let total = completedToday + openToday
            return total == 0 ? 0 : Double(completedToday) / Double(total)
        }
    }

    private(set) var plan = DayPlan()

    private let db: AppDatabase
    init(db: AppDatabase = .shared) { self.db = db }

    func observe() async {
        let observation = ValueObservation.tracking { db in
            try TaskItem
                .filter(Column("deleted") == false)
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
        do {
            for try await tasks in observation.values(in: db.dbQueue) {
                plan = Self.plan(for: tasks, now: Date())
            }
        } catch {
            // Observation ended.
        }
    }

    func toggleComplete(_ item: TaskItem) async {
        await TaskActions.toggleComplete(item, db: db)
    }

    /// Pure bucketing (testable): open tasks due today go into time slots by hour; open
    /// tasks with no due date go to Anytime; tasks due on other days are not shown today.
    /// Completed-today tasks count toward progress but aren't listed.
    nonisolated static func plan(for tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> DayPlan {
        let iso = ISO8601DateFormatter()
        var morning: [TaskItem] = [], afternoon: [TaskItem] = [], evening: [TaskItem] = [], anytime: [TaskItem] = []
        var completedToday = 0

        for task in tasks {
            if task.status == "completed" {
                if let done = task.completedAt.flatMap({ iso.date(from: $0) }),
                   calendar.isDate(done, inSameDayAs: now) {
                    completedToday += 1
                }
                continue
            }
            if let due = DueDate.parse(task.dueDate) {
                guard calendar.isDate(due, inSameDayAs: now) else { continue }  // other day
                switch calendar.component(.hour, from: due) {
                case ..<12:   morning.append(task)
                case 12..<17: afternoon.append(task)
                default:      evening.append(task)
                }
            } else {
                anytime.append(task)
            }
        }

        var groups: [SlotGroup] = []
        if !morning.isEmpty   { groups.append(SlotGroup(slot: .morning, tasks: morning)) }
        if !afternoon.isEmpty { groups.append(SlotGroup(slot: .afternoon, tasks: afternoon)) }
        if !evening.isEmpty   { groups.append(SlotGroup(slot: .evening, tasks: evening)) }
        if !anytime.isEmpty   { groups.append(SlotGroup(slot: .anytime, tasks: anytime)) }

        let openToday = morning.count + afternoon.count + evening.count + anytime.count
        return DayPlan(groups: groups, completedToday: completedToday, openToday: openToday)
    }
}
