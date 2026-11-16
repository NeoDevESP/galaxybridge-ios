import Foundation

/// Everything an achievement can be judged on, gathered once per refresh.
struct AchievementContext: Sendable {
    var bestDaySteps: Double = 0
    var totalSteps: Double = 0
    var totalDistanceKm: Double = 0
    var longestStepStreak = 0
    var currentStepStreak = 0
    var daysWithData = 0
    var watchWorkouts = 0
    var sleepNights = 0
    var gymSessions = 0
    var gymVolumeKg: Double = 0
    var personalRecords = 0
    var foodLoggingStreak = 0
    var waterGoalDays = 0
    var weighIns = 0
    var reachedTargetWeight = false
    var fasts = 0
    var intervalSessions = 0
    var goalWeeks = 0
    var progressPhotos = 0
    var ecgs = 0
    var bodyScans = 0
}

struct Achievement: Identifiable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case steps = "Steps"
        case distance = "Distance"
        case consistency = "Consistency"
        case gym = "Gym"
        case nutrition = "Nutrition"
        case body = "Body"
    }

    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let category: Category
    /// Progress from 0 to 1; 1 means earned.
    let progress: @Sendable (AchievementContext) -> Double

    static func ratio(_ value: Double, _ target: Double) -> Double { min(1, value / target) }

    static let all: [Achievement] = {
        var list: [Achievement] = []

        for (steps, name) in [(10_000.0, "10K day"), (15_000, "15K day"), (20_000, "20K day"), (30_000, "30K day")] {
            list.append(Achievement(
                id: "steps.day.\(Int(steps))", title: name,
                detail: "Walk \(Int(steps).formatted()) steps in one day",
                systemImage: "figure.walk", category: .steps,
                progress: { Achievement.ratio($0.bestDaySteps, steps) }
            ))
        }
        for (steps, name) in [(100_000.0, "100K club"), (500_000, "Half a million"), (1_000_000, "Millionaire"), (5_000_000, "Five million")] {
            list.append(Achievement(
                id: "steps.total.\(Int(steps))", title: name,
                detail: "\(Int(steps).formatted()) steps in total",
                systemImage: "shoeprints.fill", category: .steps,
                progress: { Achievement.ratio($0.totalSteps, steps) }
            ))
        }
        for (km, name) in [(42.2, "Marathon"), (100, "Century"), (500, "Long road"), (1_000, "Thousand kilometres")] {
            list.append(Achievement(
                id: "distance.\(Int(km))", title: name,
                detail: "Cover \(km.formatted()) km in total",
                systemImage: "map.fill", category: .distance,
                progress: { Achievement.ratio($0.totalDistanceKm, km) }
            ))
        }
        for days in [3, 7, 14, 30, 100] {
            list.append(Achievement(
                id: "streak.\(days)", title: "\(days)-day streak",
                detail: "Hit your step goal \(days) days in a row",
                systemImage: "flame.fill", category: .consistency,
                progress: { Achievement.ratio(Double($0.longestStepStreak), Double(days)) }
            ))
        }
        list.append(Achievement(
            id: "nights.7", title: "Sleep tracker", detail: "Record 7 nights of sleep",
            systemImage: "bed.double.fill", category: .consistency,
            progress: { Achievement.ratio(Double($0.sleepNights), 7) }
        ))
        list.append(Achievement(
            id: "data.30", title: "Always on", detail: "30 days with data from the watch",
            systemImage: "applewatch", category: .consistency,
            progress: { Achievement.ratio(Double($0.daysWithData), 30) }
        ))
        for (count, name) in [(1, "First rep"), (10, "Regular"), (50, "Committed"), (100, "Iron century"), (250, "Gym rat")] {
            list.append(Achievement(
                id: "gym.\(count)", title: name,
                detail: count == 1 ? "Log your first gym session" : "Log \(count) gym sessions",
                systemImage: "dumbbell.fill", category: .gym,
                progress: { Achievement.ratio(Double($0.gymSessions), Double(count)) }
            ))
        }
        for (tons, name) in [(10.0, "10 tonnes"), (100, "100 tonnes"), (1_000, "Atlas")] {
            list.append(Achievement(
                id: "volume.\(Int(tons))", title: name,
                detail: "Lift \(Int(tons)) tonnes in total",
                systemImage: "scalemass.fill", category: .gym,
                progress: { Achievement.ratio($0.gymVolumeKg / 1000, tons) }
            ))
        }
        list.append(Achievement(
            id: "pr.10", title: "Record breaker", detail: "Set records on 10 different exercises",
            systemImage: "trophy.fill", category: .gym,
            progress: { Achievement.ratio(Double($0.personalRecords), 10) }
        ))
        for (count, name) in [(1, "Cardio start"), (25, "Endurance")] {
            list.append(Achievement(
                id: "workout.\(count)", title: name,
                detail: count == 1 ? "Record a workout on the watch" : "Record \(count) workouts on the watch",
                systemImage: "figure.run", category: .gym,
                progress: { Achievement.ratio(Double($0.watchWorkouts), Double(count)) }
            ))
        }
        for days in [3, 7, 30] {
            list.append(Achievement(
                id: "food.\(days)", title: "Food diary \(days)",
                detail: "Log what you eat \(days) days in a row",
                systemImage: "fork.knife", category: .nutrition,
                progress: { Achievement.ratio(Double($0.foodLoggingStreak), Double(days)) }
            ))
        }
        for days in [1, 7, 30] {
            list.append(Achievement(
                id: "water.\(days)", title: days == 1 ? "Hydrated" : "Hydrated \(days)",
                detail: days == 1 ? "Reach your water goal" : "Reach your water goal on \(days) days",
                systemImage: "drop.fill", category: .nutrition,
                progress: { Achievement.ratio(Double($0.waterGoalDays), Double(days)) }
            ))
        }
        list.append(Achievement(
            id: "weigh.10", title: "On the scale", detail: "Log your weight 10 times",
            systemImage: "scalemass", category: .body,
            progress: { Achievement.ratio(Double($0.weighIns), 10) }
        ))
        list.append(Achievement(
            id: "weight.target", title: "Goal weight", detail: "Reach your target weight",
            systemImage: "target", category: .body,
            progress: { $0.reachedTargetWeight ? 1 : 0 }
        ))
        for (count, name) in [(1, "First fast"), (10, "Fasting habit"), (50, "Fasting master")] {
            list.append(Achievement(
                id: "fast.\(count)", title: name,
                detail: count == 1 ? "Complete a fast" : "Complete \(count) fasts",
                systemImage: "hourglass", category: .nutrition,
                progress: { Achievement.ratio(Double($0.fasts), Double(count)) }
            ))
        }
        for (count, name) in [(1, "Interval starter"), (25, "Interval machine")] {
            list.append(Achievement(
                id: "intervals.\(count)", title: name,
                detail: count == 1 ? "Finish an interval workout" : "Finish \(count) interval workouts",
                systemImage: "timer", category: .gym,
                progress: { Achievement.ratio(Double($0.intervalSessions), Double(count)) }
            ))
        }
        for (weeks, name) in [(4, "On plan for a month"), (12, "On plan for a quarter")] {
            list.append(Achievement(
                id: "plan.weeks.\(weeks)", title: name,
                detail: "Meet your weekly workout goal \(weeks) weeks in a row",
                systemImage: "calendar.badge.checkmark", category: .consistency,
                progress: { Achievement.ratio(Double($0.goalWeeks), Double(weeks)) }
            ))
        }
        list.append(Achievement(
            id: "photos.5", title: "Before and after", detail: "Take 5 progress photos",
            systemImage: "camera.fill", category: .body,
            progress: { Achievement.ratio(Double($0.progressPhotos), 5) }
        ))
        list.append(Achievement(
            id: "ecg.1", title: "Heart check", detail: "Record an ECG on the watch",
            systemImage: "waveform.path.ecg", category: .body,
            progress: { Achievement.ratio(Double($0.ecgs), 1) }
        ))
        list.append(Achievement(
            id: "body.5", title: "Know your body", detail: "Measure body composition 5 times",
            systemImage: "figure.arms.open", category: .body,
            progress: { Achievement.ratio(Double($0.bodyScans), 5) }
        ))
        return list
    }()
}

extension Achievement {
    var localizedTitle: String { trNumbers(title) }
    var localizedDetail: String { trNumbers(detail) }
}
