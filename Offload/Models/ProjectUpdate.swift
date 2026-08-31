import Foundation
import GRDB

/// One dated entry in a project's log: where it was on the hill, and optionally why.
///
/// A single current hill position tells you where a project stands. A *series* of them tells you
/// whether it's moving, which is the question that actually matters and the one no percentage bar
/// can answer. Two dots three weeks apart in the same place is the clearest "this is stuck" signal
/// a solo project tracker can give you, and it costs one row.
struct ProjectUpdate: Codable, Identifiable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    var id: String
    var projectId: String
    var createdAt: String
    /// The hill position recorded at this moment, 0…1.
    var hill: Double?
    /// An optional line in your own words. Never required — an update you have to write is an
    /// update you stop making.
    var note: String?

    static let databaseTableName = "project_updates"

    enum CodingKeys: String, CodingKey {
        case id
        case projectId = "project_id"
        case createdAt = "created_at"
        case hill, note
    }

    init(
        id: String = UUID().uuidString,
        projectId: String,
        createdAt: String = ISO8601DateFormatter().string(from: Date()),
        hill: Double? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.createdAt = createdAt
        self.hill = hill
        self.note = note
    }
}

/// The rules of the hill. Pure, so what counts as "stuck" is tested rather than eyeballed.
enum ProjectHill {

    /// Where the crest sits. Everything below is figuring out; everything above is executing.
    static let crest: Double = 0.5

    /// How long a project can sit in one place before the app says so. Deliberately generous:
    /// a fortnight of no movement on a long project is normal, three weeks is a signal.
    static let stalledAfterDays = 21

    /// Plain language for a position. No percentages — a hill position isn't a completion figure,
    /// and rendering it as one would invite exactly the false confidence it exists to prevent.
    static func label(_ hill: Double?) -> String {
        guard let hill else { return "Not tracked" }
        switch hill {
        case ..<0.08:      return "Not started"
        case ..<0.35:      return "Figuring it out"
        case ..<0.5:       return "Nearly there on the approach"
        case ..<0.62:      return "Over the hill"
        case ..<0.92:      return "Executing"
        default:           return "Almost done"
        }
    }

    /// A one-line read on what the position means for planning, which is the actual point of
    /// knowing it: uphill work can't be estimated, downhill work can.
    static func advice(_ hill: Double?) -> String? {
        guard let hill else { return nil }
        if hill < crest {
            return "Still unknowns here — plan time to think, not time to execute."
        }
        return "The unknowns are gone. What's left is work you can put in the calendar."
    }

    /// Whether a project has sat in one place long enough to be worth mentioning.
    ///
    /// Deliberately measured from the last hill *movement* rather than the last completed task:
    /// ticking small things off while the real problem sits untouched is the exact pattern this is
    /// meant to catch, and completion dates would hide it.
    static func isStalled(
        hill: Double?,
        hillUpdatedAt: String?,
        now: Date = Date(),
        calendar: Calendar = .current,
        afterDays: Int = stalledAfterDays
    ) -> Bool {
        // Never tracked, or finished: neither is stuck.
        guard let hill, hill < 0.999, let updated = DueDate.parse(hillUpdatedAt) else { return false }
        let days = calendar.dateComponents([.day], from: updated, to: now).day ?? 0
        return days >= afterDays
    }

    /// How many days a project has been sitting where it is.
    static func daysSinceMoved(_ hillUpdatedAt: String?, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let updated = DueDate.parse(hillUpdatedAt) else { return nil }
        return calendar.dateComponents([.day], from: updated, to: now).day
    }

    /// Clamp anything coming from a drag or the wire into the valid range.
    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

extension String {
    /// `nil` when there's nothing here worth storing.
    ///
    /// Optional-vs-empty is a distinction the database cares about and a person doesn't: an empty
    /// note and no note are the same thing to read, but only one of them makes `if let note` do the
    /// right thing at every call site.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
