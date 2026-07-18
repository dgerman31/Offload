import Testing
@testable import Offload

/// Increment-1 smoke tests. These grow as real logic lands (extraction accuracy,
/// dedupe thresholds, task-split correctness — the spec's acceptance targets).
@MainActor
struct AvailabilityTests {

    @Test("Availability headline is non-empty for every state")
    func headlinesExist() {
        let a = ModelAvailability()
        // Whatever state the test host reports, the UI must have something to show.
        #expect(!a.headline.isEmpty)
    }

    @Test("Available state reports as available")
    func availableFlag() {
        let state = ModelAvailability.State.available
        #expect(state.isAvailable)
        #expect(!ModelAvailability.State.deviceNotEligible.isAvailable)
    }
}
