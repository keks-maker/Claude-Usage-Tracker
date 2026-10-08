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
    /// Daily budget that applied at the most recent fetch of the day.
    /// Optional so that snapshots stored before this field existed still decode.
    var dailyBudget: Double?
}

enum WeeklyDailyUsage {

    /// Reset times that differ by less than this are treated as the same week
    /// (guards against small jitter in the API timestamp).
    static let resetTolerance: TimeInterval = 60

    // MARK: - Week Layout

    /// Start of the 7-day window that ends at `weeklyResetTime`.
    static func weekStart(for weeklyResetTime: Date) -> Date {
        weeklyResetTime.addingTimeInterval(-Constants.weeklyWindow)
    }

    /// Local start-of-day dates for the 7 columns of the weekly breakdown, oldest first.
    ///
    /// The columns end with the calendar day of the reset (the reset day included,
    /// before the reset time). Because the window is 7 x 24 h and not aligned to
    /// midnight, the first column starts one day after the weekday of
    /// `weekStart(for:)`. Observations on that weekday have no column and are not
    /// stored (see `applying`).
    static func dayStarts(weeklyResetTime: Date, calendar: Calendar) -> [Date] {
        let lastDay = calendar.startOfDay(for: weeklyResetTime)
        return (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: lastDay) }
    }

    /// True if `now` falls on one of the columns of the weekly breakdown.
    static func isInColumns(_ now: Date, weeklyResetTime: Date, calendar: Calendar) -> Bool {
        dayStarts(weeklyResetTime: weeklyResetTime, calendar: calendar)
            .contains { calendar.isDate($0, inSameDayAs: now) }
    }

    /// True if both reset times belong to the same weekly window.
    static func isSameWeek(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < resetTolerance
    }

    // MARK: - Snapshot Update

    /// Applies one observation to the stored snapshots and returns the new list.
    ///
    /// - An observation outside the current window (stale or missing reset time),
    ///   or on a day without a column, returns the stored snapshots unchanged, so
    ///   nothing is ever discarded by it. Accepting only observations on a column
    ///   day keeps every stored value visible; the first weekday of the window has
    ///   no column and is therefore not recorded.
    /// - Snapshots of a different weekly window are discarded only by a valid
    ///   observation, i.e. when a new week really starts.
    /// - The day's entry is created on the first observation of the day and its
    ///   end value is updated on every later one.
    static func applying(
        percentage: Double,
        at now: Date,
        weeklyResetTime: Date,
        to existing: [DailyWeeklySnapshot],
        calendar: Calendar
    ) -> [DailyWeeklySnapshot] {
        guard percentage.isFinite,
              now >= weekStart(for: weeklyResetTime),
              now < weeklyResetTime,
              isInColumns(now, weeklyResetTime: weeklyResetTime, calendar: calendar) else {
            return existing
        }

        var result = existing.filter { isSameWeek($0.weekResetTime, weeklyResetTime) }
        // The budget of the last fetch of the day is kept for the day's column
        let budget = dailyBudget(
            currentWeeklyPercentage: percentage,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )

        if let index = result.firstIndex(where: { calendar.isDate($0.dayStart, inSameDayAs: now) }) {
            result[index].endPercentage = percentage
            result[index].dailyBudget = budget
        } else {
            result.append(DailyWeeklySnapshot(
                dayStart: calendar.startOfDay(for: now),
                weekResetTime: weeklyResetTime,
                startPercentage: percentage,
                endPercentage: percentage,
                dailyBudget: budget
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

    /// The daily budget stored for each column, aligned with `dayStarts`.
    /// `nil` for days without snapshot or snapshots stored without a budget.
    static func storedBudgets(
        snapshots: [DailyWeeklySnapshot],
        weeklyResetTime: Date,
        calendar: Calendar
    ) -> [Double?] {
        let days = dayStarts(weeklyResetTime: weeklyResetTime, calendar: calendar)
        let weekSnapshots = snapshots.filter { isSameWeek($0.weekResetTime, weeklyResetTime) }
        return days.map { day in
            weekSnapshots.first { calendar.isDate($0.dayStart, inSameDayAs: day) }?.dailyBudget
        }
    }

    /// Baseline for today's usage: the previous day's end value, or today's first
    /// value if the previous day has no snapshot. `nil` if today has no snapshot yet.
    static func todayBaseline(
        snapshots: [DailyWeeklySnapshot],
        now: Date,
        weeklyResetTime: Date,
        calendar: Calendar
    ) -> Double? {
        let days = dayStarts(weeklyResetTime: weeklyResetTime, calendar: calendar)
        guard let index = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) }) else { return nil }
        let weekSnapshots = snapshots.filter { isSameWeek($0.weekResetTime, weeklyResetTime) }

        if index > 0,
           let previous = weekSnapshots.first(where: { calendar.isDate($0.dayStart, inSameDayAs: days[index - 1]) }) {
            return previous.endPercentage
        }
        return weekSnapshots.first { calendar.isDate($0.dayStart, inSameDayAs: now) }?.startPercentage
    }

    /// Today's weekly usage in percentage points: the live weekly value minus the
    /// baseline. `nil` if `now` is not on one of the columns.
    static func todayUsage(
        snapshots: [DailyWeeklySnapshot],
        currentWeeklyPercentage: Double,
        now: Date,
        weeklyResetTime: Date,
        calendar: Calendar
    ) -> Double? {
        guard isInColumns(now, weeklyResetTime: weeklyResetTime, calendar: calendar),
              currentWeeklyPercentage.isFinite else { return nil }
        let current = min(100, max(0, currentWeeklyPercentage))
        let baseline = todayBaseline(
            snapshots: snapshots,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        ) ?? current
        return max(0, current - baseline)
    }

    /// True once today's usage has reached today's daily budget.
    static func isDailyBudgetExceeded(todayUsage: Double, budget: Double) -> Bool {
        todayUsage >= budget
    }

    /// Height of today's bar as a fraction of the daily budget (0 to 1, values above 1 possible).
    static func todayBarFraction(usage: Double, budget: Double) -> Double {
        guard budget > 0 else { return usage > 0 ? 1 : 0 }
        return usage / budget
    }

    /// Budget still available today, never below 0.
    static func todayRemaining(usage: Double, budget: Double) -> Double {
        max(0, budget - usage)
    }

    // MARK: - Daily Budget

    /// Number of calendar days until the weekly reset, at least 1.
    /// A partial day counts as a full day. Calendar arithmetic keeps this correct
    /// across DST changes, where a day is not exactly 24 hours.
    static func remainingDays(now: Date, weeklyResetTime: Date, calendar: Calendar = .current) -> Int {
        let dayDistance = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: weeklyResetTime)
        ).day ?? 0
        // Same wall-clock time on the reset's day as `now` has today
        let nowOnResetDay = calendar.date(byAdding: .day, value: dayDistance, to: now) ?? now
        let partialDay = weeklyResetTime > nowOnResetDay ? 1 : 0
        return max(1, dayDistance + partialDay)
    }

    /// Percentage points that can still be used per remaining day to reach
    /// 100 % exactly at the weekly reset.
    static func dailyBudget(
        currentWeeklyPercentage: Double,
        now: Date,
        weeklyResetTime: Date,
        calendar: Calendar = .current
    ) -> Double {
        let clampedUsed = min(100, max(0, currentWeeklyPercentage))
        let remaining = Double(remainingDays(now: now, weeklyResetTime: weeklyResetTime, calendar: calendar))
        return (100 - clampedUsed) / remaining
    }
}
