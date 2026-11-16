import Foundation

// MARK: - Gym

enum MuscleGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case chest, back, shoulders, biceps, triceps, legs, glutes, core, fullBody, cardio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chest: return tr("Chest")
        case .back: return tr("Back")
        case .shoulders: return tr("Shoulders")
        case .biceps: return tr("Biceps")
        case .triceps: return tr("Triceps")
        case .legs: return tr("Legs")
        case .glutes: return tr("Glutes")
        case .core: return tr("Core")
        case .fullBody: return tr("Full body")
        case .cardio: return tr("Cardio")
        }
    }
}

struct Exercise: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var muscle: MuscleGroup
    var equipment: String
    var custom = false
    // From the exercise database: how to do it and what it works.
    var level: String?
    var category: String?
    var primary: [String]?
    var secondary: [String]?
    var instructions: [String]?
    var images: [String]?

    var fromDatabase: Bool { id.hasPrefix("db.") }

    /// Library and database names are translated where a translation exists.
    var displayName: String { custom ? name : tr(name) }
}

struct SetEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var weight: Double
    var reps: Int
    var done = false
    /// Warm-up sets count towards nothing: not volume, not records.
    var warmup: Bool?

    var isWarmup: Bool { warmup ?? false }

    /// Epley's estimated one-rep max, the usual way to compare sets with
    /// different weights and reps. Only meaningful up to about 12 reps.
    var estimatedOneRepMax: Double {
        guard reps > 0, weight > 0 else { return 0 }
        return reps == 1 ? weight : weight * (1 + Double(reps) / 30)
    }

    var volume: Double { weight * Double(reps) }
}

struct SessionExercise: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var exerciseID: String
    var sets: [SetEntry]
    var note = ""
}

struct GymSession: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var start: Date
    var end: Date?
    var exercises: [SessionExercise]
    /// From the watch, when it recorded alongside.
    var avgHeartRate: Double?
    var maxHeartRate: Double?
    var energyKcal: Double?

    var completedSets: [SetEntry] { exercises.flatMap(\.sets).filter { $0.done && !$0.isWarmup } }
    var volume: Double { completedSets.map(\.volume).reduce(0, +) }
    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
}

struct RoutineItem: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var exerciseID: String
    var sets: Int
    var reps: Int
}

struct Routine: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var items: [RoutineItem]
}

// MARK: - Nutrition

enum Meal: String, Codable, CaseIterable, Identifiable, Sendable {
    case breakfast, lunch, dinner, snack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breakfast: return tr("Breakfast")
        case .lunch: return tr("Lunch")
        case .dinner: return tr("Dinner")
        case .snack: return tr("Snacks")
        }
    }

    var systemImage: String {
        switch self {
        case .breakfast: return "sunrise"
        case .lunch: return "sun.max"
        case .dinner: return "moon.stars"
        case .snack: return "carrot"
        }
    }

    /// The meal people usually mean at this time of day.
    static var current: Meal {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11: return .breakfast
        case 11..<16: return .lunch
        case 19..<24: return .dinner
        default: return .snack
        }
    }
}

/// Nutrition per 100 g (or per 100 ml), plus a typical serving.
struct Food: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var kcal: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var serving: Double = 100
    var custom = false
}

struct FoodEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var meal: Meal
    var name: String
    var grams: Double
    var kcal: Double
    var protein: Double
    var carbs: Double
    var fat: Double
}

struct Macros: Sendable {
    var kcal: Double = 0
    var protein: Double = 0
    var carbs: Double = 0
    var fat: Double = 0

    static func + (lhs: Macros, rhs: Macros) -> Macros {
        Macros(
            kcal: lhs.kcal + rhs.kcal,
            protein: lhs.protein + rhs.protein,
            carbs: lhs.carbs + rhs.carbs,
            fat: lhs.fat + rhs.fat
        )
    }
}

// MARK: - Body

struct WeightEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var kg: Double
    var bodyFat: Double?
    var waistCm: Double?
}

enum Sex: String, Codable, CaseIterable, Identifiable, Sendable {
    case male, female
    var id: String { rawValue }
    var title: String { self == .male ? tr("Male") : tr("Female") }
}

enum ActivityLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case sedentary, light, moderate, active, veryActive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sedentary: return tr("Sedentary")
        case .light: return tr("Light (1-3 days/week)")
        case .moderate: return tr("Moderate (3-5 days/week)")
        case .active: return tr("Active (6-7 days/week)")
        case .veryActive: return tr("Very active")
        }
    }

    var factor: Double {
        switch self {
        case .sedentary: return 1.2
        case .light: return 1.375
        case .moderate: return 1.55
        case .active: return 1.725
        case .veryActive: return 1.9
        }
    }
}

enum FitnessGoal: String, Codable, CaseIterable, Identifiable, Sendable {
    case lose, maintain, gain

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lose: return tr("Lose fat")
        case .maintain: return tr("Maintain")
        case .gain: return tr("Build muscle")
        }
    }

    var calorieOffset: Double {
        switch self {
        case .lose: return -500
        case .maintain: return 0
        case .gain: return 300
        }
    }

    var proteinPerKg: Double {
        switch self {
        case .lose: return 2.0
        case .maintain: return 1.6
        case .gain: return 1.8
        }
    }
}

struct BodyProfile: Codable, Hashable, Sendable {
    var sex: Sex = .male
    var heightCm: Double = 175
    var activity: ActivityLevel = .moderate
    var goal: FitnessGoal = .maintain
    var targetWeightKg: Double?
    /// Overrides the computed calorie target when set.
    var customCalories: Double?
    var waterGoalMl: Double = 2500
}

/// Daily targets computed from the profile with the Mifflin-St Jeor equation,
/// the estimate dietitians use most. An estimate, adjustable by hand.
struct NutritionTargets: Sendable {
    var calories: Double
    var protein: Double
    var carbs: Double
    var fat: Double
    var bmr: Double
    var maintenance: Double

    init(profile: BodyProfile, weightKg: Double, age: Double) {
        let base = 10 * weightKg + 6.25 * profile.heightCm - 5 * age
        bmr = base + (profile.sex == .male ? 5 : -161)
        maintenance = bmr * profile.activity.factor
        calories = profile.customCalories ?? max(1200, maintenance + profile.goal.calorieOffset)
        protein = profile.goal.proteinPerKg * weightKg
        fat = calories * 0.25 / 9
        carbs = max(0, (calories - protein * 4 - fat * 9) / 4)
    }
}

// MARK: - Fasting, measurements, photos

struct Fast: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var start: Date
    var end: Date?
    var goalHours: Double

    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
    var reachedGoal: Bool { duration >= goalHours * 3600 }
}

/// Tape measurements in centimetres; any can be left out.
struct BodyMeasurement: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    var neck: Double?
    var chest: Double?
    var arm: Double?
    var waist: Double?
    var hips: Double?
    var thigh: Double?
    var calf: Double?

    nonisolated(unsafe) static let parts: [(key: WritableKeyPath<BodyMeasurement, Double?>, name: String)] = [
        (\.neck, "Neck"), (\.chest, "Chest"), (\.arm, "Arm"), (\.waist, "Waist"),
        (\.hips, "Hips"), (\.thigh, "Thigh"), (\.calf, "Calf"),
    ]
}

struct ProgressPhoto: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var date: Date
    /// File name inside the app's photo folder.
    var file: String
}

// MARK: - Everything persisted

struct FitnessData: Codable, Sendable {
    var customExercises: [Exercise] = []
    var routines: [Routine] = []
    var sessions: [GymSession] = []
    var activeSession: GymSession?
    var customFoods: [Food] = []
    var foodEntries: [FoodEntry] = []
    var weights: [WeightEntry] = []
    /// Millilitres of water per local day, keyed "yyyy-MM-dd".
    var water: [String: Double] = [:]
    var profile = BodyProfile()
    /// Achievement id -> the moment it was first earned.
    var achievements: [String: Date] = [:]
    var restSeconds: Int = 90
    /// Weekday (1 = Sunday, as Calendar counts) to routine id.
    var plan: [String: UUID] = [:]
    var weeklyWorkoutGoal: Int = 3
    var fasts: [Fast] = []
    var measurements: [BodyMeasurement] = []
    var photos: [ProgressPhoto] = []
    var favoriteFoods: [String] = []
    var intervalSessions: Int = 0
    var barWeight: Double = 20

    init() {}

    // Every field is optional on the way in, so data saved by an older build
    // keeps loading after new fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        customExercises = try c.decodeIfPresent([Exercise].self, forKey: .customExercises) ?? []
        routines = try c.decodeIfPresent([Routine].self, forKey: .routines) ?? []
        sessions = try c.decodeIfPresent([GymSession].self, forKey: .sessions) ?? []
        activeSession = try c.decodeIfPresent(GymSession.self, forKey: .activeSession)
        customFoods = try c.decodeIfPresent([Food].self, forKey: .customFoods) ?? []
        foodEntries = try c.decodeIfPresent([FoodEntry].self, forKey: .foodEntries) ?? []
        weights = try c.decodeIfPresent([WeightEntry].self, forKey: .weights) ?? []
        water = try c.decodeIfPresent([String: Double].self, forKey: .water) ?? [:]
        profile = try c.decodeIfPresent(BodyProfile.self, forKey: .profile) ?? BodyProfile()
        achievements = try c.decodeIfPresent([String: Date].self, forKey: .achievements) ?? [:]
        restSeconds = try c.decodeIfPresent(Int.self, forKey: .restSeconds) ?? 90
        plan = try c.decodeIfPresent([String: UUID].self, forKey: .plan) ?? [:]
        weeklyWorkoutGoal = try c.decodeIfPresent(Int.self, forKey: .weeklyWorkoutGoal) ?? 3
        fasts = try c.decodeIfPresent([Fast].self, forKey: .fasts) ?? []
        measurements = try c.decodeIfPresent([BodyMeasurement].self, forKey: .measurements) ?? []
        photos = try c.decodeIfPresent([ProgressPhoto].self, forKey: .photos) ?? []
        favoriteFoods = try c.decodeIfPresent([String].self, forKey: .favoriteFoods) ?? []
        intervalSessions = try c.decodeIfPresent(Int.self, forKey: .intervalSessions) ?? 0
        barWeight = try c.decodeIfPresent(Double.self, forKey: .barWeight) ?? 20
    }
}
