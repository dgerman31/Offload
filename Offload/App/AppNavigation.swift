import SwiftUI

/// Which bottom tab is showing, and where a deep-link should land once it's there. A gym-linked
/// task tapped on Home or Day doesn't open the normal task detail sheet — it switches to the Gym
/// tab and opens that exact session, so the workout's real detail lives in exactly one place.
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    var selectedTab: RootTab = .home
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
