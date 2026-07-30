import Foundation
import ActivityKit

/// The Live Activity contract for a focus session — compiled into **both** the app and the widget
/// extension, which is why it lives outside either one.
///
/// Everything crossing to the Lock Screen goes through here. Note what isn't in it: no database
/// handle, no shared container, nothing that would need an App Group. That's deliberate — this
/// app is signed with a free Apple ID, which can't have App Groups at all, and ActivityKit
/// serializes this state across to the extension by itself. A Live Activity needs no entitlement.
struct FocusActivityAttributes: ActivityAttributes {

    /// Fixed for the life of the activity: which task this session is for.
    var taskTitle: String
    /// Hex of the task's category accent, so the Lock Screen matches the app.
    var accentHex: UInt32

    /// The parts that change as the session runs.
    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// The window the current phase occupies. `Text(timerInterval:)` counts down against this
        /// **by itself**, once per second, with no push updates and no background execution — the
        /// system owns the ticking. That's the whole reason the timer keeps working with the app
        /// suspended or killed: the Lock Screen isn't being told the time, it's being told the
        /// deadline.
        var phaseStart: Date
        var phaseEnd: Date
        /// Frozen countdown while paused. `Text(timerInterval:)` can't represent a paused clock,
        /// so the widget renders this as static text instead.
        var pausedRemaining: TimeInterval?
        /// Focus blocks finished in this session, for the pomodoro dots.
        var completedBlocks: Int
        /// True when a phase has ended and the next one is waiting on a tap.
        var awaitingStart: Bool

        var isPaused: Bool { pausedRemaining != nil }
        var isRunning: Bool { pausedRemaining == nil && !awaitingStart }
    }

    /// Focus or one of the two breaks. Shared rather than duplicated in the widget, so the app and
    /// the Lock Screen can never disagree about what a session is doing.
    enum Phase: String, Codable, Hashable, Sendable {
        case focus, shortBreak, longBreak

        var isBreak: Bool { self != .focus }

        /// What the Lock Screen calls it.
        var label: String {
            switch self {
            case .focus:      return "Focus"
            case .shortBreak: return "Break"
            case .longBreak:  return "Long break"
            }
        }

        /// Kept to symbols that have existed for many releases. An `Image(systemName:)` with a
        /// name the device doesn't know renders as nothing at all — which on a Lock Screen widget
        /// is indistinguishable from the whole feature being broken.
        var symbol: String {
            switch self {
            case .focus:      return "timer"
            case .shortBreak: return "cup.and.saucer.fill"
            case .longBreak:  return "figure.walk"
            }
        }
    }
}
