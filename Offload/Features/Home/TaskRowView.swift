import SwiftUI

/// A single task row: completion toggle + title + category/priority + iconed context tags.
/// Color is never the sole signal — priority pairs an icon + label with its color (spec §5.8).
/// `indented` renders the row as a subtask beneath its parent.
struct TaskRowView: View {
    let task: TaskItem
    var indented: Bool = false
    var onEdit: (() -> Void)? = nil
    var onToggle: () -> Void

    private var isCompleted: Bool { task.status == "completed" }

    /// Decode the JSON `context_tags` array for display.
    private var contextTags: [String] {
        guard let json = task.contextTags,
              let data = json.data(using: .utf8),
              let tags = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return tags
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if indented {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(Color.Offload.muted)
                    .padding(.top, 4)
            }

            Button {
                Haptics.light()
                onToggle()
            } label: {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(indented ? .body : .title3)
                    .foregroundStyle(isCompleted ? Color.Offload.green : Color.Offload.muted.opacity(0.7))
                    .symbolEffect(.bounce, value: isCompleted)
                    .scaleEffect(isCompleted ? 1.06 : 1)
                    .animation(Motion.quick, value: isCompleted)
                    .contentShape(Circle())
            }
            .buttonStyle(.pressable(scale: 0.85))
            .accessibilityLabel(isCompleted ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(indented ? .Offload.body : .Offload.taskTitle)
                    .foregroundStyle(isCompleted ? Color.Offload.muted : Color.Offload.text)
                    .strikethrough(isCompleted, color: Color.Offload.muted)
                    .animation(Motion.standard, value: isCompleted)

                // The details the AI kept from the capture — one line here, all of it in edit.
                if !indented, let details = task.descriptionText, !details.isEmpty {
                    Text(details)
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                        .lineLimit(2)
                }

                if !indented {
                    // FlowLayout, not HStack: chips keep their natural width and wrap to the
                    // next line rather than being squeezed until words break mid-syllable.
                    FlowLayout(spacing: 8, lineSpacing: 6) {
                        if let category = task.category, !category.isEmpty {
                            chip(category, color: Color.Offload.indigo)
                        }
                        priorityBadge(task.priority)
                        statusBadge(task.status)
                        // "Scheduled · 3pm" for a fixed time, "Planned for Mon" for a soft day —
                        // and a quiet "Was planned Fri" once a soft day slips, never a red alarm.
                        if let timing = TaskTiming.describe(task) {
                            timingLabel(timing)
                        }
                        // A hard deadline is the one place urgency is real — a "must be done by",
                        // distinct from when you plan to do it. It earns its own emphasised chip.
                        if let deadline = task.deadline, !deadline.isEmpty {
                            Label("by \(Self.formatDue(deadline, allDay: true))", systemImage: "flag.fill")
                                .font(.Offload.data).lineLimit(1).fixedSize()
                                .foregroundStyle(Color.Offload.amber)
                        }
                        if let effort = task.effortMinutes {
                            metaLabel("\(effort)m", icon: "timer")
                        }
                        // Who this involves — obligations to people are the loops that nag
                        // hardest, so they earn a visible chip.
                        ForEach(People.decode(task.people), id: \.self) { person in
                            Label(person, systemImage: "person.fill")
                                .font(.caption2).fontWeight(.medium)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.Offload.indigo.opacity(0.13), in: .capsule)
                                .foregroundStyle(Color.Offload.indigo)
                        }
                        ForEach(contextTags, id: \.self) { tag in
                            Label(tag, systemImage: Self.tagIcon(tag))
                                .font(.caption2)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.Offload.teal.opacity(0.14), in: .capsule)
                                .foregroundStyle(Color.Offload.teal)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onEdit?() }   // tap the text area to edit (toggle is its own button)

            Spacer(minLength: 0)
        }
        .padding(.vertical, indented ? 2 : 6)
        .padding(.leading, indented ? 16 : 0)
    }

    // MARK: Elite touches

    /// Every context tag gets a matching SF Symbol.
    static func tagIcon(_ tag: String) -> String {
        switch tag {
        case "home":     return "house.fill"
        case "work":     return "briefcase.fill"
        case "car":      return "car.fill"
        case "outside":  return "leaf.fill"
        case "store":    return "cart.fill"
        case "gym":      return "dumbbell.fill"
        case "phone":    return "phone.fill"
        case "computer": return "desktopcomputer"
        case "meeting":  return "person.2.fill"
        case "errands":  return "bag.fill"
        default:         return "tag.fill"
        }
    }

    /// Human-friendly due display. A whole-day task says "Today" — never "Today 12:00 AM",
    /// which is both wrong and alarming.
    static func formatDue(_ iso: String, allDay: Bool = false) -> String {
        guard let date = DueDate.parse(iso) else { return iso }
        let df = DateFormatter()
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            df.dateFormat = allDay ? "'Today'" : "'Today' h:mm a"
        } else if calendar.isDateInTomorrow(date) {
            df.dateFormat = allDay ? "'Tomorrow'" : "'Tomorrow' h:mm a"
        } else {
            df.dateFormat = allDay ? "MMM d" : "MMM d, h:mm a"
        }
        return df.string(from: date)
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2).fontWeight(.semibold)
            .lineLimit(1)
            .fixedSize()                     // never break a word to fit
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.11), in: .capsule)
            .foregroundStyle(color)
    }

    /// Metadata pill (due date, effort) — single line, natural width.
    private func metaLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.Offload.data)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Color.Offload.muted)
    }

    /// The timing chip: a real commitment reads in teal, a soft plan in muted grey, and a
    /// slipped soft day in a calm amber — colour reinforcing "commitment vs whenever", never
    /// a red overdue scold.
    @ViewBuilder
    private func timingLabel(_ timing: TaskTiming.Label) -> some View {
        let (icon, color): (String, Color) = {
            switch timing.kind {
            case .scheduled: return ("clock.fill", Color.Offload.teal)
            case .planned:   return ("calendar", Color.Offload.muted)
            case .past:      return ("calendar", Color.Offload.amber)
            }
        }()
        Label(timing.text, systemImage: icon)
            .font(.Offload.data)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(color)
    }

    /// Started / blocked states — "in progress" and "waiting on someone" both look identical
    /// to untouched work without this.
    @ViewBuilder
    private func statusBadge(_ status: String) -> some View {
        switch status {
        case "in_progress":
            Label("Started", systemImage: "circle.lefthalf.filled")
                .font(.caption2).fontWeight(.semibold)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.Offload.teal.opacity(0.14), in: .capsule)
                .foregroundStyle(Color.Offload.teal)
        case "waiting":
            Label("Waiting", systemImage: "hourglass")
                .font(.caption2).fontWeight(.semibold)
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.Offload.amber.opacity(0.16), in: .capsule)
                .foregroundStyle(Color.Offload.amber)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func priorityBadge(_ priority: String) -> some View {
        switch priority {
        case "high":
            Label("High", systemImage: "exclamationmark.2")
                .font(.caption).lineLimit(1).fixedSize()
                .foregroundStyle(Color.Offload.red)
        case "low":
            Label("Low", systemImage: "arrow.down")
                .font(.caption).lineLimit(1).fixedSize()
                .foregroundStyle(Color.Offload.muted)
        default:
            EmptyView()   // medium is the unremarkable default
        }
    }
}
