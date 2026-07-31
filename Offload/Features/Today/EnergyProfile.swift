import Foundation

/// When you actually do your best work.
///
/// A planner that treats 9am and 4pm as interchangeable will cheerfully schedule your hardest
/// task into your worst hour. This lets the day be shaped around a real preference: demanding
/// work lands in your peak window, admin fills the trough.
///
/// Deliberately a coarse choice rather than a wellness questionnaire — three options people
/// can answer instantly about themselves.
enum EnergyProfile: String, CaseIterable, Identifiable, Sendable {
    case morning, afternoon, evening

    static let storageKey = "offload.planner.energyProfile"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .morning:   return "Morning person"
        case .afternoon: return "Afternoon peak"
        case .evening:   return "Night owl"
        }
    }

    var icon: String {
        switch self {
        case .morning:   return "sunrise.fill"
        case .afternoon: return "sun.max.fill"
        case .evening:   return "moon.stars.fill"
        }
    }

    /// The hours where demanding work should land, if it can.
    var peakHours: Range<Int> {
        switch self {
        case .morning:   return 8..<12
        case .afternoon: return 12..<17
        case .evening:   return 17..<22
        }
    }

    func isPeak(_ date: Date, calendar: Calendar = .current) -> Bool {
        peakHours.contains(calendar.component(.hour, from: date))
    }

    /// A task is "demanding" when it's high priority or a long block — those are the ones
    /// worth protecting a good hour for.
    static func isDemanding(_ task: TaskItem) -> Bool {
        task.priority == "high" || (task.effortMinutes ?? EnergyBatch.defaultEffort) >= 45
    }

    /// Score a candidate placement: lower is better, so this plugs into a sort. Demanding work
    /// is penalised outside your peak; light work is *mildly* penalised for eating into it,
    /// so admin doesn't squat on your best hours.
    static func penalty(for task: TaskItem, at start: Date, profile: EnergyProfile,
                        calendar: Calendar = .current) -> Int {
        penalty(for: task, at: start, peakHours: profile.peakHours.map { $0 }, calendar: calendar)
    }

    /// The same scoring against an explicit set of good hours, which is what lets a *measured*
    /// curve stand in for the declared profile. `EnergyCurve` produces scattered hours rather than
    /// a contiguous window — your best time can genuinely be 8–10am and 8–9pm — so this takes a
    /// list rather than a range.
    ///
    /// `nil` or empty means no opinion, and every placement scores zero: with nothing learned and
    /// nothing declared, the planner should front-load the day rather than invent a preference.
    static func penalty(for task: TaskItem, at start: Date, peakHours: [Int]?,
                        calendar: Calendar = .current) -> Int {
        guard let peakHours, !peakHours.isEmpty else { return 0 }
        let peak = peakHours.contains(calendar.component(.hour, from: start))
        if isDemanding(task) { return peak ? 0 : 2 }
        return peak ? 1 : 0
    }
}
