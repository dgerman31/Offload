import SwiftUI

/// The long-press menu for a task, shared by every screen that shows one.
///
/// Home, Search, Calendar and the detail view each used to offer a different subset of
/// actions, so what you could do to a task depended on where you found it. This is the single
/// definition — add an action here and it appears everywhere at once.
struct TaskContextMenu: View {
    let task: TaskItem
    var onFocus: ((TaskItem) -> Void)?
    var onEdit: ((TaskItem) -> Void)?

    var body: some View {
        Group {
            if let onFocus, task.status != "completed" {
                Button { onFocus(task) } label: {
                    Label("Focus \(task.effortMinutes ?? 25) min", systemImage: "timer")
                }
            }

            Button {
                Task { await TaskActions.advanceStatus(task) }; Haptics.light()
            } label: {
                Label(statusActionLabel, systemImage: statusActionIcon)
            }

            // Change priority right here — the most common tweak shouldn't need the edit sheet.
            Menu {
                ForEach(["high", "medium", "low"], id: \.self) { level in
                    Button {
                        Task { await TaskActions.setPriority(task, level) }; Haptics.light()
                    } label: {
                        Label(level.capitalized,
                              systemImage: task.priority == level ? "checkmark" : priorityIcon(level))
                    }
                }
            } label: {
                Label("Priority", systemImage: "flag.fill")
            }

            Menu {
                ForEach(TaskActions.Snooze.allCases) { preset in
                    Button {
                        Task { await TaskActions.snooze(task, preset) }; Haptics.light()
                    } label: {
                        Label(preset.rawValue, systemImage: preset.icon)
                    }
                }
            } label: {
                Label("Snooze", systemImage: "clock.arrow.circlepath")
            }

            if task.status == "waiting" {
                Button { Task { await TaskActions.clearWaiting(task) }; Haptics.light() } label: {
                    Label("No longer waiting", systemImage: "play.circle")
                }
            } else if task.status != "completed" {
                Button { Task { await TaskActions.setWaiting(task, on: nil) }; Haptics.light() } label: {
                    Label("Waiting on someone", systemImage: "hourglass")
                }
            }

            Button { Task { await TaskActions.duplicate(task) }; Haptics.light() } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }

            if let onEdit {
                Button { onEdit(task) } label: {
                    Label("Edit", systemImage: "pencil")
                }
            }

            Divider()

            // A routine session ("class is cancelled Friday") skips just this week's instance,
            // recording an exception so it isn't recreated — next week is untouched.
            if RoutineService.isRoutineTask(task) {
                Button(role: .destructive) {
                    Task { await RoutineService.shared.skipThisOccurrence(task) }
                } label: {
                    Label("Skip just this one", systemImage: "calendar.badge.minus")
                }
            } else {
                Button(role: .destructive) {
                    Task { await TaskActions.delete(task) }; Haptics.light()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var statusActionLabel: String {
        switch task.status {
        case "open":        return "Start it"
        case "in_progress": return "Mark done"
        case "completed":   return "Reopen"
        default:            return "Mark done"
        }
    }

    private var statusActionIcon: String {
        switch task.status {
        case "open":        return "play.circle"
        case "completed":   return "arrow.uturn.backward"
        default:            return "checkmark.circle"
        }
    }

    private func priorityIcon(_ level: String) -> String {
        switch level {
        case "high": return "exclamationmark.2"
        case "low":  return "arrow.down"
        default:     return "minus"
        }
    }
}

extension View {
    /// Attach the app's standard task actions as a long-press menu.
    func taskContextMenu(
        _ task: TaskItem,
        onFocus: ((TaskItem) -> Void)? = nil,
        onEdit: ((TaskItem) -> Void)? = nil
    ) -> some View {
        contextMenu { TaskContextMenu(task: task, onFocus: onFocus, onEdit: onEdit) }
    }
}
