import Foundation
import os

/// History, trends, records and export, all from the app's own database.
///
/// Three rules this file follows:
///
/// 1. **Nothing is interpolated.** A day with no samples is absent from a
///    series, not drawn as zero. A gap in the chart is the truth about a day
///    the watch was off your wrist.
/// 2. **Derived numbers say so.** Resting heart rate and trends are computed
///    here from raw readings, and the screens label them as estimates.
/// 3. **Not a diagnosis.** The app reports and compares your own numbers. It
///    does not label a reading abnormal; a wrist sensor is not a medical device.
@MainActor
final class HealthTrends: ObservableObject {

    struct DailyPoint: Identifiable, Sendable {
        let date: Date
        let value: Double
        var id: Date { date }
    }

    struct Series: Sendable {
        var points: [DailyPoint] = []

        var average: Double? {
            points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count)
        }

        var total: Double { points.map(\.value).reduce(0, +) }
        var minimum: Double? { points.map(\.value).min() }
        var maximum: Double? { points.map(\.value).max() }
        var best: DailyPoint? { points.max { $0.value < $1.value } }

        /// Days in the window that carry no sample at all. Reported, not filled.
        func gaps(in window: Int) -> Int { max(0, window - points.count) }
    }

    struct SleepNight: Identifiable, Sendable {
        let id: Date
        let night: Date
        var deep: TimeInterval = 0
        var core: TimeInterval = 0
        var rem: TimeInterval = 0
        var awake: TimeInterval = 0
        var bedtime: Date?
        var wake: Date?

        var asleep: TimeInterval { deep + core + rem }
        /// False when the watch only reported asleep/awake, which is all Wear
        /// OS gives a third-party app.
        var hasStages: Bool { deep + rem > 0 }
    }

    enum Window: Int, CaseIterable, Identifiable {
        case week = 7
        case month = 30
        case quarter = 90
        case year = 365

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .week: return tr("W")
            case .month: return tr("M")
            case .quarter: return "3M"
            case .year: return tr("Y")
            }
        }
    }

    struct Insight: Identifiable, Sendable {
        let kind: HealthKind?
        let title: String
        let systemImage: String
        let recent: Double
        let baseline: Double
        let unit: String
        /// For resting heart rate a fall is the good direction.
        let higherIsBetter: Bool

        var id: String { title }
        var change: Double? { HealthMath.change(recent, from: baseline) }

        var sentence: String {
            guard let change else { return tr("Not enough history to compare yet.") }
            let size = abs(change)
            if size < 3 { return tr("About the same as your usual.") }
            return String(
                format: change > 0 ? tr("%.0f%% higher than your 4-week average.") : tr("%.0f%% lower than your 4-week average."),
                size
            )
        }

        var isPositive: Bool? {
            guard let change, abs(change) >= 3 else { return nil }
            return (change > 0) == higherIsBetter
        }
    }

    struct Records: Sendable {
        var bestSteps: DailyPoint?
        var bestDistance: DailyPoint?
        var bestEnergy: DailyPoint?
        var currentStreak = 0
        var longestStreak = 0
        var daysWithData = 0
        var lowestResting: DailyPoint?
        var longestSleep: SleepNight?
        var workoutCount = 0
        var workoutDuration: TimeInterval = 0
    }

    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    private let store: LocalHealthStore
    private let log = Logger(subsystem: "dev.galaxybridge.companion", category: "trends")

    init(store: LocalHealthStore) {
        self.store = store
    }

    private func windowStart(days: Int) -> Date {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: -(days - 1), to: anchor) ?? anchor
    }

    // MARK: - Daily series

    /// Daily totals for a cumulative metric (steps, energy, distance, floors).
    func dailyTotals(_ kind: HealthKind, days: Int) async -> Series {
        let stats = await store.dailyStats(kind.metric, from: windowStart(days: days))
        return Series(points: stats.map { DailyPoint(date: $0.day, value: $0.sum) })
    }

    /// Daily averages for a sampled metric.
    func dailyAverages(_ kind: HealthKind, days: Int) async -> Series {
        if kind == .restingHeartRate { return await restingSeries(days: days) }
        let stats = await store.dailyStats(kind.metric, from: windowStart(days: days))
        return Series(points: stats.map { DailyPoint(date: $0.day, value: $0.average) })
    }

    /// Daily minimum and maximum, for the range band.
    func dailyRange(_ kind: HealthKind, days: Int) async -> (low: Series, high: Series) {
        let stats = await store.dailyStats(kind.metric, from: windowStart(days: days))
        return (
            Series(points: stats.map { DailyPoint(date: $0.day, value: $0.min) }),
            Series(points: stats.map { DailyPoint(date: $0.day, value: $0.max) })
        )
    }

    func series(_ kind: HealthKind, days: Int) async -> Series {
        if kind.isCumulative {
            return await dailyTotals(kind, days: days)
        }
        return await dailyAverages(kind, days: days)
    }

    /// Resting heart rate per day, estimated from five-minute averages.
    func restingSeries(days: Int) async -> Series {
        let buckets = await store.buckets(.heartRate, from: windowStart(days: days), seconds: 300)
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: buckets) { calendar.startOfDay(for: $0.date) }
        let points = byDay.compactMap { day, points -> DailyPoint? in
            HealthMath.restingEstimate(fiveMinuteAverages: points.map(\.value))
                .map { DailyPoint(date: day, value: $0) }
        }
        return Series(points: points.sorted { $0.date < $1.date })
    }

    /// Readings of one day, in five-minute buckets, for a day chart.
    func intraday(_ kind: HealthKind, day: Date) async -> [LocalHealthStore.TimePoint] {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(24 * 3600)
        return await store.buckets(kind.metric, from: start, to: end, seconds: kind.isCumulative ? 3600 : 300)
    }

    struct ZoneShare: Identifiable, Sendable {
        let zone: HealthMath.Zone
        let share: Double
        var id: Int { zone.id }
    }

    /// Share of a day's heart-rate readings in each zone.
    func zoneShares(day: Date, age: Double) async -> [ZoneShare] {
        let start = Calendar.current.startOfDay(for: day)
        let values = await store.values(.heartRate, from: start, to: start.addingTimeInterval(24 * 3600))
        let zones = HealthMath.zones(age: age)
        guard !values.isEmpty else { return zones.map { ZoneShare(zone: $0, share: 0) } }
        return zones.map { zone in
            let count = values.filter { $0 >= zone.lower && $0 < zone.upper }.count
            return ZoneShare(zone: zone, share: Double(count) / Double(values.count))
        }
    }

    // MARK: - Sleep

    /// Sleep grouped by the morning it ended on.
    func sleepNights(days: Int) async -> [SleepNight] {
        let start = windowStart(days: days).addingTimeInterval(-18 * 3600)
        let segments = await store.segments(.sleep, from: start)
        let calendar = Calendar.current
        var nights: [Date: SleepNight] = [:]

        for segment in segments {
            let night = calendar.startOfDay(for: segment.end)
            var entry = nights[night] ?? SleepNight(id: night, night: night)
            let duration = segment.end.timeIntervalSince(segment.start)
            // Same stage ordinals the watch uses: 1 awake, 2 REM, 3 light,
            // 4 deep, anything else asleep without a stage.
            switch Int(segment.value) {
            case 1: entry.awake += duration
            case 2: entry.rem += duration
            case 4: entry.deep += duration
            default: entry.core += duration
            }
            if Int(segment.value) != 1 {
                entry.bedtime = min(entry.bedtime ?? segment.start, segment.start)
                entry.wake = max(entry.wake ?? segment.end, segment.end)
            }
            nights[night] = entry
        }
        return nights.values.filter { $0.asleep > 0 }.sorted { $0.night < $1.night }
    }

    // MARK: - Insights and records

    /// Last 7 days against the 28 days before them.
    func insights() async -> [Insight] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        guard let weekStart = calendar.date(byAdding: .day, value: -6, to: today),
              let baseStart = calendar.date(byAdding: .day, value: -34, to: today)
        else { return [] }

        func averages(_ series: Series) -> (Double, Double)? {
            let recent = series.points.filter { $0.date >= weekStart }.map(\.value)
            let base = series.points.filter { $0.date < weekStart && $0.date >= baseStart }.map(\.value)
            guard !recent.isEmpty else { return nil }
            let recentAverage = recent.reduce(0, +) / Double(recent.count)
            let baseAverage = base.isEmpty ? 0 : base.reduce(0, +) / Double(base.count)
            return (recentAverage, baseAverage)
        }

        var result: [Insight] = []
        let specs: [(HealthKind, Bool)] = [(.steps, true), (.energy, true), (.distance, true), (.restingHeartRate, false)]
        for (kind, higherIsBetter) in specs {
            let series = await self.series(kind, days: 35)
            guard let pair = averages(series) else { continue }
            let (recent, base) = pair
            result.append(
                Insight(
                    kind: kind,
                    title: kind == .restingHeartRate ? "Resting heart rate" : "Daily \(kind.title.lowercased())",
                    systemImage: kind.systemImage,
                    recent: kind.display(recent),
                    baseline: kind.display(base),
                    unit: kind.unit,
                    higherIsBetter: higherIsBetter
                )
            )
        }

        let nights = await sleepNights(days: 35)
        let sleepSeries = Series(points: nights.map { DailyPoint(date: $0.night, value: $0.asleep / 3600) })
        if let pair = averages(sleepSeries) {
            let (recent, base) = pair
            result.append(
                Insight(
                    kind: nil,
                    title: "Sleep",
                    systemImage: "bed.double.fill",
                    recent: recent,
                    baseline: base,
                    unit: "h",
                    higherIsBetter: true
                )
            )
        }
        return result
    }

    func records(stepGoal: Double) async -> Records {
        var records = Records()
        let steps = await dailyTotals(.steps, days: 365)
        records.bestSteps = steps.best
        records.bestDistance = await dailyTotals(.distance, days: 365).best
        records.bestEnergy = await dailyTotals(.energy, days: 365).best
        records.daysWithData = steps.points.count
        records.lowestResting = await restingSeries(days: 365).points.min { $0.value < $1.value }
        records.longestSleep = await sleepNights(days: 365).max { $0.asleep < $1.asleep }

        // Streaks of days at or above the step goal. A day without data breaks
        // a streak, the same as a day under goal.
        let calendar = Calendar.current
        let hit = Set(steps.points.filter { $0.value >= stepGoal }.map { calendar.startOfDay(for: $0.date) })
        var longest = 0
        var run = 0
        var previous: Date?
        for day in hit.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }
        records.longestStreak = longest

        var current = 0
        var cursor = calendar.startOfDay(for: Date())
        // Today still counts as "in progress": start from yesterday if today
        // has not reached the goal yet.
        if !hit.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while hit.contains(cursor) {
            current += 1
            guard let before = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = before
        }
        records.currentStreak = current

        let workouts = await store.workouts(limit: 10_000)
        records.workoutCount = workouts.count
        records.workoutDuration = workouts.reduce(0) { $0 + Double($1.end - $1.start) / 1000 }
        return records
    }

    // MARK: - Coverage

    /// How many hours of today carry at least one heart-rate sample.
    func heartRateCoverageToday() async -> (hoursWithData: Int, samples: Int) {
        let start = Calendar.current.startOfDay(for: Date())
        let hours = await store.buckets(.heartRate, from: start, seconds: 3600)
        let values = await store.values(.heartRate, from: start)
        return (hours.count, values.count)
    }

    func storeSummary() async -> LocalHealthStore.Summary {
        await store.summary()
    }

    // MARK: - Export

    /// A CSV of every sample in the window, one row per sample with its own
    /// timestamps and units, plus one row per workout.
    func exportCSV(days: Int) async -> URL? {
        let start = windowStart(days: days)
        let samples = await store.allSamples(since: start)
        let workouts = await store.workouts(limit: 10_000, since: start)

        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        func stamp(_ millis: Int64) -> String {
            formatter.string(from: Date(timeIntervalSince1970: Double(millis) / 1000))
        }

        var rows = ["metric,start,end,value,unit"]
        for sample in samples {
            rows.append(
                [sample.metric.rawValue, stamp(sample.start), stamp(sample.end), String(sample.value), Self.unit(sample.metric)]
                    .joined(separator: ",")
            )
        }
        for workout in workouts.reversed() {
            rows.append(
                ["WORKOUT_" + workout.type.uppercased(), stamp(workout.start), stamp(workout.end),
                 String(workout.activeEnergyKcal), "kcal"].joined(separator: ",")
            )
        }
        guard rows.count > 1 else {
            lastError = "Nothing recorded in this window yet."
            return nil
        }

        let name = "galaxybridge-health-\(formatter.string(from: Date()).prefix(10)).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            lastError = nil
            return url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private static func unit(_ metric: Metric) -> String {
        switch metric {
        case .steps, .floors: return "count"
        case .heartRate, .restingHeartRate: return "bpm"
        case .activeEnergy: return "kcal"
        case .distance: return "m"
        case .spo2: return "percent"
        case .hrv: return "ms"
        case .sleep: return "stage"
        case .skinTemperature: return "celsius"
        case .bodyFat: return "percent"
        case .skeletalMuscle, .bodyWater: return "kg"
        case .bmr: return "kcal/day"
        case .respiratoryRate: return "breaths/min"
        }
    }
}
