import Testing
import Foundation
@testable import Offload

/// The numbers behind the Anki bar, and the forecast that only speaks when it should.
struct AnkiBridgeTests {

    private func snapshot(
        reviewsDone: Int = 0, newDone: Int = 0,
        reviewsRemaining: Int = 0, learningRemaining: Int = 0, newRemaining: Int = 0,
        forecast: [AnkiSnapshot.ForecastDay] = [],
        generatedAt: String = "2026-09-05T12:00:00Z",
        cutoff: TimeInterval = 1_788_667_200   // 2026-09-06T04:00:00Z
    ) -> AnkiSnapshot {
        AnkiSnapshot(
            generatedAt: generatedAt,
            deck: "AnKing",
            dayCutoff: cutoff,
            today: .init(reviewsDone: reviewsDone, newDone: newDone,
                         reviewsRemaining: reviewsRemaining,
                         learningRemaining: learningRemaining,
                         newRemaining: newRemaining,
                         answersDone: nil),
            forecast: forecast
        )
    }

    private func at(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: iso) ?? .distantPast
    }

    // MARK: The bar

    @Test("Progress is cards cleared out of what today amounted to")
    func progressMaths() {
        let s = snapshot(reviewsDone: 120, reviewsRemaining: 80)
        #expect(s.dueRemaining == 80)
        #expect(s.dueTotal == 200)
        #expect(s.progress == 0.6)
        #expect(!s.isClear)
    }

    @Test("Cards mid-learning count as still due")
    func learningCountsAsDue() {
        // They're in front of you either way — a bar that ignored them would say "done" while Anki
        // still had cards to show.
        let s = snapshot(reviewsDone: 50, reviewsRemaining: 10, learningRemaining: 6)
        #expect(s.dueRemaining == 16)
        #expect(!s.isClear)
    }

    @Test("A day with nothing due is complete, not empty")
    func emptyDayIsDone() {
        // Otherwise a rest day would draw an empty bar reading 0%, which is the opposite of true.
        let s = snapshot()
        #expect(s.progress == 1)
        #expect(s.isClear)
    }

    @Test("Progress never leaves 0…1, whatever the add-on reports")
    func progressIsClamped() {
        #expect(snapshot(reviewsDone: 300, reviewsRemaining: 0).progress == 1)
        #expect(snapshot(reviewsDone: 0, reviewsRemaining: 300).progress == 0)
    }

    // MARK: Freshness — the Mac is often asleep

    @Test("A snapshot expires at Anki's rollover, not at midnight")
    func expiresAtTheRollover() {
        let s = snapshot()
        #expect(!s.isExpired(now: at("2026-09-06T03:59:00Z")))
        #expect(s.isExpired(now: at("2026-09-06T04:00:00Z")))
    }

    @Test("Age is said out loud once it's worth knowing, and not before")
    func freshnessLabel() {
        let s = snapshot()
        // A minute behind is live enough that saying so would be noise.
        #expect(s.freshnessLabel(now: at("2026-09-05T12:01:00Z")) == nil)
        #expect(s.freshnessLabel(now: at("2026-09-05T12:20:00Z")) == "Updated 20 min ago")
        #expect(s.freshnessLabel(now: at("2026-09-05T15:00:00Z")) == "Updated 3h ago")
    }

    @Test("A snapshot with an unreadable timestamp is treated as stale, never as fresh")
    func unparsableIsStale() {
        let s = snapshot(generatedAt: "not a date")
        #expect(s.isStale(now: at("2026-09-05T12:00:00Z")))
        #expect(s.freshnessLabel(now: at("2026-09-05T12:00:00Z")) == "Never updated")
    }

    // MARK: The forecast

    @Test("A genuine spike is called out")
    func spikeIsReported() throws {
        let forecast = [
            AnkiSnapshot.ForecastDay(day: 1, reviews: 140),
            .init(day: 2, reviews: 420),
            .init(day: 3, reviews: 150),
            .init(day: 4, reviews: 130)
        ]
        let warning = try #require(AnkiForecast.warning(forecast))
        #expect(warning.contains("The day after tomorrow"))
        #expect(warning.contains("420"))
    }

    @Test("An ordinary week says nothing at all")
    func quietWeekIsSilent() {
        // A forecast that comments every morning becomes weather. Silence is the default.
        let flat = (1...7).map { AnkiSnapshot.ForecastDay(day: $0, reviews: 150) }
        #expect(AnkiForecast.warning(flat) == nil)
    }

    @Test("A small spike on a light week isn't worth a warning")
    func smallNumbersAreIgnored() {
        // Triple a tiny day is still a tiny day; waking someone for 30 cards trains them to ignore
        // the one that matters.
        let light = [AnkiSnapshot.ForecastDay(day: 1, reviews: 10), .init(day: 2, reviews: 30)]
        #expect(AnkiForecast.warning(light) == nil)
    }

    @Test("The baseline excludes the day being compared")
    func baselineExcludesTomorrow() {
        // Including tomorrow in its own baseline flattens exactly the spike we're looking for.
        let forecast = [AnkiSnapshot.ForecastDay(day: 1, reviews: 400),
                        .init(day: 2, reviews: 100), .init(day: 3, reviews: 100)]
        #expect(AnkiForecast.baseline(forecast, excluding: 1) == 100)
        #expect(AnkiForecast.peak(forecast)?.day == 1)
        #expect(AnkiForecast.warning(forecast)?.contains("Tomorrow") == true)
    }

    // MARK: The wire

    @Test("A snapshot from the add-on decodes, including one from a newer add-on")
    func decodesTheAddOnPayload() throws {
        // `answersDone` was added after the first version. A snapshot that failed to decode because
        // the add-on gained a field is a bar that silently vanishes — and the two are updated
        // independently, so that has to be survivable.
        let json = """
        {
          "generatedAt": "2026-09-05T12:00:00Z",
          "deck": "AnKing",
          "dayCutoff": 1788667200,
          "today": {
            "reviewsDone": 143, "newDone": 12, "reviewsRemaining": 210,
            "learningRemaining": 8, "newRemaining": 8
          },
          "forecast": [{"day": 1, "reviews": 180}, {"day": 2, "reviews": 220}]
        }
        """
        let decoded = try JSONDecoder().decode(AnkiSnapshot.self, from: Data(json.utf8))
        #expect(decoded.deck == "AnKing")
        #expect(decoded.dueRemaining == 218)
        #expect(decoded.today.answersDone == nil)
        #expect(decoded.forecast.count == 2)
    }
}
