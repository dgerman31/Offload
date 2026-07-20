import Foundation

/// How much your mind is currently holding.
///
/// The premise of the app is that capturing everything lets you stop carrying it — so the
/// honest headline metric isn't "tasks completed", it's how many open loops remain and how
/// many of them are actually pressing. Deliberately an *inverse* score: lower is calmer, and
/// finishing or scheduling things brings it down.
struct MentalLoad: Equatable, Sendable {
    var openLoops = 0
    var overdue = 0
    var dueToday = 0
    var unscheduled = 0
    /// 0–100; lower is calmer.
    var score = 0

    enum Band: String, Sendable {
        case clear = "Clear"
        case light = "Light"
        case full = "Full"
        case heavy = "Heavy"

        var symbol: String {
            switch self {
            case .clear: return "checkmark.circle.fill"
            case .light: return "leaf.fill"
            case .full:  return "square.stack.3d.up.fill"
            case .heavy: return "exclamationmark.triangle.fill"
            }
        }
    }

    var band: Band {
        switch score {
        case ..<20:  return .clear
        case 20..<45: return .light
        case 45..<70: return .full
        default:      return .heavy
        }
    }

    /// First person, plain language — a number alone doesn't tell you anything.
    var headline: String {
        switch band {
        case .clear:
            return openLoops == 0 ? "Nothing on your mind" : "Barely anything open"
        case .light:
            return "\(openLoops) open loop\(openLoops == 1 ? "" : "s")"
        case .full:
            return "You're holding \(openLoops) things"
        case .heavy:
            return overdue > 0 ? "\(overdue) overdue, \(openLoops) open" : "You're holding a lot"
        }
    }

    var advice: String {
        switch band {
        case .clear: return "Your mind is free. Capture anything new as it arrives."
        case .light: return "Comfortable. Nothing needs rescuing."
        case .full:  return unscheduled > 0
            ? "Try planning your day — \(unscheduled) of these have no time attached."
            : "A focus session would clear a couple of these."
        case .heavy: return overdue > 0
            ? "Start with what's overdue, or snooze what genuinely isn't happening today."
            : "Consider deferring anything that isn't really this week."
        }
    }

    static func compute(tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> MentalLoad {
        var load = MentalLoad()
        let startOfToday = calendar.startOfDay(for: now)
        var weighted = 0.0

        for task in tasks where task.status != "completed" && !task.deleted {
            load.openLoops += 1
            if let due = DueDate.parse(task.dueDate) {
                if due < startOfToday {
                    load.overdue += 1
                    weighted += 3.0          // overdue work is what actually nags
                } else if calendar.isDate(due, inSameDayAs: now) {
                    load.dueToday += 1
                    weighted += 1.5
                } else {
                    weighted += 0.6          // scheduled and in the future: mostly parked
                }
            } else {
                load.unscheduled += 1
                weighted += 1.0              // undated things float, so they cost more
            }
            // High priority adds a little regardless of timing.
            if task.priority == "high" { weighted += 0.5 }
        }

        load.score = min(100, Int((weighted * 4.5).rounded()))
        return load
    }
}
