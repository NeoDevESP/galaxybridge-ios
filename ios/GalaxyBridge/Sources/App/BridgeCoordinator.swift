import Foundation
import os

/// Wires the BLE link to the app's health database, Apple Health and the PIM
/// syncs.
///
/// The ordering is the important part: a health batch is committed to the
/// local database *before* it is ACKed, and the ACK is skipped when that
/// fails, so the watch's spool stays the backup until the phone really has the
/// data. Apple Health is an optional copy made afterwards, only when this
/// install has the HealthKit entitlement.
@MainActor
final class BridgeCoordinator: ObservableObject {

    let client = BridgeClient()
    let store = LocalHealthStore()
    let health = HealthBridge()
    let pim = PimSync()
    let fitness = FitnessStore()
    let dashboard: HealthDashboard
    let trends: HealthTrends
    let discovery = DebugDiscovery()

    @Published private(set) var events: [String] = []
    @Published private(set) var achievementContext = AchievementContext()

    private let log = Logger(subsystem: "dev.galaxybridge.companion", category: "coordinator")

    init() {
        trends = HealthTrends(store: store)
        dashboard = HealthDashboard(store: store, trends: trends)
        client.onMessage = { [weak self] type, payload in
            guard let self else { return }
            Task { await self.handle(type: type, payload: payload) }
        }
    }

    func onAppear() async {
        await dashboard.refresh()
        client.start()
        await requestHealthAccess()
    }

    /// One source of truth for "HealthKit is usable", republished to everything
    /// that depends on it. Without the entitlement this stays false and the
    /// health screens say so instead of querying anyway.
    func requestHealthAccess() async {
        Breadcrumbs.drop("asking for HealthKit")
        await health.requestAuthorization()
        Breadcrumbs.drop("HealthKit authorised=\(health.authorized)")
    }

    /// Copies everything already stored into Apple Health. Samples carry the
    /// watch's uid, so running it twice does not duplicate anything.
    func copyToAppleHealth() async -> Int {
        guard health.authorized else { return 0 }
        let samples = await store.allSamples(since: .distantPast)
        var written = 0
        var index = 0
        while index < samples.count {
            let chunk = Array(samples[index..<min(index + 500, samples.count)])
            if await health.write(batch: HealthBatch(samples: chunk, cursor: 0)) {
                written += chunk.count
            }
            index += 500
        }
        for workout in await store.workouts(limit: 10_000) {
            _ = await health.write(workout: workout)
        }
        note("copied \(written) samples to Apple Health")
        return written
    }

    /// Gathers everything achievements are judged on and records the ones
    /// earned for the first time.
    func refreshAchievements() async {
        var context = AchievementContext()
        let steps = await trends.dailyTotals(.steps, days: 3650)
        context.bestDaySteps = steps.maximum ?? 0
        context.totalSteps = steps.total
        context.daysWithData = steps.points.count
        context.totalDistanceKm = await trends.dailyTotals(.distance, days: 3650).total / 1000
        let records = await trends.records(stepGoal: dashboard.stepGoal)
        context.longestStepStreak = records.longestStreak
        context.currentStepStreak = records.currentStreak
        context.watchWorkouts = records.workoutCount
        context.sleepNights = await trends.sleepNights(days: 3650).count

        let data = fitness.data
        context.gymSessions = data.sessions.count
        context.gymVolumeKg = data.sessions.map(\.volume).reduce(0, +)
        context.personalRecords = fitness.personalRecords.count
        context.foodLoggingStreak = fitness.foodLoggingStreak
        context.waterGoalDays = fitness.waterGoalDays
        context.weighIns = data.weights.count
        context.fasts = fitness.completedFasts
        context.intervalSessions = data.intervalSessions
        context.goalWeeks = fitness.goalWeeksStreak
        context.progressPhotos = data.photos.count
        context.ecgs = await store.ecgRecords(limit: 1000).count
        context.bodyScans = await store.values(.bodyFat, from: .distantPast).count
        if let target = data.profile.targetWeightKg, let latest = fitness.latestWeight?.kg {
            switch data.profile.goal {
            case .lose: context.reachedTargetWeight = latest <= target
            case .gain: context.reachedTargetWeight = latest >= target
            case .maintain: context.reachedTargetWeight = abs(latest - target) <= 1
            }
        }
        achievementContext = context
        let earned = Set(Achievement.all.filter { $0.progress(context) >= 1 }.map(\.id))
        let fresh = fitness.recordAchievements(earned)
        if !fresh.isEmpty { note("achievements earned: \(fresh.joined(separator: ", "))") }
    }

    private var pimSyncing = false
    private var lastPimSync: Date?

    /// Contacts and calendar to the watch. On every reconnect this ran in
    /// full, competing with the health backlog; now a reconnect refreshes
    /// them at most hourly, and the button always does.
    func resync(force: Bool = true) async {
        client.sendTimeSync()
        if pimSyncing { return }
        if !force, let last = lastPimSync, Date().timeIntervalSince(last) < 3600 { return }
        pimSyncing = true
        defer { pimSyncing = false }
        lastPimSync = Date()
        Breadcrumbs.drop("syncing contacts")
        await pim.syncContacts(using: client)
        Breadcrumbs.drop("syncing calendar")
        await pim.syncCalendar(using: client)
        Breadcrumbs.drop("PIM sync done")
    }

    private func handle(type: MessageType, payload: Data) async {
        switch type {
        case .healthBatch:
            guard let batch = BridgeCoder.decode(HealthBatch.self, from: payload) else {
                note("health batch could not be decoded")
                Breadcrumbs.drop("health batch could NOT be decoded (\(payload.count) bytes)")
                return
            }
            Breadcrumbs.drop("health batch of \(batch.samples.count), storing")
            do {
                let fresh = try await store.insert(batch.samples)
                client.ack(cursor: batch.cursor)
                note("stored \(fresh) new of \(batch.samples.count) samples, acked \(batch.cursor)")
                Breadcrumbs.drop("health: stored \(fresh) new of \(batch.samples.count), acked row \(batch.cursor)")
            } catch {
                note("could not store batch \(batch.cursor): \(error.localizedDescription); left on the watch")
                Breadcrumbs.drop("health: store FAILED: \(error.localizedDescription)")
                return
            }
            var fillers: [HealthSample] = []
            do {
                fillers = try await store.fillGaps(batch.dayTotals)
                for filler in fillers {
                    Breadcrumbs.drop("health: filled \(Int(filler.value)) \(filler.metric.rawValue) the watch counted today")
                }
            } catch {
                Breadcrumbs.drop("health: gap fill FAILED: \(error.localizedDescription)")
            }
            if health.authorized {
                _ = await health.write(batch: HealthBatch(samples: batch.samples + fillers, cursor: batch.cursor))
            }
            await dashboard.refresh()

        case .workout:
            guard let workout = BridgeCoder.decode(WorkoutSummary.self, from: payload) else { return }
            do {
                try await store.insert(workout: workout)
                client.send(.workoutAck, payload: Data(workout.uid.utf8))
                note("workout \(workout.type) saved")
                Breadcrumbs.drop("workout \(workout.type) stored and confirmed")
            } catch {
                note("workout save failed: \(error.localizedDescription)")
            }
            if health.authorized {
                _ = await health.write(workout: workout)
            }
            await dashboard.refresh()

        case .ecg:
            guard let record = BridgeCoder.decode(EcgRecord.self, from: payload) else {
                note("ECG could not be decoded")
                return
            }
            do {
                try await store.insert(ecg: record)
                client.send(.workoutAck, payload: Data(record.uid.utf8))
                note("ECG saved, \(record.rhythm)")
            } catch {
                note("ECG save failed: \(error.localizedDescription)")
            }
            await dashboard.refresh()

        case .hello:
            guard let hello = BridgeCoder.decode(Hello.self, from: payload) else { return }
            note("watch: \(hello.model), caps \(hello.capabilities.joined(separator: ","))")
            Breadcrumbs.drop("hello from the watch, pushing config")
            // The watch just (re)connected: push config and a fresh PIM copy.
            pushHealthConfig()
            await resync(force: false)

        case .syncRequest:
            await resync()

        case .callState:
            if let call = BridgeCoder.decode(CallStateDTO.self, from: payload) {
                note("call \(call.state) \(call.caller ?? "")")
            }

        case .log:
            if let text = String(data: payload, encoding: .utf8) {
                WatchTrail.merge(text)
            }

        case .telemetry:
            if let telemetry = BridgeCoder.decode(Telemetry.self, from: payload) {
                note("watch battery \(telemetry.watchBatteryPct ?? -1)%, queued \(telemetry.queuedHealthRows)")
                Breadcrumbs.drop("watch: battery \(telemetry.watchBatteryPct ?? -1)%, \(telemetry.queuedHealthRows) health rows queued")
            }

        default:
            break
        }
    }

    // MARK: - Watch settings

    /// The watch settings, kept on this iPhone so a reconnect restores them.
    struct WatchSettings: Codable, Equatable {
        var enabled: [Metric] = Metric.allCases
        var flushMinutes: Int = 5
        var continuousHeartRate = false
        var sleepStages = true
    }

    var watchSettings: WatchSettings {
        get {
            guard let data = UserDefaults.standard.data(forKey: "watch.settings"),
                  var saved = try? JSONDecoder().decode(WatchSettings.self, from: data)
            else { return WatchSettings() }
            // Metrics added in an update start switched on.
            let known = Set(UserDefaults.standard.stringArray(forKey: "watch.knownMetrics") ?? [])
            for metric in Metric.allCases where !known.isEmpty && !known.contains(metric.rawValue) {
                if !saved.enabled.contains(metric) { saved.enabled.append(metric) }
            }
            return saved
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "watch.settings")
                UserDefaults.standard.set(Metric.allCases.map(\.rawValue), forKey: "watch.knownMetrics")
            }
        }
    }

    /// Sends the settings, plus the body profile the watch's body composition
    /// sensor needs (height, weight, sex and age from Fitness).
    func pushHealthConfig() {
        let settings = watchSettings
        let profile = fitness.data.profile
        let weight = fitness.latestWeight?.kg
        client.sendHealthConfig(
            HealthConfig(
                enabled: settings.enabled,
                flushInterval: settings.flushMinutes * 60,
                continuousHeartRate: settings.continuousHeartRate,
                profile: weight.map {
                    WatchBodyProfile(
                        heightCm: profile.heightCm,
                        weightKg: $0,
                        sex: profile.sex.rawValue,
                        age: Int(Profile.age)
                    )
                },
                sleepStages: settings.sleepStages
            )
        )
    }

    private func note(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        events.insert("\(stamp)  \(message)", at: 0)
        if events.count > 200 { events.removeLast() }
        log.info("\(message, privacy: .public)")
    }
}
