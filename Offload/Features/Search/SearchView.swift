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
    @State private var selectedPerson: People.Commitment?
    @State private var appeared = false
    @State private var selecting = false
    @State private var selected: Set<String> = []

    /// The tasks currently on screen — what "Select" acts on.
    private var visibleTasks: [TaskItem] {
        if isSearching { return store.results }
        if let person = selectedPerson { return person.open }
        if smartList != nil { return listResults }
        return []
    }

    private var selectedTasks: [TaskItem] {
        visibleTasks.filter { selected.contains($0.id) }
    }

    private func toggleSelection(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func endSelecting() {
        withAnimation(Motion.standard) {
            selecting = false
            selected.removeAll()
        }
    }

    private let categories = HomeGrouping.categoryOrder
    private let priorities = ["high", "medium", "low"]

    /// The standing questions worth one tap.
    enum SmartList: String, CaseIterable, Identifiable {
        case overdue = "Overdue"
        case today = "Today"
        case week = "This week"
        case high = "High priority"
        case unscheduled = "Unscheduled"
        case waiting = "Waiting on"
        case done = "Completed"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .overdue:     return "exclamationmark.triangle.fill"
            case .today:       return "sun.max.fill"
            case .week:        return "calendar"
            case .high:        return "flame.fill"
            case .unscheduled: return "tray.fill"
            case .waiting:     return "hourglass"
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
            case .waiting:     return Color.Offload.amber
            case .done:        return Color.Offload.green
            }
        }

        /// Pure predicate so the filtering is directly testable.
        func matches(_ task: TaskItem, now: Date, calendar: Calendar = .current) -> Bool {
            if self == .done { return task.status == "completed" }
            if self == .waiting { return task.status == "waiting" }
            guard task.status != "completed" else { return false }
            // Blocked work belongs in "Waiting on", not mixed into your live lists.
            guard task.status != "waiting" else { return false }
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
            case .waiting, .done:
                return false   // handled above
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
                    } else if let person = selectedPerson {
                        personHeader(person)
                        results(person.open, emptyTitle: "Nothing outstanding",
                                emptyBody: "You're all square with \(person.name).")
                    } else {
                        smartListGrid
                        if !commitments.isEmpty { peopleSection }
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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if !visibleTasks.isEmpty {
                        Button(selecting ? "Done" : "Select") {
                            withAnimation(Motion.standard) {
                                selecting.toggle()
                                if !selecting { selected.removeAll() }
                            }
                        }
                        .font(.Offload.taskTitle)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting && !selectedTasks.isEmpty { bulkBar }
            }
            .task { await store.observe() }
            .task { withAnimation(Motion.settle) { appeared = true } }
            .sheet(item: $editing) { task in
                NavigationStack { TaskDetailView(task: task) }
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

    // MARK: Bulk actions

    /// Acting on one task at a time is fine; clearing a backlog isn't. This appears only once
    /// something is selected, so it never sits there as dead chrome.
    private var bulkBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedTasks.count)")
                .font(.system(.callout, design: .rounded)).fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(minWidth: 28, minHeight: 28)
                .background(Color.Offload.indigo, in: .circle)

            Button {
                Task {
                    await TaskActions.completeAll(selectedTasks)
                    endSelecting()
                }
            } label: {
                Label("Done", systemImage: "checkmark")
                    .font(.caption).fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.Offload.green.opacity(0.15), in: .capsule)
                    .foregroundStyle(Color.Offload.green)
            }
            .buttonStyle(.pressable)

            Menu {
                ForEach(TaskActions.Snooze.allCases) { preset in
                    Button {
                        Task {
                            await TaskActions.snoozeAll(selectedTasks, preset)
                            endSelecting()
                        }
                    } label: {
                        Label(preset.rawValue, systemImage: preset.icon)
                    }
                }
            } label: {
                Label("Snooze", systemImage: "clock.arrow.circlepath")
                    .font(.caption).fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.Offload.amber.opacity(0.15), in: .capsule)
                    .foregroundStyle(Color.Offload.amber)
            }

            Button(role: .destructive) {
                Task {
                    await TaskActions.deleteAll(selectedTasks)
                    endSelecting()
                }
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.caption).fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.Offload.red.opacity(0.13), in: .capsule)
                    .foregroundStyle(Color.Offload.red)
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: People

    private var commitments: [People.Commitment] {
        People.commitments(from: store.all, now: Date())
    }

    /// "What do I owe Sarah?" — the loops that nag hardest are usually obligations to people,
    /// and they're invisible in a flat list.
    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("People", systemImage: "person.2.fill")
                .font(.caption2).fontWeight(.bold)
                .tracking(0.9)
                .foregroundStyle(Color.Offload.indigo)

            VStack(spacing: 8) {
                ForEach(commitments) { commitment in
                    Button {
                        withAnimation(Motion.standard) { selectedPerson = commitment }
                        Haptics.light()
                    } label: {
                        HStack(spacing: 12) {
                            Text(initials(commitment.name))
                                .font(.system(.caption, design: .rounded)).fontWeight(.bold)
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(
                                    LinearGradient(colors: [Color(hex: 0x5A76DC), Color(hex: 0x8A6FE0)],
                                                   startPoint: .top, endPoint: .bottom),
                                    in: .circle
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commitment.name)
                                    .font(.Offload.taskTitle)
                                    .foregroundStyle(Color.Offload.text)
                                    .lineLimit(1)
                                Text(People.summary(for: commitment))
                                    .font(.Offload.data)
                                    .foregroundStyle(commitment.overdueCount > 0
                                                     ? Color.Offload.red : Color.Offload.muted)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.Offload.muted)
                        }
                    }
                    .buttonStyle(.pressable(scale: 0.99))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
    }

    private func personHeader(_ commitment: People.Commitment) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(Motion.standard) { selectedPerson = nil }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.Offload.indigo)
                    .frame(width: 30, height: 30)
                    .background(Color.Offload.indigo.opacity(0.10), in: .circle)
            }
            .buttonStyle(.pressable(scale: 0.88))
            .accessibilityLabel("Back to lists")

            VStack(alignment: .leading, spacing: 1) {
                Text(commitment.name)
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(Color.Offload.text)
                Text(People.summary(for: commitment))
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }
            Spacer()
        }
    }

    private func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
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
                    HStack(spacing: 10) {
                        if selecting {
                            Button {
                                withAnimation(Motion.quick) { toggleSelection(task.id) }
                                Haptics.light()
                            } label: {
                                Image(systemName: selected.contains(task.id)
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(selected.contains(task.id)
                                                     ? Color.Offload.indigo : Color.Offload.muted)
                            }
                            .buttonStyle(.pressable(scale: 0.85))
                            .padding(.leading, 12)
                        }
                        Group {
                            if selecting {
                                TaskRowView(task: task, onEdit: { toggleSelection(task.id) }) {
                                    Task { await store.toggleComplete(task) }
                                }
                            } else {
                                // `onEdit: nil` — moved to `.swipeToDelete`'s `onTap` instead of
                                // `TaskRowView`'s internal `.onTapGesture`, which would otherwise
                                // race the swipe's own drag gesture on the same touch.
                                TaskRowView(task: task, onEdit: nil) {
                                    Task { await store.toggleComplete(task) }
                                }
                                .swipeToDelete(onTap: {
                                    if let gymSessionId = task.gymSessionId {
                                        AppNavigation.shared.openGymSession(gymSessionId)
                                    } else {
                                        editing = task
                                    }
                                }) { Task { await TaskActions.delete(task) } }
                            }
                        }
                        .padding(.horizontal, selecting ? 0 : 12)
                        .padding(.trailing, selecting ? 12 : 0)
                        .taskContextMenu(task, onEdit: { editing = $0 })
                    }
                    .scrollAppearSubtle()
                }
            }
            .padding(.vertical, 6)
            .offloadCard()
            .safeAreaInset(edge: .bottom) { EmptyView() }
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
