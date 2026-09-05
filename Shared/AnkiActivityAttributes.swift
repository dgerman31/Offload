import Foundation
import ActivityKit

/// Today's Anki queue on the Lock Screen, until it's empty.
///
/// Compiled into both the app and the widget extension. Everything crossing over is a count — no
/// deck contents, nothing that would need an App Group, which this app can't have anyway.
///
/// Unlike the focus timer, nothing here ticks by itself: the numbers only change when Offload
/// fetches a new snapshot, so the state carries `updatedAt` and the widget says how old it is. A
/// bar that looked live while sitting on twenty-minute-old figures would be worse than one that
/// admits its age.
struct AnkiActivityAttributes: ActivityAttributes {
    /// The deck being tracked. Fixed for the life of the activity.
    var deck: String

    struct ContentState: Codable, Hashable {
        var done: Int
        var remaining: Int
        var newRemaining: Int
        /// Roughly how long the rest will take, from the app's answer-based model.
        var minutesLeft: Int
        var updatedAt: Date

        var total: Int { max(done + remaining, done) }
        var progress: Double {
            guard total > 0 else { return 1 }
            return min(1, max(0, Double(done) / Double(total)))
        }
    }
}
