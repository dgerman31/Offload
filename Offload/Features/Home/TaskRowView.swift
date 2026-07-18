import SwiftUI

/// A single task row: completion toggle + title + category/priority.
/// Color is never the sole signal — priority pairs an icon + label with its color (spec §5.8).
struct TaskRowView: View {
    let task: TaskItem
    var onToggle: () -> Void

    private var isCompleted: Bool { task.status == "completed" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isCompleted ? Color.Offload.green : Color.Offload.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCompleted ? "Mark not done" : "Mark done")

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.Offload.taskTitle)
                    .foregroundStyle(Color.Offload.text)
                    .strikethrough(isCompleted, color: Color.Offload.muted)

                HStack(spacing: 8) {
                    if let category = task.category, !category.isEmpty {
                        chip(category, color: Color.Offload.indigo)
                    }
                    priorityBadge(task.priority)
                    if let due = task.dueDate, !due.isEmpty {
                        Label(due, systemImage: "calendar")
                            .font(.Offload.data)
                            .foregroundStyle(Color.Offload.muted)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12), in: .capsule)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func priorityBadge(_ priority: String) -> some View {
        switch priority {
        case "high":
            Label("High", systemImage: "exclamationmark.2")
                .font(.caption).foregroundStyle(Color.Offload.red)
        case "low":
            Label("Low", systemImage: "arrow.down")
                .font(.caption).foregroundStyle(Color.Offload.muted)
        default:
            EmptyView()   // medium is the unremarkable default
        }
    }
}
