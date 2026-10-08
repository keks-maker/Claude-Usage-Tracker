//
//  WeeklyDailyUsage.swift
//  Claude Usage
//
//  Pure calculations for the per-day breakdown of the weekly usage.
//  No storage and no UI here; everything is deterministic for given inputs.
//

import Foundation

/// Weekly usage observed on one local calendar day of the current weekly window.
struct DailyWeeklySnapshot: Codable, Equatable {
    /// Local start of the calendar day this snapshot belongs to
    let dayStart: Date
    /// `weeklyResetTime` of the week the value belongs to
    let weekResetTime: Date
    /// Weekly percentage at the first fetch of the day
    let startPercentage: Double
    /// Weekly percentage at the most recent fetch of the day
    var endPercentage: Double
}

enum WeeklyDailyUsage {

    /// Reset times that differ by less than this are treated as the same week
    /// (guards against small jitter in the API timestamp).
    static let resetTolerance: TimeInterval = 60

    private static let secondsPerDay: TimeInterval = 24 * 60 * 60

    // MARK: - Week Layout

    /// Start of the 7-day window that ends at `weeklyResetTime`.
    static func weekStart(for weeklyResetTime: Date) -> Date {
        weeklyResetTime.addingTimeInterval(-Constants.weeklyWindow)
    }

    /// Local start-of-day dates for the 7 days of the weekly window, oldest first.
    static func dayStarts(weeklyResetTime: Date, calendar: Calendar) -> [Date] {
        let first = calendar.startOfDay(for: weekStart(for: weeklyResetTime))
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }

    /// True if both reset times belong to the same weekly window.
    static func isSameWeek(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < resetTolerance
    }

    // MARK: - Snapshot Update

    /// Applies one observation to the stored snapshots and returns the new list.
    ///
    /// - Snapshots of a different weekly window are discarded (week reset).
    /// - An observation outside the current window (stale reset time) is ignored.
    /// - The day's entry is created on the first observation of the day and its
    ///   end value is updated on every later one.
    static func applying(
        percentage: Double,
        at now: Date,
        weeklyResetTime: Date,
        to existing: [DailyWeeklySnapshot],
        calendar: Calendar
    ) -> [DailyWeeklySnapshot] {
        var result = existing.filter { isSameWeek($0.weekResetTime, weeklyResetTime) }

        guard percentage.isFinite,
              now >= weekStart(for: weeklyResetTime),
              now < weeklyResetTime else {
            return result
        }

        if let index = result.firstIndex(where: { calendar.isDate($0.dayStart, inSameDayAs: now) }) {
            result[index].endPercentage = percentage
        } else {
            result.append(DailyWeeklySnapshot(
                dayStart: calendar.startOfDay(for: now),
                weekResetTime: weeklyResetTime,
                startPercentage: percentage,
                endPercentage: percentage
            ))
        }
        return result
    }

    // MARK: - Daily Usage

    /// Usage per day of the weekly window, aligned with `dayStarts`. Days without
    /// any snapshot are `nil`.
    ///
    /// A day's usage is its end value minus the previous day's end value. If the
    /// previous day has no snapshot, the day's first value is the baseline instead.
    static func dailyUsage(
        snapshots: [DailyWeeklySnapshot],
        weeklyResetTime: Date,
        calendar: Calendar
    ) -> [Double?] {
        let days = dayStarts(weeklyResetTime: weeklyResetTime, calendar: calendar)
        let weekSnapshots = snapshots.filter { isSameWeek($0.weekResetTime, weeklyResetTime) }

        func snapshot(for day: Date) -> DailyWeeklySnapshot? {
            weekSnapshots.first { calendar.isDate($0.dayStart, inSameDayAs: day) }
        }

        return days.indices.map { index in
            guard let current = snapshot(for: days[index]) else { return nil }
            let baseline: Double
            if index > 0, let previous = snapshot(for: days[index - 1]) {
                baseline = previous.endPercentage
            } else {
                baseline = current.startPercentage
            }
            return max(0, current.endPercentage - baseline)
        }
    }

    /// The snapshot for the calendar day of `now`, if any.
    static func todaySnapshot(
        in snapshots: [DailyWeeklySnapshot],
        now: Date,
        calendar: Calendar
    ) -> DailyWeeklySnapshot? {
        snapshots.first { calendar.isDate($0.dayStart, inSameDayAs: now) }
    }

    // MARK: - Daily Budget

    /// Number of days until the weekly reset, rounded up, at least 1.
    static func remainingDays(now: Date, weeklyResetTime: Date) -> Int {
        let days = ceil(weeklyResetTime.timeIntervalSince(now) / secondsPerDay)
        return Int(max(1, days))
    }

    /// Percentage points that can still be used per remaining day to reach
    /// 100 % exactly at the weekly reset.
    static func dailyBudget(
        currentWeeklyPercentage: Double,
        now: Date,
        weeklyResetTime: Date
    ) -> Double {
        let clampedUsed = min(100, max(0, currentWeeklyPercentage))
        let remaining = Double(remainingDays(now: now, weeklyResetTime: weeklyResetTime))
        return (100 - clampedUsed) / remaining
    }
}
