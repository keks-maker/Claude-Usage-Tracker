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
        // Today's budget is fixed at the start of the day, so every fetch of the day stores the same value
        // With an unreliable baseline (no earlier day) the budget is only an estimate and is not stored,
        // so the column does not look reliable on a later day
        let budget: Double? = isTodayBaselineReliable(
            snapshots: existing,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        ) ? todayBudget(
            snapshots: existing,
            currentWeeklyPercentage: percentage,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        ) : nil

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
    /// A day's usage is its end value minus the end value of the closest earlier day
    /// that has a snapshot (so a gap does not lose usage). If there is none, the day's
    /// first value is the baseline instead.
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
            if let previous = days[..<index].reversed().lazy.compactMap({ snapshot(for: $0) }).first {
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

    /// Baseline for today's usage: the end value of the closest earlier day with a
    /// snapshot, or today's first value if there is none (then the baseline is only
    /// an estimate, see `isTodayBaselineReliable`). `nil` if today has no snapshot yet
    /// and no earlier day exists.
    static func todayBaseline(
        snapshots: [DailyWeeklySnapshot],
        now: Date,
        weeklyResetTime: Date,
        calendar: Calendar
    ) -> Double? {
        let days = dayStarts(weeklyResetTime: weeklyResetTime, calendar: calendar)
        guard let index = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) }) else { return nil }
        let weekSnapshots = snapshots.filter { isSameWeek($0.weekResetTime, weeklyResetTime) }

        if let previous = earlierSnapshot(before: index, days: days, in: weekSnapshots, calendar: calendar) {
            return previous.endPercentage
        }
        return weekSnapshots.first { calendar.isDate($0.dayStart, inSameDayAs: now) }?.startPercentage
    }

    /// True if today's baseline comes from an earlier day's snapshot. Without one the
    /// baseline is only the first fetch of the day (or the live value), which may already
    /// include usage from earlier today, so budget and usage are unknown.
    static func isTodayBaselineReliable(
        snapshots: [DailyWeeklySnapshot],
        now: Date,
        weeklyResetTime: Date,
        calendar: Calendar
    ) -> Bool {
        let days = dayStarts(weeklyResetTime: weeklyResetTime, calendar: calendar)
        guard let index = days.firstIndex(where: { calendar.isDate($0, inSameDayAs: now) }) else { return false }
        let weekSnapshots = snapshots.filter { isSameWeek($0.weekResetTime, weeklyResetTime) }
        return earlierSnapshot(before: index, days: days, in: weekSnapshots, calendar: calendar) != nil
    }

    /// The snapshot of the closest day before column `index`, if any.
    private static func earlierSnapshot(
        before index: Int,
        days: [Date],
        in weekSnapshots: [DailyWeeklySnapshot],
        calendar: Calendar
    ) -> DailyWeeklySnapshot? {
        days[..<index].reversed().lazy.compactMap { day in
            weekSnapshots.first { calendar.isDate($0.dayStart, inSameDayAs: day) }
        }.first
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

    /// True once usage has reached the daily budget. A budget of 0 never counts
    /// as exceeded: there was nothing to exceed.
    static func isDailyBudgetExceeded(todayUsage: Double, budget: Double) -> Bool {
        budget > 0 && todayUsage >= budget
    }

    /// Budget still available today, never below 0.
    static func todayRemaining(usage: Double, budget: Double) -> Double {
        max(0, budget - usage)
    }

    /// Fill level of a day's budget bar: the share of the day's budget still left (0 to 1).
    /// The bar's full height is the budget, so 0 usage gives 1 and usage at or above the budget gives 0.
    /// A budget of 0 is already used up (0). `nil` if the usage or the budget is unknown or the budget is negative.
    static func dayRemainingFraction(usage: Double?, budget: Double?) -> Double? {
        guard let usage, let budget, usage.isFinite, budget.isFinite, budget >= 0 else { return nil }
        guard budget > 0 else { return 0 }
        return min(1, max(0, (budget - usage) / budget))
    }

    // MARK: - Column Values

    /// Usage and budget shown for one column of the breakdown.
    struct ColumnValue: Equatable {
        let usage: Double?
        let budget: Double?
        /// True if the budget is only an estimate (today without an earlier day's snapshot).
        var isEstimated: Bool = false
    }

    /// Usage and budget per column, aligned with `dayStarts`.
    /// - Past days: stored usage and stored budget.
    /// - Today: live usage and today's budget. While the baseline is unreliable the first value of
    ///   the day stands in for the day start, so the budget is an estimate (`isEstimated`) and the
    ///   measured usage is a lower bound.
    /// - Days after today: usage 0 and `restDailyBudget`, which depends only on the current
    ///   weekly value, never on the baseline. They are therefore always known.
    ///   (`restDailyBudget` spreads the allowance left now over the calendar days after today.)
    static func columnValues(
        snapshots: [DailyWeeklySnapshot],
        currentWeeklyPercentage: Double,
        now: Date,
        weeklyResetTime: Date,
        calendar: Calendar
    ) -> [ColumnValue] {
        let days = dayStarts(weeklyResetTime: weeklyResetTime, calendar: calendar)
        let usages = dailyUsage(snapshots: snapshots, weeklyResetTime: weeklyResetTime, calendar: calendar)
        let stored = storedBudgets(snapshots: snapshots, weeklyResetTime: weeklyResetTime, calendar: calendar)
        let reliable = isTodayBaselineReliable(snapshots: snapshots, now: now, weeklyResetTime: weeklyResetTime, calendar: calendar)
        let live = todayUsage(snapshots: snapshots, currentWeeklyPercentage: currentWeeklyPercentage, now: now, weeklyResetTime: weeklyResetTime, calendar: calendar)
        let todayB = todayBudget(snapshots: snapshots, currentWeeklyPercentage: currentWeeklyPercentage, now: now, weeklyResetTime: weeklyResetTime, calendar: calendar)
        let rest = restDailyBudget(currentWeeklyPercentage: currentWeeklyPercentage, now: now, weeklyResetTime: weeklyResetTime, calendar: calendar)
        let today = calendar.startOfDay(for: now)

        return days.indices.map { index in
            let day = days[index]
            if calendar.isDate(day, inSameDayAs: today) {
                return ColumnValue(usage: live, budget: todayB, isEstimated: !reliable)
            }
            if day > today {
                return ColumnValue(usage: 0, budget: rest)
            }
            return ColumnValue(usage: usages[index], budget: stored[index])
        }
    }

    // MARK: - Budget End Marker

    /// Where today's daily budget ends on the weekly scale.
    struct BudgetEnd: Equatable {
        /// Weekly percentage (0 to 100) at which today's budget is used up: day start value + today's budget
        let percentage: Double
        /// True if the day start value is only an estimate (see `isTodayBaselineReliable`)
        let isEstimated: Bool
    }

    /// End of today's budget on the weekly scale, for a marker on the weekly bar.
    /// `nil` if `now` is not on a column, the live value is invalid or today's budget is 0
    /// (then there is no budget to mark).
    static func todayBudgetEnd(
        snapshots: [DailyWeeklySnapshot],
        currentWeeklyPercentage: Double,
        now: Date,
        weeklyResetTime: Date,
        calendar: Calendar
    ) -> BudgetEnd? {
        guard isInColumns(now, weeklyResetTime: weeklyResetTime, calendar: calendar),
              currentWeeklyPercentage.isFinite else { return nil }
        let current = min(100, max(0, currentWeeklyPercentage))
        let budget = todayBudget(
            snapshots: snapshots,
            currentWeeklyPercentage: current,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )
        guard budget > 0 else { return nil }
        let start = todayBaseline(
            snapshots: snapshots,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        ) ?? current
        return BudgetEnd(
            percentage: min(100, max(0, start) + budget),
            isEstimated: !isTodayBaselineReliable(
                snapshots: snapshots,
                now: now,
                weeklyResetTime: weeklyResetTime,
                calendar: calendar
            )
        )
    }

    // MARK: - Column Markers

    /// End of one day's budget on the weekly scale, for the marker of that column.
    struct ColumnMarker: Equatable {
        /// Index into `dayStarts`
        let columnIndex: Int
        /// Weekly percentage (0 to 100) at which this day's budget is used up
        let percentage: Double
        /// True if the value is only an estimate (today with an unreliable baseline)
        let isEstimated: Bool
    }

    /// Budget end markers per column, aligned with `dayStarts`.
    ///
    /// Cumulation (all values on the weekly scale, capped at 100):
    /// - Past days: `nil`, no marker.
    /// - Today: `todayBudgetEnd` (day start value + today's budget).
    /// - Day k after today (k = 1...n): current weekly value + k * `restDailyBudget`.
    ///   This uses the same per-day budget as the columns of those days, so marker and
    ///   column always agree, and the last day ends exactly at 100.
    ///   Because the future markers start from the live value and today's marker from the
    ///   day start value, a day that stays under its budget moves the later markers to
    ///   the right of what the day start plan said (the saved allowance is spread over
    ///   the remaining days).
    /// - A day with a budget of 0 has no marker (nothing to mark).
    /// `nil` for all columns if `now` is not on a column or the live value is invalid.
    static func columnMarkers(
        snapshots: [DailyWeeklySnapshot],
        currentWeeklyPercentage: Double,
        now: Date,
        weeklyResetTime: Date,
        calendar: Calendar
    ) -> [ColumnMarker?] {
        let days = dayStarts(weeklyResetTime: weeklyResetTime, calendar: calendar)
        guard isInColumns(now, weeklyResetTime: weeklyResetTime, calendar: calendar),
              currentWeeklyPercentage.isFinite else {
            return days.map { _ in nil }
        }
        let current = min(100, max(0, currentWeeklyPercentage))
        let today = calendar.startOfDay(for: now)
        let todayEnd = todayBudgetEnd(
            snapshots: snapshots,
            currentWeeklyPercentage: current,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )
        let rest = restDailyBudget(
            currentWeeklyPercentage: current,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )

        var futureStep = 0
        return days.indices.map { index in
            let day = days[index]
            if calendar.isDate(day, inSameDayAs: today) {
                return todayEnd.map {
                    ColumnMarker(columnIndex: index, percentage: $0.percentage, isEstimated: $0.isEstimated)
                }
            }
            if day > today {
                futureStep += 1
                guard rest > 0 else { return nil }
                return ColumnMarker(
                    columnIndex: index,
                    percentage: min(100, current + Double(futureStep) * rest),
                    isEstimated: false
                )
            }
            return nil
        }
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

    /// Budget for today, fixed at the start of the day: the weekly allowance that was
    /// left at the start of today, spread over the calendar days remaining including today.
    ///
    /// The start value is `todayBaseline` (previous day's end, or today's first value).
    /// If today has no value yet, `currentWeeklyPercentage` is the first value of the day.
    static func todayBudget(
        snapshots: [DailyWeeklySnapshot],
        currentWeeklyPercentage: Double,
        now: Date,
        weeklyResetTime: Date,
        calendar: Calendar = .current
    ) -> Double {
        let current = min(100, max(0, currentWeeklyPercentage))
        let dayStartValue = todayBaseline(
            snapshots: snapshots,
            now: now,
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        ) ?? current
        let startUsed = min(100, max(0, dayStartValue))
        // Evaluated at midnight: counts today as a full day, like the days after it
        let days = remainingDays(
            now: calendar.startOfDay(for: now),
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )
        return (100 - startUsed) / Double(days)
    }

    /// Budget per day for the days after today, if the weekly usage stays at
    /// `currentWeeklyPercentage`: the allowance left now, spread over the calendar
    /// days after today (at least 1).
    static func restDailyBudget(
        currentWeeklyPercentage: Double,
        now: Date,
        weeklyResetTime: Date,
        calendar: Calendar = .current
    ) -> Double {
        let clampedUsed = min(100, max(0, currentWeeklyPercentage))
        let daysIncludingToday = remainingDays(
            now: calendar.startOfDay(for: now),
            weeklyResetTime: weeklyResetTime,
            calendar: calendar
        )
        return (100 - clampedUsed) / Double(max(1, daysIncludingToday - 1))
    }
}
