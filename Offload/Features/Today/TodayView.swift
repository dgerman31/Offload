import SwiftUI

/// Today — time-boxed sections + a "next best task" suggestion (spec §5.4).
/// Placeholder until the data layer + scheduling logic land.
struct TodayView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Your day, sorted",
                systemImage: "sun.max",
                description: Text("Captured tasks will appear here grouped by Morning, Afternoon, and Evening, with a suggestion sized to your free time.")
            )
            .background(Color.Offload.background)
            .navigationTitle("Today")
        }
    }
}

#Preview { TodayView() }
