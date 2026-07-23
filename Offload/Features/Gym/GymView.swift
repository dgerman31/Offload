import SwiftUI

/// The Gym tab — a full weekly workout organizer, planned entirely by Gemini. Type what you want
/// ("plan my week", "5x/week, afternoons, unless I have class then the campus gym", "just legs
/// today") and it lays out real sessions: day, workout type, muscle groups, and a full exercise
/// prescription with sets/reps — plus mobility and stretching work where it belongs. Chips after
/// a plan let you hyperspecialize further. Planning a session also blocks its time on Home/Day
/// (title + time only); tapping that block from either screen lands back here, on that session.
struct GymView: View {
    @State private var store = GymStore()
    @State private var weekStart = GymStore.startOfWeek(Date())
    @State private var input = ""
    @State private var isPlanning = false
    @State private var planError: String?
    @State private var chips: [GymChip] = []
    @State private var lastScope: GymPlanScope?
    @State private var editingSession: WorkoutSession?
    @State private var appeared = false
    @FocusState private var inputFocused: Bool
    private var nav: AppNavigation { AppNavigation.shared }

    private var days: [Date] {
        (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    weekHeader.appearIn(0, when: appeared)
                    captureCard.appearIn(1, when: appeared)
                    if !chips.isEmpty {
                        chipRow.appearIn(2, when: appeared)
                    }
                    if let planError {
                        errorCard(planError).appearIn(2, when: appeared)
                    }
                    ForEach(Array(days.enumerated()), id: \.element.timeIntervalSince1970) { index, day in
                        dayCard(day).appearIn(min(index + 3, 9), when: appeared).scrollAppear()
                    }
                }
                .padding(16)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.Offload.background)
            .navigationTitle("Gym")
            .navigationBarTitleDisplayMode(.inline)
            .task { await store.observe() }
            .task { withAnimation(Motion.settle) { appeared = true } }
            .onChange(of: nav.selectedTab) { _, tab in
                guard tab == .gym, let id = nav.consumePendingGymSession() else { return }
                if let session = store.sessions.first(where: { $0.id == id }) {
                    weekStart = GymStore.startOfWeek(DueDate.parse(session.date + "T00:00") ?? Date())
                    editingSession = session
                }
            }
            .sheet(item: $editingSession) { session in
                NavigationStack {
                    GymSessionDetailView(session: session, store: store)
                }
            }
        }
    }

    // MARK: Week navigation

    private var weekHeader: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    withAnimation(Motion.page) { weekStart = Calendar.current.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart }
                } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.pressable(scale: 0.85))

                Spacer(minLength: 0)
                VStack(spacing: 1) {
                    Text(weekTitle).font(.Offload.manrope(15, .bold)).foregroundStyle(Color.Offload.text)
                    if !Calendar.current.isDate(weekStart, inSameDayAs: GymStore.startOfWeek(Date())) {
                        Button("This week") {
                            withAnimation(Motion.page) { weekStart = GymStore.startOfWeek(Date()) }
                        }
                        .font(.caption).foregroundStyle(Color.Offload.indigo)
                    }
                }
                Spacer(minLength: 0)

                Button {
                    withAnimation(Motion.page) { weekStart = Calendar.current.date(byAdding: .day, value: 7, to: weekStart) ?? weekStart }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.pressable(scale: 0.85))
            }
            .foregroundStyle(Color.Offload.muted)

            if weekProgress.total > 0 {
                weekProgressBar
            }
        }
    }

    /// "3 of 4 done this week" — the plan already exists to look at; this is the one place that
    /// says out loud whether it's actually being followed, so consistency is visible without
    /// having to open every day's card and count checkmarks yourself.
    private var weekProgress: (completed: Int, total: Int) {
        GymStore.weekProgress(store.sessions, weekStart: weekStart)
    }

    private var weekProgressBar: some View {
        let progress = weekProgress
        let fraction = progress.total == 0 ? 0 : Double(progress.completed) / Double(progress.total)
        return HStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.Offload.divider)
                    Capsule().fill(Color.Offload.indigo)
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 5)
            Text("\(progress.completed) of \(progress.total) done")
                .font(.caption).fontWeight(.medium)
                .foregroundStyle(Color.Offload.muted)
                .lineLimit(1).fixedSize()
        }
        .animation(Motion.smooth, value: progress.completed)
    }

    private var weekTitle: String {
        let end = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let df = DateFormatter(); df.dateFormat = "MMM d"
        return "\(df.string(from: weekStart)) – \(df.string(from: end))"
    }

    // MARK: Capture bar

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "figure.strengthtraining.traditional")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.Offload.indigo)
                TextField("Describe your goals, or just tap Plan…", text: $input, axis: .vertical)
                    .font(.Offload.body)
                    .focused($inputFocused)
                    .lineLimit(1...4)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await plan(.week(weekStart)) }
                } label: {
                    Label("Plan week", systemImage: "calendar")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(Color.Offload.indigo, in: .capsule)
                        .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)

                Button {
                    Task { await plan(.day(Calendar.current.startOfDay(for: Date()))) }
                } label: {
                    Label("Plan today", systemImage: "sun.max")
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(Color.Offload.indigo.opacity(0.12), in: .capsule)
                        .foregroundStyle(Color.Offload.indigo)
                }
                .buttonStyle(.pressable)

                Spacer(minLength: 0)
                if isPlanning { ProgressView().controlSize(.small) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    private func plan(_ scope: GymPlanScope) async {
        inputFocused = false
        isPlanning = true
        planError = nil
        chips = []
        defer { isPlanning = false }
        do {
            chips = try await store.plan(scope: scope, transcript: input)
            lastScope = scope
            input = ""
            Haptics.success()
        } catch {
            planError = error.localizedDescription
            Haptics.warning()
        }
    }

    private var chipRow: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            ForEach(chips) { chip in
                Button {
                    guard let lastScope else { return }
                    Task {
                        isPlanning = true
                        defer { isPlanning = false }
                        do {
                            chips = try await store.plan(scope: lastScope, transcript: "", extra: chip.instruction)
                            Haptics.success()
                        } catch {
                            planError = error.localizedDescription
                        }
                    }
                } label: {
                    Text(chip.label)
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Color.Offload.amber.opacity(0.14), in: .capsule)
                        .foregroundStyle(Color.Offload.amber)
                }
                .buttonStyle(.pressable)
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.Offload.amber)
            Text(message).font(.Offload.body).foregroundStyle(Color.Offload.text)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.Offload.amber.opacity(0.10), in: .rect(cornerRadius: 16, style: .continuous))
    }

    // MARK: Day cards

    private func dayCard(_ day: Date) -> some View {
        let sessions = store.sessions(on: day)
        let isToday = Calendar.current.isDateInToday(day)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Self.dayLabel(day).uppercased())
                    .font(.caption2).fontWeight(.bold).tracking(0.6)
                    .foregroundStyle(isToday ? Color.Offload.indigo : Color.Offload.muted)
                if isToday {
                    Text("TODAY").font(.caption2).fontWeight(.bold).tracking(0.6)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.Offload.indigo.opacity(0.14), in: .capsule)
                        .foregroundStyle(Color.Offload.indigo)
                }
                Spacer(minLength: 0)
                if sessions.isEmpty {
                    Button {
                        Task { await plan(.day(day)) }
                    } label: {
                        Label("Plan", systemImage: "plus.circle.fill")
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(Color.Offload.indigo)
                    }
                    .buttonStyle(.pressable)
                }
            }

            if sessions.isEmpty {
                Text("Rest — nothing planned")
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
            } else {
                VStack(spacing: 8) {
                    ForEach(sessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    /// Not a `Button` — see `SwipeToDeleteModifier.onTap`'s doc comment. A `Button`'s tap
    /// recognition is a separate gesture recognizer from the swipe's own drag, and the two race
    /// on the same touch; `.swipeToDelete(onTap:onDelete:)` now owns tap-vs-swipe from one place.
    private func sessionRow(_ session: WorkoutSession) -> some View {
        let accent = Self.accent(for: session.workoutType)
        let done = session.status == "completed"
        return HStack(spacing: 12) {
            Button {
                Task { await store.toggleComplete(session) }
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(done ? Color.Offload.green : accent)
            }
            .buttonStyle(.pressable(scale: 0.85))

            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                    .strikethrough(done, color: Color.Offload.muted)
                HStack(spacing: 6) {
                    Text(session.workoutType.capitalized)
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(accent.opacity(0.14), in: .capsule)
                        .foregroundStyle(accent)
                    if !session.muscleGroupList.isEmpty {
                        Text(session.muscleGroupList.prefix(3).joined(separator: " · "))
                            .font(.caption).foregroundStyle(Color.Offload.muted)
                    }
                    Spacer(minLength: 0)
                    Text("\(session.durationMinutes)m")
                        .font(.Offload.data).foregroundStyle(Color.Offload.muted)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.Offload.muted)
        }
        .padding(11)
        .background(accent.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .swipeToDelete(onTap: { editingSession = session }) { Task { await store.delete(session) } }
    }

    static func dayLabel(_ date: Date) -> String {
        let df = DateFormatter(); df.dateFormat = "EEE d"
        return df.string(from: date)
    }

    static func accent(for workoutType: String) -> Color {
        switch workoutType {
        case "strength":   return Color.Offload.indigo
        case "cardio":     return Color(hex: 0xE8547C)
        case "mobility", "stretching": return Color.Offload.teal
        case "hiit":       return Color(hex: 0xD79A2B)
        default:           return Color.Offload.muted
        }
    }
}

#Preview {
    GymView()
}
