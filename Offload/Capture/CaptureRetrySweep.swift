import Foundation
import GRDB

/// Re-attempts captures whose extraction failed.
///
/// `CaptureService.prepare` has always marked a failed extraction's row `failed` "so it can be
/// retried later" — but nothing ever read that status, so later never came. The user's words were
/// safely on disk and completely invisible: no task, no project, no trace anywhere in the UI.
/// That's the one failure the capture pipeline is built to make impossible, and it was silent.
///
/// This runs on foreground, which is the right trigger for the common cause: the on-device model
/// wasn't ready, or the network was gone. By the next time the app is opened, both have usually
/// changed. Bounded by `maxAttempts` so a capture the model genuinely can't handle is tried a few
/// times and then left alone, rather than burning AI budget on every launch forever.
@MainActor
enum CaptureRetrySweep {

    /// Total extraction attempts allowed per capture, counting the original. Small on purpose:
    /// the failures this clears are transient, and one that survives three separate app launches
    /// is not going to be fixed by a fourth.
    ///
    /// `nonisolated` because the GRDB read below hands its closure off as `@Sendable`, which
    /// can't reach a main-actor-isolated static. Both of these are immutable `Int`s — exactly
    /// the case `nonisolated` exists for.
    nonisolated static let maxAttempts = 3

    /// How many to retry in one sweep. This runs alongside routine materialization and the
    /// notification refresh on every foreground, and each retry is a full extraction — so it
    /// takes the oldest few rather than however many have accumulated.
    nonisolated static let batchSize = 3

    /// Retry the oldest eligible failed captures. Never throws: a sweep is opportunistic
    /// background repair, and a capture that fails again is simply left for the next foreground
    /// with its attempt counted.
    static func run(db: AppDatabase = .shared, service: CaptureService = CaptureService()) async {
        let pending: [Capture]
        do {
            pending = try await db.dbQueue.read { database in
                try Capture
                    .filter(Column("processing_status") == "failed")
                    .filter(Column("retry_count") < maxAttempts)
                    .order(Column("created_at"))
                    .limit(batchSize)
                    .fetchAll(database)
            }
        } catch {
            Log.capture.error("Retry sweep couldn't read failed captures: \(error.localizedDescription, privacy: .public)")
            return
        }

        guard !pending.isEmpty else { return }
        Log.capture.notice("Retrying \(pending.count, privacy: .public) failed capture(s)")

        for capture in pending {
            do {
                // `retrying:` reuses this row rather than inserting a new one, so a capture that
                // keeps failing converges on `maxAttempts` instead of leaving a fresh `failed`
                // row behind on every sweep.
                let outcome = try await service.process(
                    rawInput: capture.rawInput,
                    inputType: capture.inputType ?? "text",
                    retrying: capture
                )
                // Counts only — the capture's text is the user's own words and never goes to the
                // log, at any privacy level.
                //
                // Reaching here means a real extraction happened. When Gemini is unavailable
                // `process` throws instead of inventing a placeholder task, so the `catch` below
                // is the "still can't do it" path and this one can't lie about success.
                Log.capture.notice("Retry succeeded: \(outcome.addedTasks, privacy: .public) task(s) recovered")
            } catch {
                // `prepare` already re-marked the row failed and incremented its attempt count on
                // the way out, so there's nothing to write here.
                Log.capture.error("Retry failed (attempt \(capture.retryCount + 1, privacy: .public)/\(maxAttempts, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
