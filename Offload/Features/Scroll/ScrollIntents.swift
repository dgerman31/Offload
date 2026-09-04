import AppIntents

/// The sensor. Or rather: the place where *you* are the sensor.
///
/// No iOS app can see which other app you're in — there's no foreground-app API, and reading
/// another app's screen is out of the question. The only official route is Screen Time
/// (`FamilyControls`), whose entitlement needs a paid account and Apple's written approval.
///
/// So the signal comes from a Shortcuts **personal automation** you set up once: *when Instagram is
/// opened, run this*. Set to Run Immediately it fires silently, and Offload gets woken just long
/// enough to start the clock and hand the ladder to the system. It's a doorbell rather than a lock —
/// you could delete the automation in fifteen seconds — but a doorbell you chose to install is the
/// strongest thing available without the entitlement, and it costs nothing to ignore on the days
/// you don't want it.
///
/// `openAppWhenRun = false` throughout: being yanked into Offload every time you open a feed would
/// be its own kind of interruption, and a worse one than the ladder.
struct StartScrollWatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Start scroll timer"
    static let description = IntentDescription(
        "Starts Offload's scroll timer. Point a Shortcuts automation at this — \"when Instagram is opened, run this\" — and Offload will start counting and nudge you as it climbs."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await ScrollWatch.shared.start()
        return .result()
    }
}

/// The other half of the automation: *when Instagram is closed, run this*.
///
/// Optional, and the feature works without it — `ScrollGuard.autoEndSeconds` caps a session either
/// way. But with it the daily total is honest and the nudges stop the second you stop, which is the
/// difference between a tool that feels attentive and one that feels broken.
struct StopScrollWatchIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop scroll timer"
    static let description = IntentDescription(
        "Stops Offload's scroll timer and clears any pending nudges. Pair it with the start automation — \"when Instagram is closed, run this\"."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await ScrollWatch.shared.stop()
        return .result()
    }
}

/// Quiet, from a Shortcut or from Siri — for the times you've decided to sit down and scroll, and
/// would rather say so than be argued with for twenty minutes.
struct QuietScrollGuardIntent: AppIntent {
    static let title: LocalizedStringResource = "Quiet the scroll timer for an hour"
    static let description = IntentDescription("Stops the scroll timer nudging for the next hour.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        await ScrollWatch.shared.snooze(.oneHour)
        return .result()
    }
}
