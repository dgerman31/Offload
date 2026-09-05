import SwiftUI

/// Which bottom tab is showing, and where a deep-link should land once it's there. A gym-linked
/// task tapped on Home or Day doesn't open the normal task detail sheet — it switches to the Gym
/// tab and opens that exact session, so the workout's real detail lives in exactly one place.
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    var selectedTab: RootTab = .home
    /// Bumped every time the Day tab is chosen from the bar. The Day tab watches it and jumps back
    /// to today.
    ///
    /// A counter rather than a flag because the interesting case is pressing Day *while already on
    /// Day* — the selection doesn't change, so there's nothing for an `onChange` to observe. An
    /// always-incrementing value gives every press something to react to.
    private(set) var dayTodayRequest = 0

    /// "Take me to today." Called when the Day tab is pressed, and safe to call when it's already
    /// showing.
    func requestToday() { dayTodayRequest += 1 }
    /// One-shot: set when a gym-linked task is tapped elsewhere; the Gym tab consumes it once
    /// (opens the session, clears it) so returning to the tab later doesn't re-trigger it.
    private(set) var pendingGymSessionId: String?

    private init() {}

    func openGymSession(_ id: String) {
        pendingGymSessionId = id
        selectedTab = .gym
    }

    func consumePendingGymSession() -> String? {
        defer { pendingGymSessionId = nil }
        return pendingGymSessionId
    }
}
