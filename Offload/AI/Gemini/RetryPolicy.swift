import Foundation

/// Decides whether a failed Gemini call is worth retrying, and how long to wait before the next
/// attempt.
///
/// Before this existed, `GeminiClient` had no retry at all: any hiccup — a dropped connection
/// mid-flight, Google returning a 503 while a model is overloaded, a 429 during a burst — fell
/// straight through to the on-device fallback. That's safe (the raw capture is never lost) but
/// wasteful: a large fraction of "the cloud isn't available" was actually "the cloud blipped for
/// half a second," degrading quality for no real reason. The other half of the problem is the
/// opposite mistake: retrying a 400 or a bad API key just spends the day's budget re-failing the
/// same request four times slower. This type is what tells the caller which situation it's in.
enum RetryPolicy {

    /// What to do with a failed attempt.
    enum Classification: Sendable, Equatable {
        /// Transient — the same request would plausibly succeed a moment later. Safe to retry
        /// with backoff.
        case retryable
        /// The caller (or the user) cancelled the work — a view disappeared, a navigation
        /// happened. Not a failure of the network or the API at all, so it is never retried and
        /// never logged as an error.
        case cancelled
        /// Our request is malformed, or the endpoint is wrong. Retrying reproduces the identical
        /// failure every time, just slower — this is a bug, not a network condition, so it's
        /// logged loudly instead of retried.
        case terminal
        /// The API rejected us for a reason only the user can fix (an expired or invalid key).
        /// Retrying can't help; the fix lives in Settings, not in this loop.
        case needsUserAction
    }

    /// Attempts allowed for one logical call, counting the first try. Google's own retry guidance
    /// for `generateContent` suggests a handful of attempts with capped exponential backoff — four
    /// total (three retries) clears a genuine blip without keeping the user's spinner up so long
    /// that the on-device fallback would have been faster.
    static let maxAttempts = 4

    /// Classify a thrown error. `GeminiError.http` already carries the status code Google
    /// returned, so the table below is just "which of Gemini's documented codes mean what."
    static func classify(_ error: Error) -> Classification {
        if error is CancellationError { return .cancelled }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed,
                 .notConnectedToInternet:
                return .retryable
            case .userAuthenticationRequired, .appTransportSecurityRequiresSecureConnection:
                return .terminal
            default:
                return .terminal
            }
        }

        if let geminiError = error as? GeminiError, case let .http(status, _, _) = geminiError {
            switch status {
            case 429, 503, 408, 499:
                return .retryable
            case 500...599:
                return .retryable
            case 403:
                return .needsUserAction
            default:
                // Includes 400 (INVALID_ARGUMENT) and 404 (wrong model/endpoint): both are bugs
                // in what we sent, not conditions the network will clear up on its own.
                return .terminal
            }
        }

        // Anything else (JSON encoding, decoding, `.badResponse`, `.blocked`, `.emptyResponse`) is
        // a shape-of-the-data problem a retry can't fix.
        return .terminal
    }

    static func isRetryable(_ error: Error) -> Bool {
        classify(error) == .retryable
    }

    // MARK: Backoff

    /// The full-jitter ceiling for a given attempt: `min(cap, base * 2^(attempt-1))`, so the
    /// first failed attempt (1) gives a ~1s ceiling, the second ~2s, the third ~4s, and so on up
    /// to `cap` — Google's own rough guidance of "1s → 2s → 4s → 8s, capped." Pure and
    /// deterministic — no randomness — so the growth curve itself is directly assertable in a
    /// test without needing to control a random source.
    static func ceiling(attempt: Int, base: TimeInterval = 1, cap: TimeInterval = 8) -> TimeInterval {
        min(cap, base * pow(2, Double(max(0, attempt - 1))))
    }

    /// The delay before the next attempt: uniform over `[0, ceiling]` (AWS's "full jitter" —
    /// https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/ — and Google's
    /// own retry guidance both recommend this over `ceiling + a bit of noise`: a full-width
    /// uniform draw decorrelates retries from a burst of clients that all failed at the same
    /// moment, instead of having them re-converge on the same instant).
    ///
    /// `randomSource` is injected so tests can assert the range without relying on statistics —
    /// pass a fixed function and check the exact value it produces.
    static func delay(
        attempt: Int,
        base: TimeInterval = 1,
        cap: TimeInterval = 8,
        randomSource: (ClosedRange<TimeInterval>) -> TimeInterval = { Double.random(in: $0) }
    ) -> TimeInterval {
        let exp = ceiling(attempt: attempt, base: base, cap: cap)
        guard exp > 0 else { return 0 }
        return randomSource(0...exp)
    }
}
