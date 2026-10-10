//
//  WeeklyDailyBreakdownView.swift
//  Claude Usage
//
//  Seven columns (one per day of the weekly window). Each column is a frame whose
//  full height is that day's daily budget; the filled part is the budget still left.
//

import SwiftUI

/// One color per column of the weekly breakdown (oldest day first). The column and its marker on the
/// weekly bar share it. System colors adapt to light and dark mode; orange is left out because it
/// signals an exceeded budget. The weekday label under each column keeps the day readable without color.
enum WeeklyDayPalette {
    private static let colors: [Color] = [.blue, .teal, .green, .indigo, .purple, .pink, .brown]

    static func color(for columnIndex: Int) -> Color {
        colors[((columnIndex % colors.count) + colors.count) % colors.count]
    }

    /// Full weekday name for tooltips
    static func weekdayName(_ day: Date) -> String {
        weekdayNameFormatter.string(from: day)
    }

    private static let weekdayNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEE")
        return formatter
    }()
}

/// Budget end of one day, drawn on the weekly bar
struct WeeklyDayMarker: Equatable {
    let weekdayName: String
    let percentage: Double
    let isEstimated: Bool
    let isToday: Bool
    let color: Color

    /// Markers for the days of the current weekly window (nothing for past days).
    static func markers(
        snapshots: [DailyWeeklySnapshot],
        currentWeeklyPercentage: Double,
        now: Date,
        weeklyResetTime: Date,
        calendar: Calendar
    ) -> [WeeklyDayMarker] {
        let days = WeeklyDailyUsage.dayStarts(weeklyResetTime: weeklyResetTime, calendar: calendar)
        let todayStart = calendar.startOfDay(for: now)
        return WeeklyDailyUsage.columnMarkers(
            snapshots: snapshots,
            currentWeeklyPercentage: currentWeeklyPercentage,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        ).compactMap { marker in
            guard let marker, days.indices.contains(marker.columnIndex) else { return nil }
            return WeeklyDayMarker(
                weekdayName: WeeklyDayPalette.weekdayName(days[marker.columnIndex]),
                percentage: marker.percentage,
                isEstimated: marker.isEstimated,
                isToday: days[marker.columnIndex] == todayStart,
                color: WeeklyDayPalette.color(for: marker.columnIndex)
            )
        }
    }
}

struct WeeklyDailyBreakdownView: View {
    let profileId: UUID?
    let weeklyPercentage: Double
    let weeklyResetTime: Date

    private let calendar = Calendar.current
    private let barAreaHeight: CGFloat = 44
    /// Two lines of caption2, so hovering never shifts the layout
    private let detailMinHeight: CGFloat = 28

    /// Column under the pointer; its detail replaces the standard line
    @State private var hoveredIndex: Int?

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEEEE")
        return formatter
    }()

    var body: some View {
        // Only shown when a valid weekly reset time is known and the window is still open
        let now = Date()
        if let profileId, weeklyPercentage.isFinite, weeklyResetTime > now {
            breakdown(profileId: profileId, now: now)
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private func breakdown(profileId: UUID, now: Date) -> some View {
        let snapshots = WeeklyDailySnapshotStore.shared.snapshots(for: profileId)
        let days = WeeklyDailyUsage.dayStarts(weeklyResetTime: weeklyResetTime, calendar: calendar)
        let columns = WeeklyDailyUsage.columnValues(
            snapshots: snapshots,
            currentWeeklyPercentage: weeklyPercentage,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )
        let todayIndex = days.firstIndex { calendar.isDate($0, inSameDayAs: now) }
        let todayLimit = WeeklyDailyUsage.columnMarkers(
            snapshots: snapshots,
            currentWeeklyPercentage: weeklyPercentage,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )[safe: todayIndex]

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days.indices, id: \.self) { index in
                    let isToday = index == todayIndex
                    let usage = columns[index].usage
                    let dayBudget = columns[index].budget
                    let detail = WeeklyDailyUsage.columnDetail(columns[index], day: days[index], now: now, calendar: calendar)
                    let text = detailText(detail, day: days[index], todayLimit: todayLimit ?? nil)
                    dayColumn(
                        day: days[index],
                        remainingFraction: WeeklyDailyUsage.dayRemainingFraction(usage: usage, budget: dayBudget),
                        isOverBudget: isOverBudget(usage: usage, budget: dayBudget),
                        isToday: isToday,
                        isExpired: isPast(detail),
                        isEstimatedFuture: columns[index].isEstimated && (todayIndex.map { index > $0 } ?? false),
                        color: WeeklyDayPalette.color(for: index)
                    )
                    // Whole column incl. weekday label is the hover area
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            hoveredIndex = index
                        } else if hoveredIndex == index {
                            hoveredIndex = nil
                        }
                    }
                    .help(text.full)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(text.full)
                }
            }
            .frame(height: barAreaHeight + 16)

            detailRow(
                hoveredIndex: hoveredIndex,
                todayIndex: todayIndex,
                days: days,
                columns: columns,
                now: now,
                todayLimit: todayLimit ?? nil
            )
        }
        .padding(.vertical, 4)
    }

    /// Line under the columns: the hovered column's detail, otherwise today's line.
    /// Fixed minimum height so showing or changing it never moves the layout.
    @ViewBuilder
    private func detailRow(
        hoveredIndex: Int?,
        todayIndex: Int?,
        days: [Date],
        columns: [WeeklyDailyUsage.ColumnValue],
        now: Date,
        todayLimit: WeeklyDailyUsage.ColumnMarker?
    ) -> some View {
        let shownIndex = hoveredIndex ?? todayIndex
        VStack(alignment: .leading, spacing: 0) {
            if let shownIndex, days.indices.contains(shownIndex), columns.indices.contains(shownIndex) {
                let detail = WeeklyDailyUsage.columnDetail(columns[shownIndex], day: days[shownIndex], now: now, calendar: calendar)
                let text = detailText(detail, day: days[shownIndex], todayLimit: todayLimit)
                // Standard line (nothing hovered) stays quiet; a hovered column gets its weekday in bold
                let showPrefix = hoveredIndex != nil
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if hoveredIndex != nil {
                        Circle()
                            .fill(WeeklyDayPalette.color(for: shownIndex))
                            .frame(width: 6, height: 6)
                    }
                    (showPrefix && !text.prefix.isEmpty
                        ? Text(text.prefix).fontWeight(.bold).foregroundColor(.primary) + Text(" " + text.body)
                        : Text(text.body))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: detailMinHeight, alignment: .topLeading)
    }

    private func isPast(_ detail: WeeklyDailyUsage.ColumnDetail) -> Bool {
        if case .past = detail { return true }
        return false
    }

    /// Weekday prefix and explanation of one column; `full` joins both for tooltip and VoiceOver.
    /// Today keeps its existing line (which names the day itself), so it has no prefix.
    private func detailText(_ detail: WeeklyDailyUsage.ColumnDetail, day: Date, todayLimit: WeeklyDailyUsage.ColumnMarker?) -> (prefix: String, body: String, full: String) {
        let weekday = Self.weekdayFormatter.string(from: day)
        let prefix = "popover.daily_budget.detail_prefix".localized(with: weekday)
        let result: (String, String)
        switch detail {
        case .past(let usage, let budget):
            result = (prefix, "popover.daily_budget.detail_past".localized(with: formatPoints(usage), formatPoints(budget)))
        case .noData:
            result = (prefix, "popover.daily_budget.detail_none".localized)
        case .today(let remaining, let budget, let isEstimated):
            result = ("", todayText(remaining: remaining, budget: budget, limit: todayLimit, isEstimated: isEstimated))
        case .future(let budget, let isEstimated):
            let key = isEstimated ? "popover.daily_budget.detail_future_estimated" : "popover.daily_budget.detail_future"
            result = (prefix, key.localized(with: formatPoints(budget)))
        }
        let full = result.0.isEmpty ? result.1 : result.0 + " " + result.1
        return (result.0, result.1, full)
    }

    /// True once a day's usage has reached the budget that applied to it.
    private func isOverBudget(usage: Double?, budget: Double?) -> Bool {
        guard let usage, let budget else { return false }
        return WeeklyDailyUsage.isDailyBudgetExceeded(todayUsage: usage, budget: budget)
    }

    /// "today: x left of y · limit at z"; without a limit (budget 0) only the first part
    private func todayText(remaining: Double, budget: Double, limit: WeeklyDailyUsage.ColumnMarker?, isEstimated: Bool) -> String {
        if let limit {
            let key = isEstimated ? "popover.daily_budget.today_limit_estimated" : "popover.daily_budget.today_limit"
            return key.localized(
                with: formatPoints(remaining),
                formatPoints(budget),
                limit.percentage.formatted(.number.precision(.fractionLength(0)))
            )
        }
        let key = isEstimated ? "popover.daily_budget.today_estimated" : "popover.daily_budget.today"
        return key.localized(with: formatPoints(remaining), formatPoints(budget))
    }

    private func formatPoints(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func dayColumn(day: Date, remainingFraction: Double?, isOverBudget: Bool, isToday: Bool, isExpired: Bool, isEstimatedFuture: Bool, color: Color) -> some View {
        VStack(spacing: 2) {
            budgetBar(remainingFraction: remainingFraction, isOverBudget: isOverBudget, isExpired: isExpired, color: color)
                .opacity(isEstimatedFuture ? 0.6 : 1)
                .frame(maxWidth: .infinity, maxHeight: barAreaHeight)

            Text(Self.weekdayFormatter.string(from: day))
                .font(.caption2)
                .fontWeight(isToday ? .bold : .regular)
                .foregroundColor(isToday ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(height: 14)
        }
        .frame(maxWidth: .infinity)
        // Today is marked by an outline only, not by a background that could read as a bar
        .overlay {
            if isToday {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: 1)
            }
        }
    }

    /// Frame = daily budget (full height). Fill = budget still left, emptying from the top as usage grows.
    /// Dashed frame without fill when the day has no data or no budget is known.
    /// A budget of 0 gives a solid, empty frame (already used up).
    /// A past day's unused rest has expired (it was spread over the following days): the frame keeps the
    /// day color, the fill is gray and hatched.
    private func budgetBar(remainingFraction: Double?, isOverBudget: Bool, isExpired: Bool, color: Color) -> some View {
        let frameColor = isOverBudget ? Color.orange : color
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2)
                .stroke(
                    remainingFraction == nil ? frameColor.opacity(0.5) : frameColor,
                    style: StrokeStyle(lineWidth: 1, dash: remainingFraction == nil ? [2, 2] : [])
                )

            if let remainingFraction, remainingFraction > 0 {
                let fillHeight = max(1, barAreaHeight * CGFloat(remainingFraction))
                if isExpired {
                    HatchedFill()
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .frame(height: fillHeight)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isOverBudget ? Color.orange : color.opacity(0.85))
                        .frame(height: fillHeight)
                }
            }
        }
    }
}

/// Gray diagonal stripes on a faint gray ground; the gray with partial opacity reads in light and dark mode.
private struct HatchedFill: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.gray.opacity(0.18)))
            var stripes = Path()
            let spacing: CGFloat = 4
            var x = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(stripes, with: .color(.gray.opacity(0.75)), lineWidth: 1)
        }
    }
}

private extension Array {
    /// Element at an optional index, `nil` if the index is nil or out of range
    subscript(safe index: Int?) -> Element? {
        guard let index, indices.contains(index) else { return nil }
        return self[index]
    }
}
