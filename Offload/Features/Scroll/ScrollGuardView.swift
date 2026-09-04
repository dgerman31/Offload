import SwiftUI

/// The scroll timer's settings — and, more importantly, its off switch.
///
/// The off switch is deliberately easy to reach. The instinct with a tool like this is to make it
/// hard to escape, and there's a real literature behind that. But an interruption you can't stop is
/// one you solve by deleting the app, and then it helps you never again. Cheap to silence for an
/// hour, impossible to forget you silenced it — that trade keeps the thing installed, which is the
/// only way it ever helps.
struct ScrollGuardView: View {
    @State private var watch = ScrollWatch.shared
    @State private var enabled = ScrollGuard.isEnabled()
    @State private var snoozedUntil = ScrollGuard.snoozedUntil()
    @State private var now = Date()

    private var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > now
    }

    private var todayMinutes: Int {
        ScrollGuard.minutes(ScrollGuard.todaySeconds(now: now))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Scroll timer", isOn: $enabled)
                    .onChange(of: enabled) { _, on in
                        Task { await watch.setEnabled(on) }
                    }
            } footer: {
                Text("Counts up while you're in a feed and gets steadily harder to ignore. Nothing is blocked, and the first minute is always free.")
            }

            if enabled {
                quietSection
                todaySection
                ladderSection
                setupSection
            }
        }
        .navigationTitle("Scroll timer")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // A minute is plenty — everything on this screen is measured in them.
            while !Task.isCancelled {
                now = Date()
                snoozedUntil = ScrollGuard.snoozedUntil()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: Quiet

    @ViewBuilder
    private var quietSection: some View {
        Section {
            if isSnoozed, let snoozedUntil {
                HStack {
                    Label("Quiet until \(TimeFormat.time(snoozedUntil))", systemImage: "moon.zzz.fill")
                        .foregroundStyle(Color.Offload.muted)
                    Spacer(minLength: 0)
                }
                Button("Turn it back on now") {
                    watch.endSnooze()
                    snoozedUntil = nil
                    Haptics.light()
                }
                .fontWeight(.semibold)
            } else {
                ForEach(ScrollGuard.Snooze.allCases) { option in
                    Button {
                        Task { await watch.snooze(option) }
                        snoozedUntil = ScrollGuard.snoozedUntil()
                    } label: {
                        Label("Quiet for \(option.label.lowercased())", systemImage: "moon.zzz")
                    }
                }
            }
        } header: {
            Text("Quiet")
        } footer: {
            Text(isSnoozed
                 ? "No nudges until then. Any session running now has been ended."
                 : "There's the same button on every nudge and on the Lock Screen bar, so you never have to come here to stop it.")
        }
    }

    // MARK: Today

    @ViewBuilder
    private var todaySection: some View {
        Section("Today") {
            HStack {
                Text(todayMinutes == 0 ? "Nothing yet" : "\(todayMinutes) min")
                    .font(.Offload.manrope(26, .bold))
                    .monospacedDigit()
                    .foregroundStyle(todayMinutes >= 30 ? Color.Offload.amber : Color.Offload.text)
                    .contentTransition(.numericText(value: Double(todayMinutes)))
                Spacer(minLength: 0)
                if todayMinutes > 0 {
                    Text("≈ \(ScrollGuard.cards(inSeconds: ScrollGuard.todaySeconds(now: now))) cards")
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted)
                }
            }
            if watch.isRunning {
                Label("Counting now", systemImage: "hourglass")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.amber)
            }
        }
    }

    // MARK: What it does

    private var ladderSection: some View {
        Section {
            rung("1 min", "A timer appears on your Lock Screen. Silent.")
            rung("2 min", "First nudge, naming whatever you left open.")
            rung("4 min", "One a minute.")
            rung("6 min", "The same minutes, priced in cards.")
            rung("10 min", "Every 45 seconds, and the jokes stop.")
        } header: {
            Text("What happens")
        } footer: {
            Text("It ends the moment you close the feed, or after 30 minutes if the closing automation never fires.")
        }
    }

    private func rung(_ time: String, _ what: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(time)
                .font(.Offload.data)
                .monospacedDigit()
                .foregroundStyle(Color.Offload.amber)
                .frame(width: 56, alignment: .leading)
            Text(what)
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Setup

    private var setupSection: some View {
        Section {
            step(1, "Open **Shortcuts** → **Automation** → **＋**.")
            step(2, "Choose **App**, pick **Instagram**, and select **Is Opened**.")
            step(3, "Turn on **Run Immediately** so it doesn't ask you every time.")
            step(4, "Add the action **Start scroll timer** (search \"Offload\").")
            step(5, "Make a second automation the same way for **Is Closed**, with **Stop scroll timer**.")
        } header: {
            Text("Set it up once")
        } footer: {
            Text("No app on iOS is allowed to see which other app you're in — the only API that can is Screen Time, and it needs an entitlement a free Apple ID can't have. So the automation is the sensor, and you own it. Add as many apps as you like; TikTok and YouTube work exactly the same way.")
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.system(.caption, design: .rounded)).fontWeight(.bold)
                .frame(width: 22, height: 22)
                .background(Color.Offload.amber.opacity(0.18), in: .circle)
                .foregroundStyle(Color.Offload.amber)
            Text(.init(text))
                .font(.Offload.body)
                .foregroundStyle(Color.Offload.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
