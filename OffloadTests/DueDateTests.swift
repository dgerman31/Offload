import Testing
import Foundation
@testable import Offload

/// Regression coverage for the round-2 punch-list timing bug: the model frequently emits
/// `dueDate` without seconds and/or a timezone offset, which a bare `ISO8601DateFormatter`
/// silently fails to parse — dropping the task into "Anytime". `DueDate` must handle those
/// shapes and normalize them to a canonical, always-parseable form for storage.
struct DueDateTests {

    @Test("Parses full ISO8601 with timezone and fractional seconds")
    func parsesStrictISO8601() {
        #expect(DueDate.parse("2026-07-19T09:00:00Z") != nil)
        #expect(DueDate.parse("2026-07-19T09:00:00.123Z") != nil)
    }

    @Test("Parses model output missing seconds and/or timezone")
    func parsesLenientShapes() {
        #expect(DueDate.parse("2026-07-19T09:00") != nil)
        #expect(DueDate.parse("2026-07-19T09:00:00") != nil)
        #expect(DueDate.parse("2026-07-19 09:00") != nil)
        #expect(DueDate.parse("2026-07-19") != nil)
    }

    @Test("nil, empty, and garbage input parse to nil")
    func parsesInvalidToNil() {
        #expect(DueDate.parse(nil) == nil)
        #expect(DueDate.parse("") == nil)
        #expect(DueDate.parse("not a date") == nil)
    }

    @Test("normalize re-encodes to a timezone-qualified, strictly-parseable string")
    func normalizeProducesCanonicalForm() {
        let normalized = DueDate.normalize("2026-07-19T09:00")
        #expect(normalized != nil)
        // Must round-trip through a strict formatter, unlike the original input.
        #expect(ISO8601DateFormatter().date(from: normalized!) != nil)
    }

    @Test("normalize drops unparseable input rather than storing it as-is")
    func normalizeDropsGarbage() {
        #expect(DueDate.normalize("whenever") == nil)
        #expect(DueDate.normalize(nil) == nil)
    }
}
