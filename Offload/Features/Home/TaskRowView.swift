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
                        if let due = task.dueDate, !due.isEmpty {
                            metaLabel(Self.formatDue(due), icon: "calendar")
                        }
                        if let effort = task.effortMinutes {
                            metaLabel("\(effort)m", icon: "timer")
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

    /// Human-friendly due display ("Today 5:00 PM" / "Jul 20, 9:00 AM") instead of raw ISO.
    static func formatDue(_ iso: String) -> String {
        guard let date = DueDate.parse(iso) else { return iso }
        let df = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            df.dateFormat = "'Today' h:mm a"
        } else if Calendar.current.isDateInTomorrow(date) {
            df.dateFormat = "'Tomorrow' h:mm a"
        } else {
            df.dateFormat = "MMM d, h:mm a"
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
