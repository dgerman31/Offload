import SwiftUI

/// The Mon–Sun day selector from the design reference. Tapping a day retargets the whole
/// screen, which turns Home from "today only" into somewhere you can glance a few days ahead
/// without leaving for the Calendar tab.
///
/// Each day carries a density dot so you can see where the week gets heavy before you tap.
struct WeekStrip: View {
    @Binding var selected: Date
    var density: [Date: DayDensity]
    var now: Date = Date()
    var calendar: Calendar = .current

    /// A long horizontal runway — a week of history plus ~two months ahead — so the strip acts
    /// like a scrollable calendar you can page weeks into, not just a fixed fortnight. Far dates
    /// (a meeting three weeks out) are reachable by scrolling or by the Day tab's date picker,
    /// which scrolls this strip to match.
    private var days: [Date] {
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let start = calendar.date(byAdding: .day, value: -7, to: thisWeek) else { return [] }
        return (0..<70).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(days, id: \.timeIntervalSince1970) { day in
                        dayCell(day)
                            .id(day.timeIntervalSince1970)
                    }
                }
                .padding(.horizontal, 2)
            }
            .onAppear {
                // Open on the selected day rather than the start of the runway.
                proxy.scrollTo(calendar.startOfDay(for: selected).timeIntervalSince1970, anchor: .center)
            }
            // Keep the strip in sync when the day changes from elsewhere (the date picker jump,
            // the Today button) — scroll so the newly-selected day is visible.
            .onChange(of: selected) { _, day in
                withAnimation(Motion.standard) {
                    proxy.scrollTo(calendar.startOfDay(for: day).timeIntervalSince1970, anchor: .center)
                }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let dayDensity = density[calendar.startOfDay(for: day)] ?? DayDensity()

        return Button {
            withAnimation(Motion.standard) { selected = calendar.startOfDay(for: day) }
            Haptics.light()
        } label: {
            VStack(spacing: 6) {
                Text(Self.weekdayLabel(day, calendar: calendar).uppercased())
                    .font(.caption2).fontWeight(.semibold)
                    .tracking(0.5)
                    .foregroundStyle(isSelected ? .white.opacity(0.9) : Color.Offload.muted)

                Text("\(calendar.component(.day, from: day))")
                    .font(.system(.body, design: .rounded)).fontWeight(.bold)
                    .foregroundStyle(isSelected ? .white : Color.Offload.text)

                // Dot: filled when there's work, hollow ring for today, nothing otherwise.
                Group {
                    if !dayDensity.isEmpty {
                        Circle()
                            .fill(isSelected ? Color.white : Color.Offload.accent(for: nil))
                            .frame(width: 5, height: 5)
                    } else {
                        Color.clear.frame(width: 5, height: 5)
                    }
                }
            }
            .frame(width: 48)
            .padding(.vertical, 10)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(colors: [Color(hex: 0x5A76DC), Color(hex: 0x3B4CB8)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .elevated(.low)
                } else if isToday {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.Offload.indigo.opacity(0.45), lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.pressable(scale: 0.92))
        .accessibilityLabel(Self.accessibilityLabel(day, isToday: isToday, density: dayDensity, calendar: calendar))
    }

    static func weekdayLabel(_ day: Date, calendar: Calendar) -> String {
        let symbols = calendar.shortWeekdaySymbols
        let index = calendar.component(.weekday, from: day) - 1
        guard index >= 0, index < symbols.count else { return "" }
        return String(symbols[index].prefix(3))
    }

    static func accessibilityLabel(_ day: Date, isToday: Bool, density: DayDensity, calendar: Calendar) -> String {
        let df = DateFormatter(); df.dateStyle = .full
        var parts = [df.string(from: day)]
        if isToday { parts.append("today") }
        if density.isEmpty {
            parts.append("nothing scheduled")
        } else {
            if density.events > 0 { parts.append("\(density.events) event\(density.events == 1 ? "" : "s")") }
            if density.tasks > 0 { parts.append("\(density.tasks) task\(density.tasks == 1 ? "" : "s")") }
        }
        return parts.joined(separator: ", ")
    }
}

/// A vertical timeline: connector rail, a node per entry, and the entry's card beside it —
/// the structure from the design reference. Reading top-to-bottom shows the actual shape of a
/// day in a way a flat list never does.
struct TimelineRow<Content: View>: View {
    var accent: Color
    var isFirst: Bool
    var isLast: Bool
    var isPast: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Rail + node
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color.Offload.divider)
                    .frame(width: 2, height: 10)
                ZStack {
                    Circle()
                        .strokeBorder(accent.opacity(isPast ? 0.35 : 1), lineWidth: 2)
                        .background(Circle().fill(Color.Offload.background))
                        .frame(width: 13, height: 13)
                    if isPast {
                        Circle().fill(accent.opacity(0.35)).frame(width: 5, height: 5)
                    }
                }
                Rectangle()
                    .fill(isLast ? Color.clear : Color.Offload.divider)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: 13)

            content()
                .padding(.bottom, isLast ? 0 : 10)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
