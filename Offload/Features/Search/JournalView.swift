import SwiftUI
import GRDB

/// Everything you've ever said to the app, in your own words.
///
/// The extractor deliberately produces no task for pure venting or a passing idea — which is
/// right, but it also meant those captures disappeared. They're still recorded, so this gives
/// them a home: a plain, chronological record of what you offloaded, whether or not it turned
/// into a to-do. It doubles as the honest audit trail for "did it actually get that?".
struct JournalView: View {
    @State private var store = JournalStore()
    @State private var appeared = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if store.days.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing captured yet")
                            .font(.Offload.taskTitle)
                            .foregroundStyle(Color.Offload.text)
                        Text("Everything you speak or type appears here in your own words — including the thoughts that didn't need to become tasks.")
                            .font(.Offload.body)
                            .foregroundStyle(Color.Offload.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .offloadCard()
                }

                ForEach(Array(store.days.enumerated()), id: \.element.id) { index, day in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(day.label.uppercased())
                            .font(.caption2).fontWeight(.bold)
                            .tracking(0.9)
                            .foregroundStyle(Color.Offload.muted)

                        VStack(spacing: 8) {
                            ForEach(day.captures) { capture in
                                captureRow(capture)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appearIn(min(index, 8), when: appeared)
                    .scrollAppearSubtle()
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        .background(Color.Offload.background)
        .navigationTitle("Journal")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.observe() }
        .task { withAnimation(Motion.settle) { appeared = true } }
    }

    private func captureRow(_ capture: Capture) -> some View {
        let taskCount = JournalStore.taskCount(capture)
        return VStack(alignment: .leading, spacing: 8) {
            Text(capture.rawInput)
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.text)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Label(capture.inputType == "voice" ? "Spoken" : "Typed",
                      systemImage: capture.inputType == "voice" ? "waveform" : "keyboard")
                    .font(.caption2)
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(Color.Offload.muted)

                if let time = DueDate.parse(capture.createdAt) {
                    Text(CalendarView.time(time))
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                }

                Spacer(minLength: 0)

                // What it became — including "nothing", which is a valid and deliberate result.
                Text(taskCount == 0 ? "Just a thought" : "\(taskCount) task\(taskCount == 1 ? "" : "s")")
                    .font(.caption2).fontWeight(.semibold)
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background((taskCount == 0 ? Color.Offload.muted : Color.Offload.teal).opacity(0.13),
                                in: .capsule)
                    .foregroundStyle(taskCount == 0 ? Color.Offload.muted : Color.Offload.teal)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard(cornerRadius: 14)
    }
}

/// Captures grouped by day, newest first.
@MainActor
@Observable
final class JournalStore {

    struct Day: Identifiable, Sendable {
        let label: String
        let captures: [Capture]
        var id: String { label }
    }

    private(set) var days: [Day] = []

    private let db: AppDatabase
    init(db: AppDatabase = .shared) { self.db = db }

    func observe() async {
        let observation = ValueObservation.tracking { db in
            try Capture.order(Column("created_at").desc).limit(300).fetchAll(db)
        }
        do {
            for try await captures in observation.values(in: db.dbQueue) {
                days = Self.group(captures, now: Date())
            }
        } catch {
            // Observation ended.
        }
    }

    /// How many tasks a capture produced — stored as a JSON id array at capture time.
    nonisolated static func taskCount(_ capture: Capture) -> Int {
        guard let json = capture.extractedTaskIds,
              let data = json.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return 0 }
        return ids.count
    }

    /// Group by calendar day with friendly headers. Pure and testable.
    nonisolated static func group(_ captures: [Capture], now: Date, calendar: Calendar = .current) -> [Day] {
        var order: [String] = []
        var grouped: [String: [Capture]] = [:]

        for capture in captures {
            guard let created = DueDate.parse(capture.createdAt) else { continue }
            let label = dayLabel(created, now: now, calendar: calendar)
            if grouped[label] == nil { order.append(label) }
            grouped[label, default: []].append(capture)
        }
        return order.compactMap { label in
            guard let items = grouped[label] else { return nil }
            return Day(label: label, captures: items)
        }
    }

    nonisolated static func dayLabel(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let df = DateFormatter()
        df.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "EEEE, MMM d" : "MMM d, yyyy"
        return df.string(from: date)
    }
}
