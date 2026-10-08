//
//  WeeklyDailySnapshotStore.swift
//  Claude Usage
//
//  Persists the per-day weekly usage snapshots of each profile in UserDefaults.
//  Only the current weekly window is kept, so the stored data stays a few hundred
//  bytes per profile. Contains no credentials.
//

import Foundation

final class WeeklyDailySnapshotStore {
    static let shared = WeeklyDailySnapshotStore()

    private let defaults: UserDefaults
    private let keyPrefix = "weeklyDailySnapshots_"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Public

    /// Records a fetched usage for a profile. Only usage whose weekly reset time came
    /// from the API is recorded; a fallback reset would otherwise start a wrong week
    /// and discard the stored snapshots of the real one.
    func recordUsage(
        _ usage: ClaudeUsage,
        for profileId: UUID,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        guard usage.weeklyResetIsFromAPI else { return }
        record(
            percentage: usage.weeklyPercentage,
            weeklyResetTime: usage.weeklyResetTime,
            for: profileId,
            now: now,
            calendar: calendar
        )
    }

    /// Records the current weekly percentage for a profile on the calendar day of `now`.
    func record(
        percentage: Double,
        weeklyResetTime: Date,
        for profileId: UUID,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let existing = snapshots(for: profileId)
        let updated = WeeklyDailyUsage.applying(
            percentage: percentage,
            at: now,
            weeklyResetTime: weeklyResetTime,
            to: existing,
            calendar: calendar
        )
        guard updated != existing else { return }
        save(updated, for: profileId)
    }

    /// Snapshots of the profile's current weekly window (empty if none stored).
    func snapshots(for profileId: UUID) -> [DailyWeeklySnapshot] {
        guard let data = defaults.data(forKey: storageKey(for: profileId)) else { return [] }
        do {
            return try decoder.decode([DailyWeeklySnapshot].self, from: data)
        } catch {
            LoggingService.shared.logStorageError("weeklyDailySnapshots", error: error)
            return []
        }
    }

    /// Removes all stored snapshots of a profile (called when the profile is deleted).
    func deleteSnapshots(for profileId: UUID) {
        defaults.removeObject(forKey: storageKey(for: profileId))
    }

    // MARK: - Private

    private func save(_ snapshots: [DailyWeeklySnapshot], for profileId: UUID) {
        do {
            let data = try encoder.encode(snapshots)
            defaults.set(data, forKey: storageKey(for: profileId))
        } catch {
            LoggingService.shared.logStorageError("saveWeeklyDailySnapshots", error: error)
        }
    }

    private func storageKey(for profileId: UUID) -> String {
        "\(keyPrefix)\(profileId.uuidString)"
    }
}
