import Foundation
import os

/// Today at a glance, read from the app's own database.
///
/// Every figure comes from what the watch actually delivered. Nothing is
/// borrowed from the iPhone's pedometer and nothing is filled in: a tile with
/// no data says "--", because zero steps and "the watch never sent steps" are
/// different problems.
@MainActor
final class HealthDashboard: ObservableObject {

    struct Totals {
        var steps: Double = 0
        var activeEnergy: Double = 0
        var distanceMeters: Double = 0
        var floors: Double = 0
    }

    struct HeartRate {
        var latest: Double?
        var min: Double?
        var max: Double?
        var average: Double?
        var at: Date?
    }

    struct Workout: Identifiable {
        let summary: WorkoutSummary
        var id: String { summary.uid }
        var activity: String { WorkoutStyle.name(for: summary.type) }
        var start: Date { Date(timeIntervalSince1970: Double(summary.start) / 1000) }
        var end: Date { Date(timeIntervalSince1970: Double(summary.end) / 1000) }
        /// Active time when the watch sent it (pauses excluded), else wall time.
        var duration: TimeInterval {
            if let active = summary.activeDurationMs, active > 0 { return Double(active) / 1000 }
            return end.timeIntervalSince(start)
        }
        var energyKcal: Double? { summary.activeEnergyKcal > 0 ? summary.activeEnergyKcal : nil }
        var distanceMeters: Double? { summary.distanceMeters > 0 ? summary.distanceMeters : nil }
    }

    @Published private(set) var today = Totals()
    @Published private(set) var heartRate = HeartRate()
    @Published private(set) var restingHeartRate: Double?
    @Published private(set) var spo2: LocalHealthStore.TimePoint?
    @Published private(set) var hrv: LocalHealthStore.TimePoint?
    @Published private(set) var sleepLastNight: TimeInterval?
    @Published private(set) var bedtime: Date?
    @Published private(set) var wakeTime: Date?
    @Published private(set) var workouts: [Workout] = []
    @Published private(set) var training: TrainingStatus?
    @Published private(set) var nightSignals: NightSignals?
    @Published private(set) var hourlySteps: [LocalHealthStore.TimePoint] = []
    @Published private(set) var heartToday: [LocalHealthStore.TimePoint] = []
    @Published private(set) var lastSampleAt: Date?
    /// Latest reading of each on-demand or overnight measurement.
    @Published private(set) var latest: [HealthKind: LocalHealthStore.TimePoint] = [:]
    @Published private(set) var latestEcg: EcgRecord?
    /// Last night including awake stretches, for the hypnogram.
    @Published private(set) var lastNight: [LocalHealthStore.Segment] = []
    @Published private(set) var sleepScore: SleepScore?
    @Published private(set) var readiness: Readiness?
    @Published private(set) var stress: Int?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var hasAnyData = false

    /// Daily goals, editable in Settings.
    @Published var stepGoal: Double = UserDefaults.standard.double(forKey: "goal.steps").nonZero(10_000) {
        didSet { UserDefaults.standard.set(stepGoal, forKey: "goal.steps") }
    }
    @Published var energyGoal: Double = UserDefaults.standard.double(forKey: "goal.energy").nonZero(400) {
        didSet { UserDefaults.standard.set(energyGoal, forKey: "goal.energy") }
    }
    @Published var distanceGoal: Double = UserDefaults.standard.double(forKey: "goal.distance").nonZero(5_000) {
        didSet { UserDefaults.standard.set(distanceGoal, forKey: "goal.distance") }
    }

    private let store: LocalHealthStore
    private let trends: HealthTrends

    init(store: LocalHealthStore, trends: HealthTrends) {
        self.store = store
        self.trends = trends
    }

    static let extraKinds: [HealthKind] = [
        .respiratoryRate, .skinTemperature, .bodyFat, .skeletalMuscle, .bodyWater, .bmr,
    ]

    func refresh() async {
        let calendar = Calendar.current
        let now = Date()
        let midnight = calendar.startOfDay(for: now)

        async let steps = store.dailyStats(.steps, from: midnight)
        async let energy = store.dailyStats(.activeEnergy, from: midnight)
        async let distance = store.dailyStats(.distance, from: midnight)
        async let floors = store.dailyStats(.floors, from: midnight)
        async let heart = store.dailyStats(.heartRate, from: midnight)
        async let latestHeart = store.latest(.heartRate)
        async let hourly = store.buckets(.steps, from: midnight, seconds: 3600)
        async let heartBuckets = store.buckets(.heartRate, from: midnight, seconds: 300)
        async let sleep = store.segments(.sleep, from: midnight.addingTimeInterval(-18 * 3600))
        async let recent = store.workouts(limit: 20)
        async let summary = store.summary()
        async let latestSpo2 = store.latest(.spo2)
        async let latestHrv = store.latest(.hrv)

        today = Totals(
            steps: await steps.first?.sum ?? 0,
            activeEnergy: await energy.first?.sum ?? 0,
            distanceMeters: await distance.first?.sum ?? 0,
            floors: await floors.first?.sum ?? 0
        )

        let heartDay = await heart.first
        let newest = await latestHeart
        heartRate = HeartRate(
            latest: newest?.value,
            min: heartDay?.min,
            max: heartDay?.max,
            average: heartDay?.average,
            at: newest?.date
        )

        spo2 = await latestSpo2
        hrv = await latestHrv
        heartToday = await heartBuckets
        restingHeartRate = HealthMath.restingEstimate(fiveMinuteAverages: heartToday.map(\.value))
        hourlySteps = await hourly

        // Last night: the longest stretch of sleep that ended today, never a
        // nap. Awake stretches (value 1) are not counted as sleep.
        let mainNight = SleepSessions.split(await sleep)
            .filter { $0.end >= midnight && !$0.isNap }
            .max { $0.asleep < $1.asleep }
        if let mainNight {
            let asleepParts = mainNight.segments.filter { $0.value != 1 }
            sleepLastNight = mainNight.asleep
            bedtime = asleepParts.map(\.start).min()
            wakeTime = asleepParts.map(\.end).max()
        } else {
            sleepLastNight = nil
            bedtime = nil
            wakeTime = nil
        }

        workouts = await recent.map(Workout.init(summary:))

        var latestByKind: [HealthKind: LocalHealthStore.TimePoint] = [:]
        for kind in Self.extraKinds {
            latestByKind[kind] = await store.latest(kind.metric)
        }
        latest = latestByKind
        latestEcg = await store.ecgRecords(limit: 1).first

        if let mainNight {
            lastNight = mainNight.segments
            func time(_ stage: Double) -> TimeInterval {
                lastNight.filter { $0.value == stage }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            }
            let staged = lastNight.contains { (2...4).contains($0.value) }
            sleepScore = SleepScore(
                asleep: sleepLastNight ?? 0,
                deep: staged ? time(4) : nil,
                rem: staged ? time(2) : nil,
                awakenings: lastNight.filter { $0.value == 1 }.count
            )
        } else {
            lastNight = []
            sleepScore = nil
        }

        let monthAgo = midnight.addingTimeInterval(-30 * 86_400)
        let hrvBaseline = Self.mean(await store.values(.hrv, from: monthAgo, to: midnight))
        let hrvToday = Self.mean(await store.values(.hrv, from: midnight.addingTimeInterval(-6 * 3600)))
        let resting = await trends.restingSeries(days: 31)
        let restingBaseline = Self.mean(resting.points.filter { $0.date < midnight }.map(\.value))
        let yesterday = midnight.addingTimeInterval(-86_400)
        let stepsYesterday = await store.dailyStats(.steps, from: yesterday, to: midnight).first?.sum
        readiness = Readiness.compute(
            sleep: sleepScore,
            hrvToday: hrvToday,
            hrvBaseline: hrvBaseline,
            restingToday: restingHeartRate,
            restingBaseline: restingBaseline,
            stepsYesterday: stepsYesterday,
            stepGoal: stepGoal
        )
        training = TrainingStatus.compute(await store.workouts(limit: 200, since: now.addingTimeInterval(-29 * 86_400)))

        // Last night runs from 6 pm yesterday to noon today; the baseline is
        // the fortnight before it.
        let nightStart = midnight.addingTimeInterval(-6 * 3600)
        let nightEnd = midnight.addingTimeInterval(12 * 3600)
        let skinNight = Self.mean(await store.values(.skinTemperature, from: nightStart, to: nightEnd))
        let skinBaseline = Self.mean(await store.values(.skinTemperature, from: nightStart.addingTimeInterval(-14 * 86_400), to: nightStart))
        let oxygen = await store.values(.spo2, from: nightStart, to: nightEnd).filter { $0 > 0.5 && $0 <= 1 }
        let skinDelta: Double? = if let skinNight, let skinBaseline { skinNight - skinBaseline } else { nil }
        let restingDelta: Double? = if let restingHeartRate, let restingBaseline { restingHeartRate - restingBaseline } else { nil }
        nightSignals = (skinDelta == nil && restingDelta == nil && oxygen.isEmpty) ? nil : NightSignals(
            skinDelta: skinDelta,
            restingDelta: restingDelta,
            oxygenMin: oxygen.min(),
            oxygenDrops: oxygen.filter { $0 < 0.90 }.count
        )

        if let latestHrv = hrv?.value, let hrvBaseline {
            stress = StressLevel.score(hrv: latestHrv, baseline: hrvBaseline)
        } else {
            stress = nil
        }
        let totals = await summary
        lastSampleAt = totals.newest
        hasAnyData = totals.samples > 0 || totals.workouts > 0
        lastRefresh = now
    }
}

/// Names and symbols for the watch's exercise types.
enum WorkoutStyle {
    static func name(for raw: String) -> String {
        let value = raw.lowercased()
        if value.contains("treadmill") { return tr("Treadmill") }
        if value.contains("run") { return tr("Running") }
        if value.contains("walk") { return tr("Walking") }
        if value.contains("bik") || value.contains("cycl") { return tr("Cycling") }
        if value.contains("hik") { return tr("Hiking") }
        if value.contains("swim") { return tr("Swimming") }
        if value.contains("yoga") { return tr("Yoga") }
        if value.contains("strength") || value.contains("weight") { return tr("Strength") }
        if value.contains("high_intensity") || value.contains("hiit") { return "HIIT" }
        if value.isEmpty || value == "workout" { return tr("Workout") }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func symbol(for raw: String) -> String {
        let value = raw.lowercased()
        if value.contains("run") { return "figure.run" }
        if value.contains("walk") { return "figure.walk" }
        if value.contains("bik") || value.contains("cycl") { return "figure.outdoor.cycle" }
        if value.contains("hik") { return "figure.hiking" }
        if value.contains("swim") { return "figure.pool.swim" }
        if value.contains("yoga") { return "figure.yoga" }
        if value.contains("strength") || value.contains("weight") {
            return "figure.strengthtraining.traditional"
        }
        if value.contains("high_intensity") || value.contains("hiit") {
            return "figure.highintensity.intervaltraining"
        }
        return "figure.mixed.cardio"
    }
}

extension HealthDashboard {
    nonisolated static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

private extension Double {
    /// UserDefaults returns 0 for an unset key, which is never a sane goal.
    func nonZero(_ fallback: Double) -> Double {
        self == 0 ? fallback : self
    }
}
