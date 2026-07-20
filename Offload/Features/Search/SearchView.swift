import SwiftUI

/// Search — full-text and semantic, over everything you've ever captured (spec §5.4).
///
/// Search is also where you go when you *don't* have a specific word in mind, so it opens on
/// smart lists — Overdue, Today, This week, High priority, Unscheduled — which answer the
/// questions people actually arrive with. Typing takes over from there.
struct SearchView: View {
    @State private var store = SearchStore()
    @State private var editing: TaskItem?
    @State private var smartList: SmartList?
    @State private var appeared = false

    private let categories = HomeGrouping.categoryOrder
    private let priorities = ["high", "medium", "low"]

    /// The standing questions worth one tap.
    enum SmartList: String, CaseIterable, Identifiable {
        case overdue = "Overdue"
        case today = "Today"
        case week = "This week"
        case high = "High priority"
        case unscheduled = "Unscheduled"
        case done = "Completed"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overdue:     return "exclamationmark.triangle.fill"
            case .today:       return "sun.max.fill"
            case .week:        return "calendar"
            case .high:        return "flame.fill"
            case .unscheduled: return "tray.fill"
            case .done:        return "checkmark.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .overdue:     return Color.Offload.red
            case .today:       return Color.Offload.amber
            case .week:        return Color.Offload.teal
            case .high:        return Color.Offload.accent(for: "Personal")
            case .unscheduled: return Color.Offload.muted
            case .done:        return Color.Offload.green
            }
        }

        /// Pure predicate so the filtering is directly testable.
        func matches(_ task: TaskItem, now: Date, calendar: Calendar = .current) -> Bool {
            if self == .done { return task.status == "completed" }
            guard task.status != "completed" else { return false }
            let due = DueDate.parse(task.dueDate)
            switch self {
            case .overdue:
                guard let due else { return false }
                return due < calendar.startOfDay(for: now)
            case .today:
                guard let due else { return false }
                return calendar.isDate(due, inSameDayAs: now)
            case .week:
                guard let due else { return false }
                return due >= calendar.startOfDay(for: now)
                    && due < (calendar.date(byAdding: .day, value: 7, to: calendar.startOfDay(for: now)) ?? now)
            case .high:
                return task.priority == "high"
            case .unscheduled:
                return due == nil
            case .done:
                return false
            }
        }
    }

    private var isSearching: Bool {
        !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || store.category != nil || store.priority != nil
    }

    private var listResults: [TaskItem] {
        guard let smartList else { return [] }
        let now = Date()
        return HomeGrouping.inDisplayOrder(store.all.filter { !$0.deleted && smartList.matches($0, now: now) })
    }

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isSearching {
                        filterBar
                        results(store.results, emptyTitle: "No matches",
                                emptyBody: "Try a different word or clear your filters.")
                    } else if let smartList {
                        selectedListHeader(smartList)
                        results(listResults, emptyTitle: "Nothing here",
                                emptyBody: "This list is empty — which is usually good news.")
                    } else {
                        smartListGrid
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(Color.Offload.background)
            .navigationTitle("Search")
            .searchable(text: $store.query, prompt: "Tasks, projects, ideas…")
            .task { await store.observe() }
            .task { withAnimation(Motion.settle) { appeared = true } }
            .sheet(item: $editing) { task in
                NavigationStack { TaskEditView(task: task) }
            }
        }
    }

    // MARK: Smart lists

    private var smartListGrid: some View {
        let now = Date()
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                         spacing: 12) {
            ForEach(Array(SmartList.allCases.enumerated()), id: \.element.id) { index, list in
                let count = store.all.filter { !$0.deleted && list.matches($0, now: now) }.count
                Button {
                    withAnimation(Motion.standard) { smartList = list }
                    Haptics.light()
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: list.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(list.tint)
                            .frame(width: 34, height: 34)
                            .background(list.tint.opacity(0.13), in: .rect(cornerRadius: 10, style: .continuous))
                        Text("\(count)")
                            .font(.system(.title2, design: .rounded).weight(.bold))
                            .foregroundStyle(Color.Offload.text)
                            .contentTransition(.numericText(value: Double(count)))
                        Text(list.rawValue)
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .offloadCard(cornerRadius: 16)
                }
                .buttonStyle(.pressable(scale: 0.97))
                .appearIn(index, when: appeared)
            }
        }
    }

    private func selectedListHeader(_ list: SmartList) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(Motion.standard) { smartList = nil }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.Offload.indigo)
                    .frame(width: 30, height: 30)
                    .background(Color.Offload.indigo.opacity(0.10), in: .circle)
            }
            .buttonStyle(.pressable(scale: 0.88))
            .accessibilityLabel("Back to lists")

            Label(list.rawValue, systemImage: list.icon)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(list.tint)
            Spacer()
        }
    }

    // MARK: Results

    @ViewBuilder
    private func results(_ tasks: [TaskItem], emptyTitle: String, emptyBody: String) -> some View {
        if tasks.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(store.all.isEmpty ? "Nothing to search yet" : emptyTitle)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                Text(store.all.isEmpty
                     ? "Capture a few thoughts and they'll be searchable here."
                     : emptyBody)
                    .font(.Offload.body)
                    .foregroundStyle(Color.Offload.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .offloadCard()
        } else {
            VStack(spacing: 2) {
                ForEach(tasks) { task in
                    TaskRowView(task: task, onEdit: { editing = task }) {
                        Task { await store.toggleComplete(task) }
                    }
                    .padding(.horizontal, 12)
                    .scrollAppearSubtle()
                }
            }
            .padding(.vertical, 6)
            .offloadCard()
        }
    }

    // MARK: Filters

    private var filterBar: some View {
        @Bindable var store = store
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("Any category") { store.category = nil }
                    ForEach(categories, id: \.self) { c in
                        Button(c) { store.category = c }
                    }
                } label: {
                    filterChip(store.category ?? "Category", active: store.category != nil)
                }
                Menu {
                    Button("Any priority") { store.priority = nil }
                    ForEach(priorities, id: \.self) { p in
                        Button(p.capitalized) { store.priority = p }
                    }
                } label: {
                    filterChip(store.priority?.capitalized ?? "Priority", active: store.priority != nil)
                }
                if store.category != nil || store.priority != nil {
                    Button("Clear") { store.category = nil; store.priority = nil }
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(Color.Offload.indigo)
                        .buttonStyle(.pressable)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func filterChip(_ text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.caption).fontWeight(.semibold)
        .lineLimit(1).fixedSize()
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background((active ? Color.Offload.indigo : Color.Offload.muted).opacity(0.12), in: .capsule)
        .foregroundStyle(active ? Color.Offload.indigo : Color.Offload.text)
    }
}

#Preview { SearchView() }
