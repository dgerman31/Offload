import Testing
import Foundation
@testable import Offload

/// Which Gemini failures are worth another attempt, and how long to wait.
///
/// All pure — `RetryPolicy` deliberately keeps classification and backoff math out of the
/// networking code, and `delay` takes an injectable random source, so none of this sleeps or
/// touches the network.
struct RetryPolicyTests {

    // MARK: Classification

    @Test func cancellationIsNeverRetried() {
        #expect(RetryPolicy.classify(CancellationError()) == .cancelled)
        #expect(RetryPolicy.classify(URLError(.cancelled)) == .cancelled)
    }

    @Test func transientNetworkFailuresAreRetryable() {
        for code: URLError.Code in [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                                    .dnsLookupFailed, .notConnectedToInternet] {
            #expect(RetryPolicy.classify(URLError(code)) == .retryable,
                    "URLError(\(code.rawValue)) should be retryable")
        }
    }

    /// The whole reason retry exists: a rate-limited or overloaded model is the *normal*
    /// transient failure, and falling straight through to the on-device model on a 429 is what
    /// made "the cloud isn't available" mean "the cloud blipped".
    @Test func serverSideFailuresAreRetryable() {
        for status in [429, 500, 502, 503, 408, 499] {
            let error = GeminiError.http(status: status, message: "", retryAfter: nil)
            #expect(RetryPolicy.classify(error) == .retryable, "HTTP \(status) should be retryable")
        }
    }

    /// The other half: retrying a malformed request just spends the day's budget re-failing the
    /// identical call four times slower.
    @Test func clientMistakesAreTerminal() {
        for status in [400, 404, 422] {
            let error = GeminiError.http(status: status, message: "", retryAfter: nil)
            #expect(RetryPolicy.classify(error) == .terminal, "HTTP \(status) should be terminal")
        }
    }

    @Test func forbiddenNeedsTheUser() {
        let error = GeminiError.http(status: 403, message: "", retryAfter: nil)
        #expect(RetryPolicy.classify(error) == .needsUserAction)
    }

    @Test func shapeProblemsAreTerminal() {
        #expect(RetryPolicy.classify(GeminiError.badResponse) == .terminal)
        #expect(RetryPolicy.classify(GeminiError.blocked) == .terminal)
        #expect(RetryPolicy.classify(GeminiError.emptyResponse) == .terminal)
        #expect(RetryPolicy.classify(GeminiError.noKey) == .terminal)
    }

    @Test func isRetryableAgreesWithClassify() {
        #expect(RetryPolicy.isRetryable(URLError(.timedOut)))
        #expect(!RetryPolicy.isRetryable(CancellationError()))
        #expect(!RetryPolicy.isRetryable(GeminiError.badResponse))
    }

    // MARK: Backoff

    @Test func ceilingDoublesThenCaps() {
        #expect(RetryPolicy.ceiling(attempt: 1) == 1)
        #expect(RetryPolicy.ceiling(attempt: 2) == 2)
        #expect(RetryPolicy.ceiling(attempt: 3) == 4)
        #expect(RetryPolicy.ceiling(attempt: 4) == 8)
        // Capped, not unbounded — a long-running loop must not stretch to minutes.
        #expect(RetryPolicy.ceiling(attempt: 5) == 8)
        #expect(RetryPolicy.ceiling(attempt: 12) == 8)
    }

    /// Attempt numbering starts at 1; a defensive 0 must not produce a *fraction* of the base
    /// (`2^-1`), which would make the first wait shorter than intended.
    @Test func ceilingClampsAttemptsBelowOne() {
        #expect(RetryPolicy.ceiling(attempt: 0) == 1)
        #expect(RetryPolicy.ceiling(attempt: -3) == 1)
    }

    /// Full jitter: uniform over `[0, ceiling]`, not `ceiling ± noise`. Asserted through the
    /// injected source rather than statistically, so the test is deterministic.
    @Test func delayDrawsFromTheFullRange() {
        var seen: ClosedRange<TimeInterval>?
        let value = RetryPolicy.delay(attempt: 3) { range in
            seen = range
            return range.upperBound
        }
        #expect(seen == 0...4)
        #expect(value == 4)

        let low = RetryPolicy.delay(attempt: 3) { $0.lowerBound }
        #expect(low == 0)
    }

    @Test func delayHonoursCustomBaseAndCap() {
        let range = RetryPolicy.delay(attempt: 4, base: 0.5, cap: 2) { $0.upperBound }
        // 0.5 * 2^3 = 4, capped at 2.
        #expect(range == 2)
    }

    @Test func maxAttemptsIsBounded() {
        // Enough to clear a genuine blip, few enough that the on-device fallback isn't left
        // waiting longer than it would have taken to just run.
        #expect(RetryPolicy.maxAttempts == 4)
    }
}
