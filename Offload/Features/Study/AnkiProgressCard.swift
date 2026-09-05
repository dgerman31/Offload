import SwiftUI

/// Today's Anki queue on Home: a bar that stays until it's empty, and one line about what's coming.
///
/// It disappears entirely when the queue is clear or nothing is configured — the point of the bar is
/// that its absence means "done", so a permanent "0 left" card would quietly undo it.
struct AnkiProgressCard: View {
    @State private var bridge = AnkiBridge.shared
    @State private var now = Date()

    private var snapshot: AnkiSnapshot? { bridge.current(now: now) }

    var body: some View {
        Group {
            if let snapshot, !snapshot.isClear {
                card(snapshot)
            }
        }
        .task {
            // A minute is plenty: the add-on pushes at most once a minute, and the numbers are
            // measured in cards rather than seconds.
            while !Task.isCancelled {
                now = Date()
                await bridge.refresh(now: now)
                await AnkiLiveActivity.sync(bridge.current(now: now),
                                            enabled: bridge.showsLiveActivity,
                                            canStart: true)
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func card(_ snapshot: AnkiSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(snapshot.deck, systemImage: "rectangle.on.rectangle.angled")
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(Color.Offload.teal)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(snapshot.dueRemaining)")
                    .font(.Offload.manrope(26, .bold))
                    .monospacedDigit()
                    .foregroundStyle(Color.Offload.text)
                    .contentTransition(.numericText(value: Double(snapshot.dueRemaining)))
                Text("left")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
            }

            bar(snapshot.progress)

            HStack(spacing: 6) {
                Text(subtitle(snapshot))
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.muted)
                Spacer(minLength: 0)
                if let freshness = snapshot.freshnessLabel(now: now) {
                    // Said out loud whenever it isn't essentially live. The add-on runs on a Mac
                    // that may well be asleep, and a stale number presented as a live one is worse
                    // than no number at all.
                    Text(freshness)
                        .font(.Offload.data)
                        .foregroundStyle(Color.Offload.muted.opacity(0.7))
                }
            }

            if let warning = AnkiForecast.warning(snapshot.forecast) {
                Divider().opacity(0.4)
                Label(warning, systemImage: "chart.line.uptrend.xyaxis")
                    .font(.Offload.data)
                    .foregroundStyle(Color.Offload.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .offloadCard()
        .animation(Motion.settle, value: snapshot.dueRemaining)
    }

    private func bar(_ progress: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Offload.muted.opacity(0.16))
                Capsule()
                    .fill(Color.Offload.teal)
                    .frame(width: max(6, proxy.size.width * progress))
            }
        }
        .frame(height: 9)
        .animation(Motion.settle, value: progress)
        .accessibilityElement()
        .accessibilityLabel("Today's cards")
        .accessibilityValue("\(Int(progress * 100)) percent done")
    }

    private func subtitle(_ snapshot: AnkiSnapshot) -> String {
        var parts = ["\(snapshot.today.reviewsDone) of \(snapshot.dueTotal) done"]
        let minutes = snapshot.minutesLeft()
        if minutes > 0 { parts.append("≈ \(AnkiLoad.durationLabel(minutes)) left") }
        if snapshot.today.newRemaining > 0 { parts.append("\(snapshot.today.newRemaining) new") }
        return parts.joined(separator: " · ")
    }
}
