import Foundation
@preconcurrency import HealthKit
import os

/// Writes the watch's measurements into HealthKit.
///
/// Two rules shape this file. First, Apple does not allow writing data the app
/// did not actually measure, so every sample carries the watch as its source
/// device and nothing is synthesised or interpolated. Second, a batch can be
/// delivered twice after a reconnect, so each sample carries a deterministic
/// uid from the watch and is recorded in `writtenUIDs` before the ACK; a
/// duplicate batch is then a no-op rather than a doubled step count.
@MainActor
final class HealthBridge: ObservableObject {

    @Published private(set) var authorized = false
    @Published private(set) var lastWriteAt: Date?
    @Published private(set) var samplesWritten = 0
    @Published private(set) var lastError: String?
    /// The signed app has no HealthKit entitlement, so iOS never lists it in
    /// Health and no permission sheet can appear.
    @Published private(set) var missingEntitlement = false

    private let store = HKHealthStore()
    private let log = Logger(subsystem: "dev.galaxybridge.companion", category: "health")
    private let defaults = UserDefaults.standard

    /// Bounded set of uids already written, persisted across launches.
    private var writtenUIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "writtenUIDs") ?? []) }
        set {
            // Keep the newest 5000; older samples can no longer arrive twice
            // because the watch deletes acknowledged rows.
            let trimmed = Array(newValue.suffix(5000))
            defaults.set(trimmed, forKey: "writtenUIDs")
        }
    }

    private static let device = HKDevice(
        name: "Galaxy Watch",
        manufacturer: "Samsung",
        model: "Galaxy Watch8",
        hardwareVersion: nil,
        firmwareVersion: nil,
        softwareVersion: nil,
        localIdentifier: "galaxybridge",
        udiDeviceIdentifier: nil
    )

    var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [
            HKQuantityType(.stepCount),
            HKQuantityType(.heartRate),
            HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.distanceWalkingRunning),
            HKQuantityType(.flightsClimbed),
            HKQuantityType(.oxygenSaturation),
            HKQuantityType(.restingHeartRate),
            HKQuantityType(.heartRateVariabilitySDNN),
            HKQuantityType(.bodyFatPercentage),
            HKQuantityType(.respiratoryRate),
            HKObjectType.workoutType(),
        ]
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleep)
        }
        return types
    }

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastError = "Health data is not available on this device"
            return
        }
        do {
            // Read access covers the same types the watch writes, for two
            // reasons: deduplicating against what is already in Health, and
            // showing the dashboard. The dashboard deliberately reads back from
            // HealthKit instead of keeping a private copy, so what it displays
            // is what actually landed. Nothing is read beyond these types.
            let readTypes = Set(shareTypes.map { $0 as HKObjectType })
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            authorized = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            if error.localizedDescription.lowercased().contains("entitlement") {
                missingEntitlement = true
            }
            log.error("authorization failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Writes a batch and returns true when the watch may delete those rows.
    func write(batch: HealthBatch) async -> Bool {
        guard authorized else {
            // Not acknowledged on purpose: the watch's spool is the only copy
            // of this data until Apple Health has really taken it.
            lastError = "Apple Health is not authorised, so nothing can be saved. A sideloaded build needs the HealthKit entitlement for this to work."
            return false
        }
        var objects: [HKObject] = []
        var newUIDs: Set<String> = []
        let alreadyWritten = writtenUIDs

        for sample in batch.samples where !alreadyWritten.contains(sample.uid) {
            guard let object = makeSample(sample) else { continue }
            objects.append(object)
            newUIDs.insert(sample.uid)
        }

        guard !objects.isEmpty else {
            // Nothing new: still ACK, otherwise the watch retries forever.
            return true
        }

        do {
            try await store.save(objects)
            writtenUIDs = alreadyWritten.union(newUIDs)
            samplesWritten += objects.count
            lastWriteAt = Date()
            lastError = nil
            log.info("wrote \(objects.count, privacy: .public) samples to HealthKit")
            return true
        } catch {
            lastError = error.localizedDescription
            log.error("HealthKit save failed: \(error.localizedDescription, privacy: .public)")
            // Do not ACK: the spool on the watch keeps the data for the retry.
            return false
        }
    }

    func write(workout: WorkoutSummary) async -> Bool {
        guard authorized else { return false }
        // Same dedup as samples, so copying the history twice is harmless.
        if writtenUIDs.contains(workout.uid) { return true }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = Self.activityType(for: workout.type)
        configuration.locationType = workout.route?.isEmpty == false ? .outdoor : .unknown

        let start = Date(timeIntervalSince1970: Double(workout.start) / 1000)
        let end = Date(timeIntervalSince1970: Double(workout.end) / 1000)

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: Self.device)
        do {
            try await builder.beginCollection(at: start)

            var samples: [HKSample] = []
            if workout.activeEnergyKcal > 0 {
                samples.append(
                    HKQuantitySample(
                        type: HKQuantityType(.activeEnergyBurned),
                        quantity: HKQuantity(unit: .kilocalorie(), doubleValue: workout.activeEnergyKcal),
                        start: start,
                        end: end,
                        device: Self.device,
                        metadata: metadata(uid: workout.uid)
                    )
                )
            }
            if workout.distanceMeters > 0 {
                samples.append(
                    HKQuantitySample(
                        // Cycling distance is its own type; a ride filed as
                        // walking-running distance inflated the step-based
                        // totals in Apple Health.
                        type: HKQuantityType(
                            Self.activityType(for: workout.type) == .cycling ? .distanceCycling : .distanceWalkingRunning
                        ),
                        quantity: HKQuantity(unit: .meter(), doubleValue: workout.distanceMeters),
                        start: start,
                        end: end,
                        device: Self.device,
                        metadata: metadata(uid: workout.uid)
                    )
                )
            }
            if !samples.isEmpty {
                try await builder.addSamples(samples)
            }

            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            writtenUIDs = writtenUIDs.union([workout.uid])
            lastWriteAt = Date()
            log.info("wrote workout \(workout.type, privacy: .public)")
            return true
        } catch {
            lastError = error.localizedDescription
            log.error("workout save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Mapping

    private func makeSample(_ sample: HealthSample) -> HKObject? {
        let start = Date(timeIntervalSince1970: Double(sample.start) / 1000)
        let end = Date(timeIntervalSince1970: Double(sample.end) / 1000)
        guard end >= start else { return nil }
        let meta = metadata(uid: sample.uid)

        switch sample.metric {
        case .steps:
            return quantity(.stepCount, unit: .count(), value: sample.value, start: start, end: end, meta: meta)
        case .heartRate:
            return quantity(
                .heartRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                value: sample.value,
                start: start,
                end: end,
                meta: meta
            )
        case .activeEnergy:
            return quantity(
                .activeEnergyBurned,
                unit: .kilocalorie(),
                value: sample.value,
                start: start,
                end: end,
                meta: meta
            )
        case .distance:
            return quantity(
                .distanceWalkingRunning,
                unit: .meter(),
                value: sample.value,
                start: start,
                end: end,
                meta: meta
            )
        case .floors:
            return quantity(.flightsClimbed, unit: .count(), value: sample.value, start: start, end: end, meta: meta)
        case .spo2:
            return quantity(.oxygenSaturation, unit: .percent(), value: sample.value, start: start, end: end, meta: meta)
        case .restingHeartRate:
            return quantity(
                .restingHeartRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                value: sample.value,
                start: start,
                end: end,
                meta: meta
            )
        case .hrv:
            // The watch reports RMSSD; Apple Health's HRV type is SDNN, a
            // different statistic. Copying it across would mislabel it.
            return nil
        case .bodyFat:
            return quantity(.bodyFatPercentage, unit: .percent(), value: sample.value / 100, start: start, end: end, meta: meta)
        case .respiratoryRate:
            return quantity(
                .respiratoryRate,
                unit: HKUnit.count().unitDivided(by: .minute()),
                value: sample.value,
                start: start,
                end: end,
                meta: meta
            )
        case .skinTemperature, .skeletalMuscle, .bodyWater, .bmr:
            // No matching Apple Health type: wrist skin temperature outside
            // sleep, muscle mass and body water have none, and a daily basal
            // rate is not the energy-over-an-interval Apple Health stores.
            return nil
        case .sleep:
            guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
            return HKCategorySample(
                type: type,
                value: Self.sleepValue(for: sample.value),
                start: start,
                end: end,
                device: Self.device,
                metadata: meta
            )
        }
    }

    private func quantity(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        value: Double,
        start: Date,
        end: Date,
        meta: [String: Any]
    ) -> HKQuantitySample {
        HKQuantitySample(
            type: HKQuantityType(identifier),
            quantity: HKQuantity(unit: unit, doubleValue: value),
            start: start,
            end: end,
            device: Self.device,
            metadata: meta
        )
    }

    private func metadata(uid: String) -> [String: Any] {
        [
            HKMetadataKeyExternalUUID: uid,
            HKMetadataKeyWasUserEntered: false,
            "GalaxyBridgeTransport": "BLE",
        ]
    }

    /// Wear OS sleep stage ordinals mapped onto HKCategoryValueSleepAnalysis.
    private static func sleepValue(for stage: Double) -> Int {
        switch Int(stage) {
        case 1: return HKCategoryValueSleepAnalysis.awake.rawValue
        case 2: return HKCategoryValueSleepAnalysis.asleepREM.rawValue
        case 3: return HKCategoryValueSleepAnalysis.asleepCore.rawValue
        case 4: return HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        default: return HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
        }
    }

    private static func activityType(for raw: String) -> HKWorkoutActivityType {
        switch raw.lowercased() {
        case let value where value.contains("run"): return .running
        case let value where value.contains("walk"): return .walking
        case let value where value.contains("bik"), let value where value.contains("cycl"): return .cycling
        case let value where value.contains("hik"): return .hiking
        case let value where value.contains("swim"): return .swimming
        case let value where value.contains("strength"): return .traditionalStrengthTraining
        case let value where value.contains("high_intensity") || value.contains("hiit"):
            return .highIntensityIntervalTraining
        case let value where value.contains("yoga"): return .yoga
        default: return .other
        }
    }
}
