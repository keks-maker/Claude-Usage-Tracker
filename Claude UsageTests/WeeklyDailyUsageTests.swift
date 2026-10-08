import XCTest
@testable import Claude_Usage

final class WeeklyDailyUsageTests: XCTestCase {

    // Fixed calendar so day boundaries are deterministic regardless of the host machine
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// Weekly window ending Monday 2026-10-12 12:59 (Berlin). Columns run Tue 10-06 ... Mon 10-12,
    /// so the reset day itself is a column.
    private let resetTime: Date = date(2026, 10, 12, 12, 59)

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: month, day: day, hour: hour, minute: minute
        ))!
    }

    private func snapshot(_ y: Int, _ m: Int, _ d: Int, start: Double, end: Double, reset: Date? = nil) -> DailyWeeklySnapshot {
        DailyWeeklySnapshot(
            dayStart: calendar.startOfDay(for: Self.date(y, m, d, 12, 0)),
            weekResetTime: reset ?? resetTime,
            startPercentage: start,
            endPercentage: end
        )
    }

    // MARK: - Daily Budget

    func testRestDailyBudget_spreadsRemainingAllowanceOverRemainingDays() {
        // Thu 13:00 -> reset Mon 12:59 is 3.99 days away, rounded up to 4 days
        let now = Self.date(2026, 10, 8, 13, 0)
        let budget = WeeklyDailyUsage.restDailyBudget(currentWeeklyPercentage: 40, now: now, weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertEqual(budget, 15, accuracy: 0.0001)
    }

    func testRestDailyBudget_atLeastOneDayBeforeReset() {
        // Two hours before reset: the whole remaining allowance is the budget for one day
        let now = resetTime.addingTimeInterval(-2 * 60 * 60)
        let budget = WeeklyDailyUsage.restDailyBudget(currentWeeklyPercentage: 30, now: now, weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertEqual(budget, 70, accuracy: 0.0001)
    }

    func testRestDailyBudget_resetInPastStillUsesOneDay() {
        let now = resetTime.addingTimeInterval(60)
        let budget = WeeklyDailyUsage.restDailyBudget(currentWeeklyPercentage: 90, now: now, weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertEqual(budget, 10, accuracy: 0.0001)
    }

    func testRestDailyBudget_clampsUsageToValidRange() {
        let now = Self.date(2026, 10, 8, 13, 0)  // 4 remaining days
        XCTAssertEqual(WeeklyDailyUsage.restDailyBudget(currentWeeklyPercentage: 120, now: now, weeklyResetTime: resetTime, calendar: calendar), 0, accuracy: 0.0001)
        XCTAssertEqual(WeeklyDailyUsage.restDailyBudget(currentWeeklyPercentage: -5, now: now, weeklyResetTime: resetTime, calendar: calendar), 25, accuracy: 0.0001)
    }

    func testRemainingDays_partialDayCountsAsFullDay() {
        let now = resetTime.addingTimeInterval(-(24 * 60 * 60 + 60))
        XCTAssertEqual(WeeklyDailyUsage.remainingDays(now: now, weeklyResetTime: resetTime, calendar: calendar), 2)
    }

    // MARK: - Daily Usage (snapshot difference)

    func testDailyUsage_differenceToPreviousDayEndValue() {
        let snapshots = [
            snapshot(2026, 10, 6, start: 10, end: 15),  // Tue: no previous column -> start is baseline
            snapshot(2026, 10, 7, start: 15, end: 22)   // Wed: end(Wed) - end(Tue)
        ]
        let usage = WeeklyDailyUsage.dailyUsage(snapshots: snapshots, weeklyResetTime: resetTime, calendar: calendar)

        XCTAssertEqual(usage.count, 7)
        XCTAssertEqual(usage[0] ?? -1, 5, accuracy: 0.0001)
        XCTAssertEqual(usage[1] ?? -1, 7, accuracy: 0.0001)
        XCTAssertNil(usage[2])
    }

    func testDailyUsage_missingDayUsesOwnFirstValueAsBaseline() {
        // Wednesday has no snapshot: Thursday's baseline is its own first value
        let snapshots = [
            snapshot(2026, 10, 6, start: 10, end: 12),
            snapshot(2026, 10, 8, start: 20, end: 25)
        ]
        let usage = WeeklyDailyUsage.dailyUsage(snapshots: snapshots, weeklyResetTime: resetTime, calendar: calendar)

        XCTAssertEqual(usage[0] ?? -1, 2, accuracy: 0.0001)
        XCTAssertNil(usage[1])
        XCTAssertEqual(usage[2] ?? -1, 5, accuracy: 0.0001)
    }

    func testDailyUsage_noSnapshotsYieldsNilForEveryDay() {
        let usage = WeeklyDailyUsage.dailyUsage(snapshots: [], weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertEqual(usage.count, 7)
        XCTAssertTrue(usage.allSatisfy { $0 == nil })
    }

    func testDailyUsage_ignoresSnapshotsOfOtherWeek() {
        let previousWeek = resetTime.addingTimeInterval(-7 * 24 * 60 * 60)
        let snapshots = [snapshot(2026, 10, 6, start: 50, end: 60, reset: previousWeek)]
        let usage = WeeklyDailyUsage.dailyUsage(snapshots: snapshots, weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertTrue(usage.allSatisfy { $0 == nil })
    }

    // MARK: - Snapshot Update

    func testApplying_createsOneEntryPerDayAndUpdatesEndValue() {
        var stored: [DailyWeeklySnapshot] = []
        stored = WeeklyDailyUsage.applying(percentage: 15, at: Self.date(2026, 10, 6, 9, 0), weeklyResetTime: resetTime, to: stored, calendar: calendar)
        stored = WeeklyDailyUsage.applying(percentage: 22, at: Self.date(2026, 10, 6, 18, 0), weeklyResetTime: resetTime, to: stored, calendar: calendar)

        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].startPercentage, 15)
        XCTAssertEqual(stored[0].endPercentage, 22)
    }

    func testApplying_weeklyResetDiscardsPreviousWeekSnapshots() {
        let previousWeek = resetTime.addingTimeInterval(-7 * 24 * 60 * 60)
        let existing = [snapshot(2026, 10, 9, start: 80, end: 90, reset: previousWeek)]
        let newReset = resetTime.addingTimeInterval(7 * 24 * 60 * 60)

        let result = WeeklyDailyUsage.applying(
            percentage: 3,
            at: Self.date(2026, 10, 13, 9, 0),  // Tue: first column of the new week (Mon after the reset has none)
            weeklyResetTime: newReset,
            to: existing,
            calendar: calendar
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].weekResetTime, newReset)
        XCTAssertEqual(result[0].startPercentage, 3)
    }

    func testApplying_resetTimeJitterDoesNotStartNewWeek() {
        let existing = [snapshot(2026, 10, 6, start: 10, end: 12)]
        let jittered = resetTime.addingTimeInterval(30)

        let result = WeeklyDailyUsage.applying(
            percentage: 14, at: Self.date(2026, 10, 6, 20, 0), weeklyResetTime: jittered, to: existing, calendar: calendar
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].endPercentage, 14)
    }

    func testApplying_ignoresObservationOutsideWindowAndNonFiniteValues() {
        let afterReset = resetTime.addingTimeInterval(60)
        XCTAssertTrue(WeeklyDailyUsage.applying(percentage: 5, at: afterReset, weeklyResetTime: resetTime, to: [], calendar: calendar).isEmpty)

        let now = Self.date(2026, 10, 8, 12, 0)
        XCTAssertTrue(WeeklyDailyUsage.applying(percentage: .nan, at: now, weeklyResetTime: resetTime, to: [], calendar: calendar).isEmpty)
    }

    func testApplying_observationOnFirstWeekdayHasNoColumnAndIsNotStored() {
        // Reset Mon 10-12 12:59. Mon 10-05 13:00 is inside the 7 x 24 h window, but
        // the first column is Tue 10-06, so this observation must not be accepted.
        let now = Self.date(2026, 10, 5, 13, 0)
        XCTAssertFalse(WeeklyDailyUsage.isInColumns(now, weeklyResetTime: resetTime, calendar: calendar))
        XCTAssertTrue(WeeklyDailyUsage.applying(percentage: 10, at: now, weeklyResetTime: resetTime, to: [], calendar: calendar).isEmpty)
    }

    func testApplying_firstColumnDayIsStoredAndShown() {
        // Tue 10-06 13:00 is inside the window and on the first column
        let now = Self.date(2026, 10, 6, 13, 0)
        let stored = WeeklyDailyUsage.applying(percentage: 10, at: now, weeklyResetTime: resetTime, to: [], calendar: calendar)
        let days = WeeklyDailyUsage.dayStarts(weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertEqual(stored.first?.dayStart, days.first)
        XCTAssertNotNil(WeeklyDailyUsage.dailyUsage(snapshots: stored, weeklyResetTime: resetTime, calendar: calendar)[0])
    }

    func testApplying_everyAcceptedObservationIsShownInItsColumn() {
        // Hourly over the whole window: each accepted observation (incl. today) must have a column
        var time = WeeklyDailyUsage.weekStart(for: resetTime)
        var acceptedCount = 0
        while time < resetTime {
            let stored = WeeklyDailyUsage.applying(percentage: 10, at: time, weeklyResetTime: resetTime, to: [], calendar: calendar)
            if !stored.isEmpty {
                acceptedCount += 1
                XCTAssertNotNil(WeeklyDailyUsage.todaySnapshot(in: stored, now: time, calendar: calendar), "no column for \(time)")
            }
            time = time.addingTimeInterval(60 * 60)
        }
        XCTAssertGreaterThan(acceptedCount, 150)
    }

    func testDayStarts_sevenColumnsEndingWithResetDay() {
        let days = WeeklyDailyUsage.dayStarts(weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first, calendar.startOfDay(for: Self.date(2026, 10, 6, 12, 0)))
        XCTAssertEqual(days.last, calendar.startOfDay(for: Self.date(2026, 10, 12, 12, 0)))
    }

    func testDayStarts_currentDayIsIncludedOnResetDayBeforeResetTime() {
        // Monday 09:00, reset Monday 12:59: today must still get a column
        let now = Self.date(2026, 10, 12, 9, 0)
        let days = WeeklyDailyUsage.dayStarts(weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertTrue(days.contains { calendar.isDate($0, inSameDayAs: now) })
    }

    func testApplying_observationOnResetDayIsShownInItsColumn() {
        let now = Self.date(2026, 10, 12, 9, 0)
        let stored = WeeklyDailyUsage.applying(percentage: 40, at: now, weeklyResetTime: resetTime, to: [], calendar: calendar)
        let usage = WeeklyDailyUsage.dailyUsage(snapshots: stored, weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertEqual(usage.count, 7)
        XCTAssertEqual(usage[6] ?? -1, 0, accuracy: 0.0001)  // no previous column: own start is baseline
        XCTAssertNil(usage[5])
    }

    func testApplying_invalidObservationKeepsExistingSnapshots() {
        let existing = [snapshot(2026, 10, 6, start: 10, end: 12)]
        let now = Self.date(2026, 10, 6, 20, 0)
        let invalidPercentage = WeeklyDailyUsage.applying(
            percentage: .nan, at: now, weeklyResetTime: resetTime, to: existing, calendar: calendar
        )
        XCTAssertEqual(invalidPercentage, existing)

        // Reset time in the past (stale): nothing is written and nothing is discarded
        let stale = WeeklyDailyUsage.applying(
            percentage: 30, at: now, weeklyResetTime: resetTime.addingTimeInterval(-7 * 24 * 60 * 60), to: existing, calendar: calendar
        )
        XCTAssertEqual(stale, existing)
    }

    // MARK: - Store

    func testStore_recordsDailySnapshotsPerProfileAndDeletes() {
        let suite = "WeeklyDailySnapshotStoreTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WeeklyDailySnapshotStore(defaults: defaults)
        let profileId = UUID()
        let now = Self.date(2026, 10, 8, 12, 0)

        store.record(percentage: 10, weeklyResetTime: resetTime, for: profileId, now: now, calendar: calendar)
        store.record(percentage: 13, weeklyResetTime: resetTime, for: profileId, now: now.addingTimeInterval(3600), calendar: calendar)

        let stored = store.snapshots(for: profileId)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].startPercentage, 10)
        XCTAssertEqual(stored[0].endPercentage, 13)
        XCTAssertTrue(store.snapshots(for: UUID()).isEmpty)

        store.deleteSnapshots(for: profileId)
        XCTAssertTrue(store.snapshots(for: profileId).isEmpty)
    }

    func testRecordUsage_fallbackResetLeavesStoredSnapshotsUnchanged() {
        let suite = "WeeklyDailySnapshotFallbackTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WeeklyDailySnapshotStore(defaults: defaults)
        let profileId = UUID()
        let now = Self.date(2026, 10, 8, 12, 0)
        store.record(percentage: 10, weeklyResetTime: resetTime, for: profileId, now: now, calendar: calendar)
        store.record(percentage: 13, weeklyResetTime: resetTime, for: profileId, now: now.addingTimeInterval(3600), calendar: calendar)
        let before = store.snapshots(for: profileId)
        XCTAssertEqual(before.count, 1)

        // Response without seven_day.resets_at: fallback date, flag false
        var fallback = ClaudeUsage.empty
        fallback.weeklyPercentage = 99
        fallback.weeklyResetTime = Self.date(2026, 10, 19, 12, 59)
        fallback.weeklyResetIsFromAPI = false
        store.recordUsage(fallback, for: profileId, now: now.addingTimeInterval(7200), calendar: calendar)

        XCTAssertEqual(store.snapshots(for: profileId), before)
    }

    func testRecordUsage_apiResetUpdatesSnapshot() {
        let suite = "WeeklyDailySnapshotAPITests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WeeklyDailySnapshotStore(defaults: defaults)
        let profileId = UUID()
        var usage = ClaudeUsage.empty
        usage.weeklyPercentage = 20
        usage.weeklyResetTime = resetTime
        usage.weeklyResetIsFromAPI = true
        store.recordUsage(usage, for: profileId, now: Self.date(2026, 10, 8, 12, 0), calendar: calendar)

        XCTAssertEqual(store.snapshots(for: profileId).first?.endPercentage, 20)
    }

    // MARK: - Budget Model (39 % example, dynamic budget, alert)

    private func todayBudgetAt(_ snapshots: [DailyWeeklySnapshot], current: Double, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Double {
        WeeklyDailyUsage.todayBudget(
            snapshots: snapshots, currentWeeklyPercentage: current,
            now: Self.date(y, m, d, h, 0), weeklyResetTime: resetTime, calendar: calendar
        )
    }

    func testTodayBudget_39PercentAtDayStartGivesTwelvePointTwo() {
        // Thu 2026-10-08: Wed ended at 39 %, 5 calendar days remaining including today -> 61 / 5
        let snapshots = [snapshot(2026, 10, 7, start: 30, end: 39)]
        XCTAssertEqual(todayBudgetAt(snapshots, current: 45, 2026, 10, 8), 12.2, accuracy: 0.0001)
    }

    func testTodayBudget_fixedDuringTheDayRegardlessOfLaterFetches() {
        let snapshots = [snapshot(2026, 10, 7, start: 30, end: 39), snapshot(2026, 10, 8, start: 39, end: 50)]
        XCTAssertEqual(todayBudgetAt(snapshots, current: 50, 2026, 10, 8, 18), 12.2, accuracy: 0.0001)
    }

    func testTodayBudget_withoutPreviousDayUsesFirstValueOfToday() {
        // No data at all: the first value of today is the day start value
        XCTAssertEqual(todayBudgetAt([], current: 39, 2026, 10, 8, 9), 12.2, accuracy: 0.0001)
        // Only today's snapshot exists: its start value is the day start value
        let todayOnly = [snapshot(2026, 10, 8, start: 39, end: 45)]
        XCTAssertEqual(todayBudgetAt(todayOnly, current: 45, 2026, 10, 8, 18), 12.2, accuracy: 0.0001)
        // First fetch of the day stores that same budget
        let stored = WeeklyDailyUsage.applying(
            percentage: 39, at: Self.date(2026, 10, 8, 9, 0), weeklyResetTime: resetTime, to: [], calendar: calendar
        )
        XCTAssertEqual(stored.first?.dailyBudget ?? -1, 12.2, accuracy: 0.0001)
    }

    func testTodayBudget_wiringWithUsageBarAndRemainder() {
        // Start of day 39 %, live 45 % -> budget 12.2, today's usage 6, bar ~49 %, remainder 6.2
        let snapshots = [snapshot(2026, 10, 7, start: 30, end: 39)]
        let now = Self.date(2026, 10, 8, 12, 0)
        let budget = WeeklyDailyUsage.todayBudget(
            snapshots: snapshots, currentWeeklyPercentage: 45, now: now, weeklyResetTime: resetTime, calendar: calendar
        )
        let usage = WeeklyDailyUsage.todayUsage(
            snapshots: snapshots, currentWeeklyPercentage: 45, now: now, weeklyResetTime: resetTime, calendar: calendar
        ) ?? -1
        XCTAssertEqual(budget, 12.2, accuracy: 0.0001)
        XCTAssertEqual(usage, 6, accuracy: 0.0001)
        XCTAssertEqual(WeeklyDailyUsage.todayBarFraction(usage: usage, budget: budget), 0.49, accuracy: 0.01)
        XCTAssertEqual(WeeklyDailyUsage.todayRemaining(usage: usage, budget: budget), 6.2, accuracy: 0.05)
        XCTAssertFalse(WeeklyDailyUsage.isDailyBudgetExceeded(todayUsage: 10.2, budget: budget))
        XCTAssertTrue(WeeklyDailyUsage.isDailyBudgetExceeded(todayUsage: 12.2, budget: budget))
    }

    func testRestDailyBudget_decreasesForFollowingDaysWhenUsageGrows() {
        // Thu 12:00 with 39 % used: 61 / 4 days after today
        let now = Self.date(2026, 10, 8, 12, 0)
        let before = WeeklyDailyUsage.restDailyBudget(currentWeeklyPercentage: 39, now: now, weeklyResetTime: resetTime, calendar: calendar)
        let after = WeeklyDailyUsage.restDailyBudget(currentWeeklyPercentage: 50, now: now, weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertEqual(before, 15.25, accuracy: 0.0001)
        XCTAssertLessThan(after, before)
        XCTAssertEqual(after, 12.5, accuracy: 0.0001)
    }

    func testTodayBar_sixPercentOfTwelvePointTwoBudget() {
        XCTAssertEqual(WeeklyDailyUsage.todayBarFraction(usage: 6, budget: 12.2), 0.49, accuracy: 0.01)
        XCTAssertEqual(WeeklyDailyUsage.todayRemaining(usage: 6, budget: 12.2), 6.2, accuracy: 0.05)
    }

    func testTodayRemaining_neverNegativeAndBarNotZeroBudget() {
        XCTAssertEqual(WeeklyDailyUsage.todayRemaining(usage: 15, budget: 12.2), 0)
        XCTAssertEqual(WeeklyDailyUsage.todayBarFraction(usage: 3, budget: 0), 1)
        XCTAssertEqual(WeeklyDailyUsage.todayBarFraction(usage: 0, budget: 0), 0)
    }

    func testTodayUsage_isLiveValueMinusYesterdaysEnd() {
        let snapshots = [snapshot(2026, 10, 7, start: 30, end: 39)]
        let usage = WeeklyDailyUsage.todayUsage(
            snapshots: snapshots, currentWeeklyPercentage: 45,
            now: Self.date(2026, 10, 8, 12, 0), weeklyResetTime: resetTime, calendar: calendar
        )
        XCTAssertEqual(usage ?? -1, 6, accuracy: 0.0001)
    }

    func testDailyBudgetAlert_firesOnceOnDayBudgetIsReached() {
        let suite = "DailyBudgetAlertTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WeeklyDailySnapshotStore(defaults: defaults)
        var dispatched: [String] = []
        let service = DailyBudgetAlertService(defaults: defaults, snapshotStore: store) { _, _, dayKey in
            dispatched.append(dayKey)
        }
        let profileId = UUID()
        let settings = NotificationSettings(
            enabled: true, threshold75Enabled: true, threshold90Enabled: true, threshold95Enabled: true,
            soundName: "default", customThresholds: []
        )
        func usage(_ percentage: Double) -> ClaudeUsage {
            var usage = ClaudeUsage.empty
            usage.weeklyPercentage = percentage
            usage.weeklyResetTime = resetTime
            usage.weeklyResetIsFromAPI = true
            return usage
        }
        func observe(_ percentage: Double, _ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Bool {
            let now = Self.date(y, m, d, h, 0)
            store.record(percentage: percentage, weeklyResetTime: resetTime, for: profileId, now: now, calendar: calendar)
            return service.checkAndNotify(usage: usage(percentage), profileId: profileId, profileName: "Test", settings: settings, now: now, calendar: calendar)
        }

        // Wed: 39 % at end of day. Thu budget fixed at 12.2 points (61 / 5)
        store.record(percentage: 39, weeklyResetTime: resetTime, for: profileId, now: Self.date(2026, 10, 7, 20, 0), calendar: calendar)
        XCTAssertFalse(observe(45, 2026, 10, 8, 12))  // 6 points
        XCTAssertFalse(observe(49, 2026, 10, 8, 12))  // 10 points: no alert
        XCTAssertFalse(observe(51, 2026, 10, 8, 12))  // 12 points: still below 12.2
        XCTAssertTrue(observe(52, 2026, 10, 8, 12))   // 13 points: reached, alert
        // Same day again: no second alert
        XCTAssertFalse(observe(53, 2026, 10, 8, 12))
        XCTAssertEqual(dispatched, ["2026-10-08"])
        // Fri: starts at 53 %, budget (100 - 53) / 4 = 11.75; 75 % means 22 points -> one more alert
        XCTAssertTrue(observe(75, 2026, 10, 9, 12))
        XCTAssertEqual(dispatched, ["2026-10-08", "2026-10-09"])
    }

    func testDailyBudgetAlert_sameDayNotRepeatedAfterRestart() {
        let suite = "DailyBudgetAlertRestartTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let profileId = UUID()
        let settings = NotificationSettings(
            enabled: true, threshold75Enabled: true, threshold90Enabled: true, threshold95Enabled: true,
            soundName: "default", customThresholds: []
        )
        var usage = ClaudeUsage.empty
        usage.weeklyResetTime = resetTime
        usage.weeklyResetIsFromAPI = true
        let thursday = Self.date(2026, 10, 8, 12, 0)

        let store = WeeklyDailySnapshotStore(defaults: defaults)
        store.record(percentage: 39, weeklyResetTime: resetTime, for: profileId, now: Self.date(2026, 10, 7, 20, 0), calendar: calendar)
        store.record(percentage: 52, weeklyResetTime: resetTime, for: profileId, now: thursday, calendar: calendar)
        usage.weeklyPercentage = 52
        var dispatched = 0
        let before = DailyBudgetAlertService(defaults: defaults, snapshotStore: store) { _, _, _ in dispatched += 1 }
        XCTAssertTrue(before.checkAndNotify(usage: usage, profileId: profileId, profileName: "Test", settings: settings, now: thursday, calendar: calendar))

        // Restart: new service and new store instance on the same UserDefaults
        usage.weeklyPercentage = 60
        let afterRestart = DailyBudgetAlertService(defaults: defaults, snapshotStore: WeeklyDailySnapshotStore(defaults: defaults)) { _, _, _ in dispatched += 1 }
        XCTAssertFalse(afterRestart.checkAndNotify(usage: usage, profileId: profileId, profileName: "Test", settings: settings, now: thursday, calendar: calendar))
        XCTAssertEqual(dispatched, 1)
    }

    func testDailyBudgetAlert_disabledNotificationsDoNotFire() {
        let suite = "DailyBudgetAlertDisabledTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        var dispatched = 0
        let service = DailyBudgetAlertService(defaults: defaults, snapshotStore: WeeklyDailySnapshotStore(defaults: defaults)) { _, _, _ in
            dispatched += 1
        }
        var usage = ClaudeUsage.empty
        usage.weeklyPercentage = 99
        usage.weeklyResetTime = resetTime
        usage.weeklyResetIsFromAPI = true
        let settings = NotificationSettings(
            enabled: false, threshold75Enabled: true, threshold90Enabled: true, threshold95Enabled: true,
            soundName: "default", customThresholds: []
        )
        let fired = service.checkAndNotify(usage: usage, profileId: UUID(), profileName: "Test", settings: settings,
                                           now: Self.date(2026, 10, 8, 12, 0), calendar: calendar)
        XCTAssertFalse(fired)
        XCTAssertEqual(dispatched, 0)
    }

    func testStoredBudget_savedWithSnapshotAndUpdatedOnLaterFetch() {
        let wedBudget = todayBudgetAt([], current: 39, 2026, 10, 7)
        let snapshots = [DailyWeeklySnapshot(
            dayStart: calendar.startOfDay(for: Self.date(2026, 10, 7, 12, 0)),
            weekResetTime: resetTime, startPercentage: 39, endPercentage: 39, dailyBudget: wedBudget
        )]
        let budgets = WeeklyDailyUsage.storedBudgets(snapshots: snapshots, weeklyResetTime: resetTime, calendar: calendar)
        let days = WeeklyDailyUsage.dayStarts(weeklyResetTime: resetTime, calendar: calendar)
        let wedIndex = days.firstIndex { calendar.isDate($0, inSameDayAs: Self.date(2026, 10, 7, 12, 0)) }!
        XCTAssertEqual(budgets[wedIndex] ?? -1, wedBudget, accuracy: 0.0001)
        // Days without snapshot stay nil, not 0
        XCTAssertEqual(budgets.compactMap { $0 }.count, 1)
    }

    func testStore_recordStoresBudgetOfTheDay() {
        let suite = "WeeklyDailyBudgetStoreTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = WeeklyDailySnapshotStore(defaults: defaults)
        let profileId = UUID()
        let now = Self.date(2026, 10, 7, 12, 0)
        store.record(percentage: 39, weeklyResetTime: resetTime, for: profileId, now: now, calendar: calendar)
        store.record(percentage: 50, weeklyResetTime: resetTime, for: profileId, now: now.addingTimeInterval(3600), calendar: calendar)

        let stored = store.snapshots(for: profileId)
        XCTAssertEqual(stored.count, 1)
        // Day-start budget: Wed starts at 39 % (first value), 6 calendar days remaining incl. Wed.
        // The later fetch at 50 % does not change it.
        let dayStartBudget = WeeklyDailyUsage.todayBudget(snapshots: [], currentWeeklyPercentage: 39, now: now, weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertEqual(stored[0].dailyBudget ?? -1, dayStartBudget, accuracy: 0.0001)
        XCTAssertEqual(stored[0].dailyBudget ?? -1, 61.0 / 6.0, accuracy: 0.0001)
    }

    @MainActor
    func testDailySnapshot_legacyJSONWithoutBudgetDecodes() throws {
        let snapshot = DailyWeeklySnapshot(
            dayStart: calendar.startOfDay(for: Self.date(2026, 10, 7, 12, 0)),
            weekResetTime: resetTime, startPercentage: 10, endPercentage: 20, dailyBudget: 12.2
        )
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any] ?? [:]
        XCTAssertNotNil(object["dailyBudget"])
        object.removeValue(forKey: "dailyBudget")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DailyWeeklySnapshot.self, from: legacy)
        XCTAssertNil(decoded.dailyBudget)
        XCTAssertEqual(decoded.startPercentage, 10)
        XCTAssertEqual(decoded.endPercentage, 20)
    }
}
