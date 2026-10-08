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

    func testDailyBudget_spreadsRemainingAllowanceOverRemainingDays() {
        // Thu 13:00 -> reset Mon 12:59 is 3.99 days away, rounded up to 4 days
        let now = Self.date(2026, 10, 8, 13, 0)
        let budget = WeeklyDailyUsage.dailyBudget(currentWeeklyPercentage: 40, now: now, weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertEqual(budget, 15, accuracy: 0.0001)
    }

    func testDailyBudget_atLeastOneDayBeforeReset() {
        // Two hours before reset: the whole remaining allowance is the budget for one day
        let now = resetTime.addingTimeInterval(-2 * 60 * 60)
        let budget = WeeklyDailyUsage.dailyBudget(currentWeeklyPercentage: 30, now: now, weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertEqual(budget, 70, accuracy: 0.0001)
    }

    func testDailyBudget_resetInPastStillUsesOneDay() {
        let now = resetTime.addingTimeInterval(60)
        let budget = WeeklyDailyUsage.dailyBudget(currentWeeklyPercentage: 90, now: now, weeklyResetTime: resetTime, calendar: calendar)
        XCTAssertEqual(budget, 10, accuracy: 0.0001)
    }

    func testDailyBudget_clampsUsageToValidRange() {
        let now = Self.date(2026, 10, 8, 13, 0)  // 4 remaining days
        XCTAssertEqual(WeeklyDailyUsage.dailyBudget(currentWeeklyPercentage: 120, now: now, weeklyResetTime: resetTime, calendar: calendar), 0, accuracy: 0.0001)
        XCTAssertEqual(WeeklyDailyUsage.dailyBudget(currentWeeklyPercentage: -5, now: now, weeklyResetTime: resetTime, calendar: calendar), 25, accuracy: 0.0001)
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
}
