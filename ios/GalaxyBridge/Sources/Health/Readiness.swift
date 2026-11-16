import Foundation

/// A night of sleep, scored the way sleep trackers usually do: mostly how long,
/// then how much of it was deep and REM, and how broken it was.
struct SleepScore: Sendable, Equatable {
    let total: Int
    let duration: Int
    let deep: Int
    let rem: Int
    let continuity: Int

    /// - Parameters:
    ///   - asleep: seconds asleep.
    ///   - deep, rem: seconds in each stage, or nil when the night has no stages.
    ///   - awakenings: wake-ups after first falling asleep.
    init(asleep: TimeInterval, deep: TimeInterval?, rem: TimeInterval?, awakenings: Int) {
        let hours = asleep / 3600
        // Full marks from 7 to 9 hours, sloping off either side.
        let durationShare: Double
        switch hours {
        case ..<4: durationShare = max(0, hours / 4 * 0.4)
        case ..<7: durationShare = 0.4 + (hours - 4) / 3 * 0.6
        case ...9: durationShare = 1
        default: durationShare = max(0.6, 1 - (hours - 9) * 0.2)
        }
        duration = Int((durationShare * 50).rounded())

        if let deep, let rem, asleep > 0 {
            // Adults typically spend 15-25% in deep and 20-25% in REM.
            self.deep = Int((min(1, deep / asleep / 0.15) * 20).rounded())
            self.rem = Int((min(1, rem / asleep / 0.20) * 20).rounded())
        } else {
            // No stages: score the stage part on duration alone.
            self.deep = Int((durationShare * 20).rounded())
            self.rem = Int((durationShare * 20).rounded())
        }
        continuity = max(0, 10 - awakenings * 2)
        total = min(100, duration + self.deep + self.rem + continuity)
    }
}

/// How ready the body is today, in the spirit of Samsung's Energy Score and
/// Garmin's Body Battery: last night's sleep, HRV and resting heart rate
/// against the wearer's own 30-day baseline, and yesterday's activity.
struct Readiness: Sendable, Equatable {
    struct Part: Sendable, Equatable, Identifiable {
        let id: String
        let title: String
        let score: Int
        let detail: String
    }

    let score: Int
    let parts: [Part]

    var label: String {
        switch score {
        case 85...: return "Excellent"
        case 70..<85: return "Good"
        case 50..<70: return "Fair"
        default: return "Low"
        }
    }

    /// Needs at least sleep or HRV; returns nil when there is too little to
    /// say anything.
    static func compute(
        sleep: SleepScore?,
        hrvToday: Double?,
        hrvBaseline: Double?,
        restingToday: Double?,
        restingBaseline: Double?,
        stepsYesterday: Double?,
        stepGoal: Double
    ) -> Readiness? {
        var parts: [(Part, Double)] = []

        if let sleep {
            parts.append((Part(id: "sleep", title: "Sleep", score: sleep.total, detail: String(format: tr("Sleep score %ld"), sleep.total)), 0.35))
        }
        if let today = hrvToday, let base = hrvBaseline, base > 0 {
            // At baseline is 75; each 10% above or below moves it 12 points.
            let ratio = today / base
            let score = clamp(75 + (ratio - 1) * 120)
            let change = Int(((ratio - 1) * 100).rounded())
            parts.append((Part(id: "hrv", title: "HRV", score: score, detail: String(format: tr("%@%% vs your usual"), signed(change))), 0.25))
        }
        if let today = restingToday, let base = restingBaseline, base > 0 {
            // Each bpm above usual costs 6 points; below usual is a good sign.
            let delta = today - base
            let score = clamp(80 - delta * 6)
            parts.append((Part(id: "resting", title: "Resting heart rate", score: score, detail: String(format: tr("%@ bpm vs your usual"), signed(Int(delta.rounded())))), 0.25))
        }
        if let steps = stepsYesterday, stepGoal > 0 {
            // Near the goal is balanced; far above it asks for recovery, far
            // below it is under-recovery's opposite and costs little.
            let ratio = steps / stepGoal
            let score: Int
            switch ratio {
            case ..<0.5: score = 70
            case ..<1.5: score = 90
            case ..<2.5: score = 70
            default: score = 50
            }
            parts.append((Part(id: "activity", title: "Yesterday's activity", score: score, detail: String(format: tr("%ld steps"), Int(steps))), 0.15))
        }

        guard parts.contains(where: { $0.0.id == "sleep" || $0.0.id == "hrv" }) else { return nil }
        let weight = parts.map(\.1).reduce(0, +)
        let total = parts.map { Double($0.0.score) * $0.1 }.reduce(0, +) / weight
        return Readiness(score: Int(total.rounded()), parts: parts.map(\.0))
    }

    private static func clamp(_ value: Double) -> Int { Int(min(100, max(0, value)).rounded()) }
    private static func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
}

/// Stress from HRV, the way watches derive it: HRV well below the wearer's
/// own baseline means a sympathetic (stressed) state. 0 calm, 100 very high.
enum StressLevel {
    static func score(hrv: Double, baseline: Double) -> Int? {
        guard baseline > 0 else { return nil }
        let ratio = hrv / baseline
        return Int(min(100, max(0, (1.2 - ratio) / 0.8 * 100)).rounded())
    }

    static func label(_ score: Int) -> String {
        switch score {
        case ..<25: return "Calm"
        case ..<50: return "Normal"
        case ..<75: return "Elevated"
        default: return "High"
        }
    }
}
