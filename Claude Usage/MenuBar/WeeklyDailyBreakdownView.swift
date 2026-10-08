//
//  WeeklyDailyBreakdownView.swift
//  Claude Usage
//
//  Seven columns (one per day of the weekly window) showing how much of the
//  weekly usage was consumed per day, with the daily budget as a reference line.
//

import SwiftUI

struct WeeklyDailyBreakdownView: View {
    let profileId: UUID?
    let weeklyPercentage: Double
    let weeklyResetTime: Date

    private let calendar = Calendar.current
    private let barAreaHeight: CGFloat = 44

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
        let usages = WeeklyDailyUsage.dailyUsage(snapshots: snapshots, weeklyResetTime: weeklyResetTime, calendar: calendar)
        let storedBudgets = WeeklyDailyUsage.storedBudgets(snapshots: snapshots, weeklyResetTime: weeklyResetTime, calendar: calendar)
        let budget = WeeklyDailyUsage.dailyBudget(currentWeeklyPercentage: weeklyPercentage, now: now, weeklyResetTime: weeklyResetTime, calendar: calendar)
        let todayIndex = days.firstIndex { calendar.isDate($0, inSameDayAs: now) }
        let todayUsage = WeeklyDailyUsage.todayUsage(
            snapshots: snapshots,
            currentWeeklyPercentage: weeklyPercentage,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )
        // Past days are drawn in weekly percentage points; today is drawn relative to its budget
        let pastIndices = days.indices.filter { index in index != todayIndex }
        let scaleMax = max(
            pastIndices.compactMap { usages[$0] }.max() ?? 0,
            pastIndices.compactMap { storedBudgets[$0] }.max() ?? 0,
            1
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days.indices, id: \.self) { index in
                    let isToday = index == todayIndex
                    dayColumn(
                        day: days[index],
                        bar: isToday ? todayBar(usage: todayUsage, budget: budget) : pastBar(usage: usages[index], budget: storedBudgets[index], scaleMax: scaleMax),
                        referenceLine: isToday ? nil : storedBudgets[index].map { $0 / scaleMax },
                        isToday: isToday
                    )
                }
            }
            .frame(height: barAreaHeight + 16)

            if let todayUsage {
                let remaining = WeeklyDailyUsage.todayRemaining(usage: todayUsage, budget: budget)
                Text("popover.daily_budget.today".localized(with: formatPoints(remaining), formatPoints(budget)))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.vertical, 4)
    }

    /// Today's bar: 0 to 100 % of the daily budget. Orange once the budget is reached.
    private func todayBar(usage: Double?, budget: Double) -> DayBar? {
        guard let usage else { return nil }
        return DayBar(
            fraction: WeeklyDailyUsage.todayBarFraction(usage: usage, budget: budget),
            isOverBudget: WeeklyDailyUsage.isDailyBudgetExceeded(todayUsage: usage, budget: budget)
        )
    }

    /// Past day's bar: weekly percentage points on the shared scale. Orange if the
    /// day's usage reached the budget that applied to it.
    private func pastBar(usage: Double?, budget: Double?, scaleMax: Double) -> DayBar? {
        guard let usage else { return nil }
        return DayBar(fraction: usage / scaleMax, isOverBudget: budget.map { usage >= $0 } ?? false)
    }

    private func formatPoints(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func dayColumn(day: Date, bar: DayBar?, referenceLine: Double?, isToday: Bool) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                Color.clear
                if let bar {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bar.isOverBudget ? Color.orange : Color.accentColor.opacity(isToday ? 1 : 0.6))
                        .frame(height: max(2, barAreaHeight * CGFloat(min(1, bar.fraction))))
                } else {
                    // Missing day: thin placeholder, distinct from a real 0
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                }
            }
            .overlay {
                // Daily budget that applied to a past day
                if let referenceLine {
                    referenceLineView(fraction: referenceLine)
                }
            }
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
        .background(
            isToday ? Color.accentColor.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
    }

    private func referenceLineView(fraction: Double) -> some View {
        GeometryReader { geometry in
            let y = geometry.size.height * CGFloat(1 - min(1, max(0, fraction)))
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: geometry.size.width, y: y))
            }
            .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }

    /// Height of a column's bar as a fraction of the bar area, plus its warning state.
    private struct DayBar {
        let fraction: Double
        let isOverBudget: Bool
    }
}
