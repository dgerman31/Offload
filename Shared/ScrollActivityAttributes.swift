import Foundation
import ActivityKit

/// The Lock Screen witness for a scrolling session — compiled into both the app and the widget
/// extension, which is why it lives here rather than in either.
///
/// It is deliberately a *clock and nothing else*. The point of the first minute of this feature is
/// to put a number somewhere you'll see it without being told off, and a number that appears on
/// the Lock Screen while you're inside another app is the only place that works.
///
/// Note there is no periodic update anywhere: `startedAt` is fixed for the life of the activity and
/// the widget counts up from it with `Text(_:style: .timer)`, which the system ticks by itself. The
/// app is suspended the entire time this is on screen — it has to be, you're in Instagram — so
/// anything that needed the app to be running to stay correct would simply freeze.
struct ScrollActivityAttributes: ActivityAttributes {

    /// When the session began. The widget counts up from here, unaided.
    var startedAt: Date

    struct ContentState: Codable, Hashable {
        /// What you left open, if the app could work it out. Shown so the Lock Screen answers the
        /// question the feed erased — not "how long", but "instead of what".
        var task: String?
    }
}

/// What a button on the scroll bar can ask the app to do.
enum ScrollCommand: String, Sendable {
    /// Quiet for fifteen minutes. The escape hatch, one tap from wherever you are.
    case snooze
    /// I've stopped — end the session now.
    case stop
}

/// How a button on the Lock Screen reaches the app.
///
/// Same shape and the same reason as `FocusCommandBus`: a `LiveActivityIntent` runs in the **app's**
/// process rather than the extension's, so the intent type has to compile into the widget while the
/// work it triggers stays in the app. The app installs a handler at launch; the extension's copy
/// never does and never needs to. An App Group would be the usual bridge and there isn't one — a
/// free Apple ID doesn't get them — so the process boundary the system already crosses is the bridge.
@MainActor
enum ScrollCommandBus {
    private static var handler: ((ScrollCommand) -> Void)?

    static func install(_ handler: @escaping (ScrollCommand) -> Void) {
        Self.handler = handler
    }

    static func send(_ command: ScrollCommand) {
        handler?(command)
    }
}
