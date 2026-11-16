import Foundation

/// Every chartable measurement, mapped onto the wire metric it is built from.
enum HealthKind: String, Identifiable, Hashable, CaseIterable, Sendable {
    case steps, energy, distance, floors, heartRate, restingHeartRate, hrv, spo2
    case respiratoryRate, skinTemperature, bodyFat, skeletalMuscle, bodyWater, bmr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .steps: return tr("Steps")
        case .energy: return tr("Active energy")
        case .distance: return tr("Distance")
        case .floors: return tr("Floors climbed")
        case .heartRate: return tr("Heart rate")
        case .restingHeartRate: return tr("Resting heart rate")
        case .hrv: return tr("Heart rate variability")
        case .spo2: return tr("Blood oxygen")
        case .respiratoryRate: return tr("Respiratory rate")
        case .skinTemperature: return tr("Skin temperature")
        case .bodyFat: return tr("Body fat")
        case .skeletalMuscle: return tr("Skeletal muscle")
        case .bodyWater: return tr("Body water")
        case .bmr: return tr("Basal metabolic rate")
        }
    }

    var unit: String {
        switch self {
        case .steps, .floors: return ""
        case .energy: return "kcal"
        case .distance: return "km"
        case .heartRate, .restingHeartRate: return "bpm"
        case .hrv: return "ms"
        case .spo2, .bodyFat: return "%"
        case .respiratoryRate: return "br/min"
        case .skinTemperature: return "°C"
        case .skeletalMuscle, .bodyWater: return "kg"
        case .bmr: return "kcal"
        }
    }

    var systemImage: String {
        switch self {
        case .steps: return "figure.walk"
        case .energy: return "flame.fill"
        case .distance: return "location.fill"
        case .floors: return "stairs"
        case .heartRate: return "heart.fill"
        case .restingHeartRate: return "heart.text.square"
        case .hrv: return "waveform.path.ecg"
        case .spo2: return "drop.fill"
        case .respiratoryRate: return "lungs.fill"
        case .skinTemperature: return "thermometer.medium"
        case .bodyFat: return "figure.arms.open"
        case .skeletalMuscle: return "figure.strengthtraining.functional"
        case .bodyWater: return "drop.circle.fill"
        case .bmr: return "flame.circle.fill"
        }
    }

    /// Resting heart rate is derived on the phone from heart-rate readings;
    /// the watch never sends it as such.
    var metric: Metric {
        switch self {
        case .steps: return .steps
        case .energy: return .activeEnergy
        case .distance: return .distance
        case .floors: return .floors
        case .heartRate, .restingHeartRate: return .heartRate
        case .hrv: return .hrv
        case .spo2: return .spo2
        case .respiratoryRate: return .respiratoryRate
        case .skinTemperature: return .skinTemperature
        case .bodyFat: return .bodyFat
        case .skeletalMuscle: return .skeletalMuscle
        case .bodyWater: return .bodyWater
        case .bmr: return .bmr
        }
    }

    /// Cumulative metrics are summed per day and drawn as bars; sampled ones
    /// are averaged and drawn as a line.
    var isCumulative: Bool { self != .restingHeartRate && metric.isCumulative }

    /// Converts the stored unit into the one people read.
    func display(_ value: Double) -> Double {
        switch self {
        case .distance: return value / 1000
        case .spo2: return value <= 1 ? value * 100 : value
        default: return value
        }
    }
}

/// The arithmetic behind the derived numbers, kept in one place so every
/// screen agrees on them.
enum HealthMath {

    /// Resting heart rate for one day, estimated from five-minute averages:
    /// the mean of the lowest tenth. This is close to how wearables define it
    /// (the heart at rest, usually asleep) but it is an estimate, and the app
    /// labels it as one. Needs at least an hour of readings.
    static func restingEstimate(fiveMinuteAverages values: [Double]) -> Double? {
        let valid = values.filter { $0 >= 30 && $0 <= 220 }
        guard valid.count >= 12 else { return nil }
        let sorted = valid.sorted()
        let take = max(3, sorted.count / 10)
        let lowest = sorted.prefix(take)
        return lowest.reduce(0, +) / Double(lowest.count)
    }

    struct Zone: Identifiable, Sendable {
        let id: Int
        let name: String
        let lower: Double
        let upper: Double
    }

    /// The five classic zones as fractions of an age-predicted maximum
    /// (208 - 0.7 x age, Tanaka et al.), which fits adults better than 220 - age.
    static func zones(age: Double) -> [Zone] {
        let maximum = 208 - 0.7 * age
        let bounds: [(String, Double, Double)] = [
            ("Warm-up", 0.50, 0.60),
            ("Fat burn", 0.60, 0.70),
            ("Aerobic", 0.70, 0.80),
            ("Threshold", 0.80, 0.90),
            ("Maximum", 0.90, 1.10),
        ]
        return bounds.enumerated().map { index, entry in
            Zone(id: index + 1, name: tr(entry.0), lower: entry.1 * maximum, upper: entry.2 * maximum)
        }
    }

    static func maximumHeartRate(age: Double) -> Double { 208 - 0.7 * age }

    /// Percentage change from `baseline` to `recent`, or nil when there is no
    /// baseline to compare with.
    static func change(_ recent: Double, from baseline: Double) -> Double? {
        guard baseline > 0 else { return nil }
        return (recent - baseline) / baseline * 100
    }
}

/// The user's own numbers, used for heart-rate zones and goals.
enum Profile {
    static var age: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: "profile.age")
            return stored > 0 ? stored : 35
        }
        set { UserDefaults.standard.set(newValue, forKey: "profile.age") }
    }
}
