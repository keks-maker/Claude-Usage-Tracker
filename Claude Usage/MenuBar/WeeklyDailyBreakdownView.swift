//
//  WeeklyDailyBreakdownView.swift
//  Claude Usage
//
//  Seven columns (one per day of the weekly window). Each column is a frame whose
//  full height is that day's daily budget; the filled part is the budget still left.
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
        let todayIndex = days.firstIndex { calendar.isDate($0, inSameDayAs: now) }
        let todayUsage = WeeklyDailyUsage.todayUsage(
            snapshots: snapshots,
            currentWeeklyPercentage: weeklyPercentage,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )
        let baselineReliable = WeeklyDailyUsage.isTodayBaselineReliable(
            snapshots: snapshots,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )
        let restBudget = WeeklyDailyUsage.restDailyBudget(
            currentWeeklyPercentage: weeklyPercentage,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )
        let budget = WeeklyDailyUsage.todayBudget(
            snapshots: snapshots,
            currentWeeklyPercentage: weeklyPercentage,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days.indices, id: \.self) { index in
                    let isToday = index == todayIndex
                    let isFuture = todayIndex.map { index > $0 } ?? false
                    // Today without a reliable day-start value is unknown, not "nothing used"
                    let usage: Double? = isToday ? (baselineReliable ? todayUsage : nil) : (isFuture ? 0 : usages[index])
                    let dayBudget: Double? = isToday ? (baselineReliable ? budget : nil) : (isFuture ? restBudget : storedBudgets[index])
                    dayColumn(
                        day: days[index],
                        remainingFraction: WeeklyDailyUsage.dayRemainingFraction(usage: usage, budget: dayBudget),
                        isOverBudget: isOverBudget(usage: usage, budget: dayBudget),
                        isToday: isToday
                    )
                }
            }
            .frame(height: barAreaHeight + 16)

            if todayUsage != nil, !baselineReliable {
                Text("popover.daily_budget.no_data".localized)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else if let todayUsage {
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

    /// True once a day's usage has reached the budget that applied to it.
    private func isOverBudget(usage: Double?, budget: Double?) -> Bool {
        guard let usage, let budget else { return false }
        return WeeklyDailyUsage.isDailyBudgetExceeded(todayUsage: usage, budget: budget)
    }

    private func formatPoints(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    private func dayColumn(day: Date, remainingFraction: Double?, isOverBudget: Bool, isToday: Bool) -> some View {
        VStack(spacing: 2) {
            budgetBar(remainingFraction: remainingFraction, isOverBudget: isOverBudget)
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
    private func budgetBar(remainingFraction: Double?, isOverBudget: Bool) -> some View {
        let frameColor = isOverBudget ? Color.orange : Color.secondary
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 2)
                .stroke(
                    remainingFraction == nil ? frameColor.opacity(0.5) : frameColor,
                    style: StrokeStyle(lineWidth: 1, dash: remainingFraction == nil ? [2, 2] : [])
                )

            if let remainingFraction, remainingFraction > 0 {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isOverBudget ? Color.orange : Color.accentColor)
                    .frame(height: max(1, barAreaHeight * CGFloat(remainingFraction)))
            }
        }
    }
}
