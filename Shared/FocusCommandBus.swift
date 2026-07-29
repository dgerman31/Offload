import Foundation

/// The four things a Lock Screen button can ask the timer to do.
enum FocusCommand: String, Sendable {
    case pause, resume, skip, end
}

/// How a Live Activity button reaches the timer.
///
/// The awkwardness this solves: `Button(intent:)` needs the intent **type** to be compiled into
/// the widget extension, but the timer it drives lives in the app and can't be — it reaches into
/// the database, the log, and the design system, none of which the extension has. Compiling
/// `FocusTimer` into both targets to satisfy a button would be the tail wagging the dog.
///
/// So the intents live in `Shared` and speak through this bus instead. The app installs a handler
/// at launch; the widget's copy never installs one and never needs to, because a
/// `LiveActivityIntent` runs in the **app's** process, not the extension's. In the extension this
/// is dead code that exists only so the type resolves.
///
/// The usual way to bridge an extension and its app is an App Group. There isn't one here and
/// can't be — this app is signed with a free Apple ID, which doesn't get them — so the bridge has
/// to be the process boundary the system already crosses for us.
@MainActor
enum FocusCommandBus {
    /// Installed once, by the app, at launch.
    private static var handler: ((FocusCommand) -> Void)?

    static func install(_ handler: @escaping (FocusCommand) -> Void) {
        Self.handler = handler
    }

    static func send(_ command: FocusCommand) {
        handler?(command)
    }
}
