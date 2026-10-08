//
//  DailyBudgetAlertService.swift
//  Claude Usage
//
//  Sends one notification per local day and profile once today's weekly usage
//  reaches today's daily budget. The day of the last alert is kept per profile
//  in UserDefaults, so the alert survives app restarts. Contains no credentials.
//

import Foundation

final class DailyBudgetAlertService {
    static let shared = DailyBudgetAlertService()

    /// Delivers the notification. Parameters: profile id, profile name, day key (yyyy-MM-dd).
    typealias Dispatch = (_ profileId: UUID, _ profileName: String, _ dayKey: String) -> Void

    private let defaults: UserDefaults
    private let snapshotStore: WeeklyDailySnapshotStore
    private let dispatch: Dispatch
    private let keyPrefix = "dailyBudgetAlertDay_"

    init(
        defaults: UserDefaults = .standard,
        snapshotStore: WeeklyDailySnapshotStore = .shared,
        dispatch: @escaping Dispatch = { profileId, profileName, dayKey in
            NotificationManager.shared.sendDailyBudgetAlert(
                profileName: profileName,
                profileId: profileId,
                dayKey: dayKey
            )
        }
    ) {
        self.defaults = defaults
        self.snapshotStore = snapshotStore
        self.dispatch = dispatch
    }

    /// Checks the budget after a usage fetch has been recorded in the snapshot store.
    /// Returns `true` if an alert was dispatched.
    @discardableResult
    func checkAndNotify(
        usage: ClaudeUsage,
        profileId: UUID,
        profileName: String,
        settings: NotificationSettings,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        // Same guard as the snapshot store: a fallback reset time is not a real week
        guard settings.enabled,
              usage.weeklyResetIsFromAPI,
              usage.weeklyPercentage.isFinite,
              usage.weeklyResetTime > now else { return false }

        let snapshots = snapshotStore.snapshots(for: profileId)
        guard let todayUsage = WeeklyDailyUsage.todayUsage(
            snapshots: snapshots,
            currentWeeklyPercentage: usage.weeklyPercentage,
            now: now,
            weeklyResetTime: usage.weeklyResetTime,
            calendar: calendar
        ) else { return false }

        let budget = WeeklyDailyUsage.dailyBudget(
            currentWeeklyPercentage: usage.weeklyPercentage,
            now: now,
            weeklyResetTime: usage.weeklyResetTime,
            calendar: calendar
        )
        guard WeeklyDailyUsage.isDailyBudgetExceeded(todayUsage: todayUsage, budget: budget) else { return false }

        let dayKey = Self.dayKey(for: now, calendar: calendar)
        let key = storageKey(for: profileId)
        guard defaults.string(forKey: key) != dayKey else { return false }

        // Persist before dispatching so a repeated check on the same day cannot alert twice
        defaults.set(dayKey, forKey: key)
        dispatch(profileId, profileName, dayKey)
        return true
    }

    // MARK: - Private

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private func storageKey(for profileId: UUID) -> String {
        "\(keyPrefix)\(profileId.uuidString)"
    }
}
