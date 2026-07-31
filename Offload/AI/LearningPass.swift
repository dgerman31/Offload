import Foundation
import GRDB

/// The nightly recompute: read everything that happened, work out what it means, save one profile.
///
/// Deliberately a single pass rather than each feature learning on demand. Learning on demand
/// means a full-table read inside a view body, five different definitions of "enough evidence",
/// and five chances to get the isolation wrong. This runs on the background task the app already
/// schedules (`BackgroundSynthesis`, roughly every six hours) plus once a day at launch, and the
/// planner just reads the result synchronously.
///
/// Nothing here is expensive: three table reads and some medians. It's on a background task
/// because it has no reason to be on the critical path, not because it's heavy.
enum LearningPass {

    nonisolated static let lastRunKey = "offload.learning.lastRun"

    /// Recompute and store. Best-effort throughout: a learning pass that fails should cost the
    /// user nothing except a stale profile.
    @discardableResult
    static func run(db: AppDatabase = .shared, defaults: UserDefaults = .standard, now: Date = Date()) async -> LearnedProfile? {
        let data = try? await db.dbQueue.read { database -> ([TaskItem], [TaskSession]) in
            let tasks = try TaskItem.filter(Column("deleted") == false).fetchAll(database)
            let sessions = try TaskSession.fetchAll(database)
            return (tasks, sessions)
        }
        guard let (tasks, sessions) = data else {
            Log.ai.error("Learning pass could not read history")
            return nil
        }

        let profile = build(tasks: tasks, sessions: sessions, now: now)
        LearnedProfile.save(profile, defaults: defaults)
        defaults.set(now.timeIntervalSince1970, forKey: lastRunKey)
        // Counts only. What the app has learned is derived from the user's own task titles, and
        // none of that belongs in a log.
        Log.ai.info("""
            Learning pass: \(profile.finishedTaskSample, privacy: .public) finished tasks, \
            \(profile.sessionSample, privacy: .public) sessions, \
            \(profile.estimatePriors.count, privacy: .public) priors, \
            \(profile.glossary.count, privacy: .public) terms
            """)
        return profile
    }

    /// The whole computation, pure — so what the app concludes from a given history is testable
    /// without a database or a clock.
    static func build(tasks: [TaskItem], sessions: [TaskSession], now: Date = Date()) -> LearnedProfile {
        var profile = LearnedProfile()
        profile.updatedAt = now

        profile.driftOverall = TaskSessionLog.drift(sessions: sessions, tasks: tasks)
        profile.finishedTaskSample = finishedSample(tasks: tasks, sessions: sessions)
        for category in Set(tasks.compactMap(\.category)) {
            // Only a category's *own* evidence counts here. `TaskSessionLog.drift` falls back to
            // the overall figure for a thin category, which is right at the call site and wrong
            // here — storing the fallback would make every category look independently confident.
            let ownTasks = tasks.filter { $0.category == category }
            if let drift = TaskSessionLog.drift(sessions: sessions, tasks: ownTasks) {
                profile.driftByCategory[category] = drift
            }
        }

        let curve = EnergyCurve.learn(sessions)
        profile.hourScores = curve.scores
        profile.peakHours = curve.peak
        profile.sessionSample = curve.sample

        profile.estimatePriors = EstimatePriors.learn(tasks: tasks, sessions: sessions)
        profile.glossary = Glossary.learn(tasks: tasks)
        return profile
    }

    /// How many finished tasks actually carry timed evidence — the sample behind the drift figures.
    private static func finishedSample(tasks: [TaskItem], sessions: [TaskSession]) -> Int {
        let timed = Set(sessions.map(\.taskId))
        return tasks.filter {
            $0.status == "completed" && !$0.deleted && timed.contains($0.id)
                && ($0.effortMinutes ?? 0) > 0
        }.count
    }

    /// Run at most once a day from the foreground, so a user who never leaves the app idle long
    /// enough for a background task still gets a current profile.
    static func runIfStale(db: AppDatabase = .shared, defaults: UserDefaults = .standard, now: Date = Date()) async {
        let last = defaults.object(forKey: lastRunKey) as? Double
        if let last, now.timeIntervalSince1970 - last < 20 * 3600 { return }
        await run(db: db, defaults: defaults, now: now)
    }
}
