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
        let budget = WeeklyDailyUsage.dailyBudget(currentWeeklyPercentage: weeklyPercentage, now: now, weeklyResetTime: weeklyResetTime, calendar: calendar)
        let scaleMax = max(budget, usages.compactMap { $0 }.max() ?? 0, 1)
        let todayIndex = days.firstIndex { calendar.isDate($0, inSameDayAs: now) }

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days.indices, id: \.self) { index in
                    dayColumn(
                        day: days[index],
                        usage: usages[index],
                        budget: budget,
                        scaleMax: scaleMax,
                        isToday: index == todayIndex
                    )
                }
            }
            .frame(height: barAreaHeight + 16)
            .overlay(alignment: .top) {
                budgetLine(budget: budget, scaleMax: scaleMax)
                    .frame(height: barAreaHeight)
            }

            if let todayIndex, let todayValue = usages[todayIndex] {
                Text("popover.daily_budget.today".localized(with: Int(todayValue.rounded()), Int(budget.rounded())))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.vertical, 4)
    }

    private func dayColumn(day: Date, usage: Double?, budget: Double, scaleMax: Double, isToday: Bool) -> some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                Color.clear
                if let usage {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(usage > budget ? Color.orange : Color.accentColor.opacity(isToday ? 1 : 0.6))
                        .frame(height: max(2, barAreaHeight * CGFloat(usage / scaleMax)))
                } else {
                    // Missing day: thin placeholder, distinct from a real 0
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
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

    private func budgetLine(budget: Double, scaleMax: Double) -> some View {
        GeometryReader { geometry in
            let y = geometry.size.height * CGFloat(1 - budget / scaleMax)
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: geometry.size.width, y: y))
            }
            .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }
}
