import SwiftUI

/// A paged, one-week-at-a-time day selector: a single Sunday-to-Saturday row you swipe left and
/// right to move week by week, like flipping pages on a wall calendar. Today is always known —
/// it's labelled "TODAY" and ringed on every page — so selecting another day never feels like
/// redefining which day today is; it's just where you're looking.
///
/// Each day carries a density dot so you can see where the week gets heavy before you tap.
struct WeekStrip: View {
    @Binding var selected: Date
    var density: [Date: DayDensity]
    var now: Date = Date()
    var calendar: Calendar = .current

    /// The Sunday of the week currently on screen. Paging changes this; it stays in sync with
    /// `selected` so a jump from elsewhere (the Today button, the date picker) flips to the right
    /// week.
    @State private var visibleWeek: Date = Date()

    /// The Sunday on or before a date, so weeks always run Sun–Sat regardless of locale.
    private func sunday(onOrBefore date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: start)   // 1 = Sunday
        return calendar.date(byAdding: .day, value: -(weekday - 1), to: start) ?? start
    }

    /// The pageable range of weeks, each identified by its Sunday: a couple months back through a
    /// year ahead, so a meeting booked well in advance is always reachable by swiping.
    private var weeks: [Date] {
        let base = sunday(onOrBefore: now)
        return (-8...52).compactMap { calendar.date(byAdding: .weekOfYear, value: $0, to: base) }
    }

    private func days(of weekStart: Date) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(Self.monthTitle(visibleWeek, calendar: calendar))
                .font(.caption).fontWeight(.semibold)
                .tracking(0.4)
                .foregroundStyle(Color.Offload.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(Motion.standard, value: visibleWeek)

            TabView(selection: $visibleWeek) {
                ForEach(weeks, id: \.timeIntervalSince1970) { week in
                    HStack(spacing: 6) {
                        ForEach(days(of: week), id: \.timeIntervalSince1970) { day in
                            dayCell(day)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .tag(week)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 82)
        }
        .onAppear { visibleWeek = sunday(onOrBefore: selected) }
        // A jump from elsewhere (Today button, date picker) flips to that day's week.
        .onChange(of: selected) { _, day in
            let target = sunday(onOrBefore: day)
            if !calendar.isDate(target, inSameDayAs: visibleWeek) {
                withAnimation(Motion.standard) { visibleWeek = target }
            }
        }
    }

    private func dayCell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selected)
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let dayDensity = density[calendar.startOfDay(for: day)] ?? DayDensity()
        let topColor: Color = isSelected ? .white.opacity(0.95) : (isToday ? Color.Offload.indigo : Color.Offload.muted)

        return Button {
            withAnimation(Motion.standard) { selected = calendar.startOfDay(for: day) }
            Haptics.light()
        } label: {
            VStack(spacing: 6) {
                // Today announces itself on every page; other days show their weekday.
                Text(isToday ? "TODAY" : Self.weekdayLabel(day, calendar: calendar).uppercased())
                    .font(.caption2).fontWeight(.bold)
                    .tracking(0.4)
                    .foregroundStyle(topColor)
                    .lineLimit(1).minimumScaleFactor(0.8)

                Text("\(calendar.component(.day, from: day))")
                    .font(.system(.body, design: .rounded)).fontWeight(.bold)
                    .foregroundStyle(isSelected ? .white : Color.Offload.text)

                // Dot: filled when there's work, nothing otherwise.
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
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background {
                // Selection is a filled pill; today keeps its ring even when selected, so it's
                // never invisible — you always know which day is actually today.
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                LinearGradient(colors: [Color(hex: 0x5A76DC), Color(hex: 0x3B4CB8)],
                                               startPoint: .top, endPoint: .bottom)
                            )
                            .elevated(.low)
                    }
                    if isToday {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isSelected ? Color.white.opacity(0.7) : Color.Offload.indigo.opacity(0.5),
                                          lineWidth: 1.5)
                    }
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

    /// "July 2026", or "Jun – Jul 2026" when the visible week straddles two months.
    static func monthTitle(_ weekStart: Date, calendar: Calendar) -> String {
        let end = calendar.date(byAdding: .day, value: 6, to: weekStart) ?? weekStart
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        let year = DateFormatter(); year.locale = Locale(identifier: "en_US_POSIX"); year.dateFormat = "yyyy"
        let startMonth = calendar.component(.month, from: weekStart)
        let endMonth = calendar.component(.month, from: end)
        if startMonth == endMonth {
            df.dateFormat = "MMMM yyyy"
            return df.string(from: weekStart)
        }
        df.dateFormat = "MMM"
        return "\(df.string(from: weekStart)) – \(df.string(from: end)) \(year.string(from: end))"
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
