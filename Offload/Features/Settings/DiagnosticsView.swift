import SwiftUI

/// What the app has actually been doing, read back from its own unified log.
///
/// This exists because of a specific, recurring problem: there is no Mac in this project's loop,
/// so there is no console, no debugger, and no way to answer "why did that capture fall back to
/// the on-device model?" from the outside. `Log.recentEntries` has been able to read the app's own
/// entries since logging went in — an app may read its own log with no entitlement — but nothing
/// ever surfaced it, so the evidence existed and was unreachable. This is the screen that reaches it.
///
/// Scoped to the current launch by construction (`OSLogStore(scope: .currentProcessIdentifier)`),
/// which the footer says plainly rather than leaving someone to wonder where yesterday went.
struct DiagnosticsView: View {
    @State private var entries: [LogEntry] = []
    @State private var selected: Set<String> = Set(Log.allCategories)
    @State private var window: Window = .hour
    @State private var loadError: String?
    @State private var loading = false

    /// How far back to read. Kept short by default because the store read costs more the further
    /// back it reaches, and the entry you want after something just went wrong is a recent one.
    enum Window: String, CaseIterable, Identifiable {
        case fifteen = "15 min"
        case hour = "1 hour"
        case launch = "This launch"

        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .fifteen: return 900
            case .hour:    return 3600
            case .launch:  return 86_400
            }
        }
    }

    private var visible: [LogEntry] {
        entries.filter { selected.contains($0.category) }.reversed()
    }

    var body: some View {
        List {
            Section {
                Picker("Window", selection: $window) {
                    ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                categoryChips
            }

            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.amber)
                }
            }

            Section {
                if loading && entries.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if visible.isEmpty {
                    Text(entries.isEmpty
                         ? "Nothing logged yet this launch. Make a capture or plan a day, then pull to refresh."
                         : "Nothing in the categories you've got selected.")
                        .font(.Offload.body)
                        .foregroundStyle(Color.Offload.muted)
                } else {
                    ForEach(visible) { entry in
                        row(entry)
                    }
                }
            } header: {
                HStack {
                    Text("\(visible.count) entries")
                    Spacer()
                    if !visible.isEmpty {
                        ShareLink(item: Log.exportText(visible.reversed())) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .font(.caption)
                        }
                    }
                }
            } footer: {
                Text("This launch only — the log is scoped to the running process, so quitting the app clears it. Captured text is never logged; entries carry counts, durations, and error kinds.")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { load() }
        .task { load() }
        .onChange(of: window) { _, _ in load() }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(Log.allCategories, id: \.self) { category in
                    let on = selected.contains(category)
                    Button {
                        if on { selected.remove(category) } else { selected.insert(category) }
                        Haptics.light()
                    } label: {
                        Text(category)
                            .font(.caption).fontWeight(.semibold)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(on ? Color.Offload.indigo : Color.Offload.surface, in: .capsule)
                            .foregroundStyle(on ? .white : Color.Offload.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? [.isSelected] : [])
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(TimeFormat.time(entry.date))
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                Text(entry.category)
                    .font(.system(.caption2, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.Offload.surface, in: .capsule)
                    .foregroundStyle(Color.Offload.muted)
                if Self.isProblem(entry.level) {
                    Text(entry.level.uppercased())
                        .font(.system(.caption2, weight: .heavy))
                        .foregroundStyle(Color.Offload.red)
                }
            }
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Self.isProblem(entry.level) ? Color.Offload.red : Color.Offload.text)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private static func isProblem(_ level: String) -> Bool {
        level == "error" || level == "fault"
    }

    /// Reads on the main actor deliberately: this is a few hundred entries from the current
    /// process, and hopping actors to fetch them would buy nothing but a race with `refreshable`.
    private func load() {
        loading = true
        defer { loading = false }
        do {
            entries = try Log.recentEntries(since: window.seconds)
            loadError = nil
        } catch {
            // The one place in the app where an error's own description is the useful thing —
            // it's an OSLogStore failure, and it carries no user content.
            entries = []
            loadError = "Couldn't read the log: \(error.localizedDescription)"
        }
    }
}
