import Foundation

/// How training is going, from the load the watch works out for each session:
/// the last 7 days against the weekly average of the last 28 (the acute to
/// chronic ratio coaches use), hours still needed to recover, and the latest
/// VO2max estimate.
struct TrainingStatus: Sendable, Equatable {
    /// TRIMP of the last 7 days.
    let acute: Double
    /// Average weekly TRIMP over the last 28 days.
    let chronic: Double
    /// Hours until the last sessions are recovered from; 0 when fresh.
    let recoveryLeftHours: Int
    /// Latest VO2max estimate, ml/kg/min.
    let vo2Max: Double?

    var ratio: Double? { chronic > 0 ? acute / chronic : nil }

    /// Plain words for the ratio.
    var label: String {
        guard let ratio else { return acute > 0 ? "Building up" : "No training yet" }
        switch ratio {
        case ..<0.8: return "Low"
        case ..<1.3: return "Optimal"
        case ..<1.5: return "High"
        default: return "Very high"
        }
    }

    static func compute(_ workouts: [WorkoutSummary], now: Date = Date()) -> TrainingStatus? {
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        let week: Int64 = 7 * 86_400_000
        let loaded = workouts.filter { ($0.trainingLoad ?? 0) > 0 }
        let vo2 = workouts.filter { $0.vo2Max != nil }.max { $0.end < $1.end }?.vo2Max
        guard !loaded.isEmpty || vo2 != nil else { return nil }
        let acute = loaded.filter { ms - $0.end < week }.reduce(0) { $0 + ($1.trainingLoad ?? 0) }
        let month = loaded.filter { ms - $0.end < 4 * week }
        let chronic = month.reduce(0) { $0 + ($1.trainingLoad ?? 0) } / 4
        // Recovery overlaps: what is left is the latest finish time of any session.
        let left = loaded.compactMap { w -> Int? in
            guard let hours = w.recoveryHours else { return nil }
            let ready = w.end + Int64(hours) * 3_600_000
            return ready > ms ? Int((ready - ms) / 3_600_000) : nil
        }.max() ?? 0
        return TrainingStatus(acute: acute, chronic: chronic, recoveryLeftHours: left, vo2Max: vo2)
    }

    /// What a VO2max means for a typical adult, in plain words.
    static func fitnessLabel(_ vo2: Double) -> String {
        switch vo2 {
        case ..<30: return "Below average"
        case ..<38: return "Average"
        case ..<46: return "Above average"
        case ..<54: return "High"
        default: return "Excellent"
        }
    }
}

/// What last night says beyond sleep: skin temperature and resting pulse
/// against their usual level, and blood oxygen with its drops below 90 %.
struct NightSignals: Sendable, Equatable {
    /// Last night's skin temperature minus the 14-night average, °C.
    let skinDelta: Double?
    /// This morning's resting pulse minus the usual one, bpm.
    let restingDelta: Double?
    /// Lowest blood oxygen last night, as a fraction.
    let oxygenMin: Double?
    /// Oxygen readings below 90 % last night.
    let oxygenDrops: Int

    /// Both up together for a night is the classic sign of the body fighting
    /// something off, often a day before feeling ill.
    var mayBeIll: Bool { (skinDelta ?? 0) >= 0.5 && (restingDelta ?? 0) >= 4 }
}
