import Foundation
import os

/// Training, nutrition, body and achievements: everything the user records by
/// hand, kept in one JSON file next to the health database.
///
/// The data is small (a few thousand rows over years), so a single file
/// written atomically after every change is simpler and safer than a schema,
/// and a crash can never leave it half-written.
@MainActor
final class FitnessStore: ObservableObject {

    @Published private(set) var data = FitnessData()
    @Published private(set) var lastError: String?

    private let url: URL
    private let log = Logger(subsystem: "dev.galaxybridge.companion", category: "fitness")

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("fitness.json")
        load()
    }

    private func load() {
        guard let raw = try? Data(contentsOf: url) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            data = try decoder.decode(FitnessData.self, from: raw)
        } catch {
            // Keep the unreadable file instead of overwriting it on next save.
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("fitness-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            lastError = "Saved fitness data could not be read; a copy was kept."
            log.error("fitness decode failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func mutate(_ change: (inout FitnessData) -> Void) {
        change(&data)
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let raw = try encoder.encode(data)
            try raw.write(to: url, options: .atomic)
        } catch {
            lastError = error.localizedDescription
            log.error("fitness save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Exercises

    var allExercises: [Exercise] { FitnessLibrary.exercises + data.customExercises + FitnessLibrary.database }

    /// The short list shown by default: the built-in ones and your own.
    var commonExercises: [Exercise] { FitnessLibrary.exercises + data.customExercises }

    func exercise(_ id: String) -> Exercise? {
        allExercises.first { $0.id == id }
    }

    /// Library names are translated; custom ones are shown as typed.
    func exerciseName(_ id: String) -> String {
        guard let exercise = exercise(id) else { return tr("Exercise") }
        return exercise.custom ? exercise.name : tr(exercise.name)
    }

    @discardableResult
    func addCustomExercise(name: String, muscle: MuscleGroup, equipment: String) -> Exercise {
        let exercise = Exercise(
            id: "custom." + UUID().uuidString,
            name: name,
            muscle: muscle,
            equipment: equipment,
            custom: true
        )
        mutate { $0.customExercises.append(exercise) }
        return exercise
    }

    // MARK: - Routines

    func saveRoutine(_ routine: Routine) {
        mutate { data in
            if let index = data.routines.firstIndex(where: { $0.id == routine.id }) {
                data.routines[index] = routine
            } else {
                data.routines.append(routine)
            }
        }
    }

    func deleteRoutine(_ id: UUID) {
        mutate { $0.routines.removeAll { $0.id == id } }
    }

    // MARK: - Sessions

    var activeSession: GymSession? { data.activeSession }

    /// Starts a session, pre-filled from a routine and from the weights used
    /// last time for each exercise, which is what you want to beat.
    func startSession(from routine: Routine?) {
        guard data.activeSession == nil else { return }
        resetWatchTotals()
        let exercises = (routine?.items ?? []).map { item in
            SessionExercise(
                exerciseID: item.exerciseID,
                sets: (0..<max(1, item.sets)).map { _ in
                    SetEntry(
                        weight: suggestion(for: item.exerciseID, targetReps: item.reps)?.weight
                            ?? lastWeight(for: item.exerciseID) ?? 0,
                        reps: item.reps
                    )
                }
            )
        }
        let session = GymSession(name: routine.map { tr($0.name) } ?? tr("Workout"), start: Date(), exercises: exercises)
        mutate { $0.activeSession = session }
    }

    func updateActive(_ change: (inout GymSession) -> Void) {
        guard var session = data.activeSession else { return }
        change(&session)
        mutate { $0.activeSession = session }
    }

    func addExerciseToActive(_ exerciseID: String) {
        updateActive { session in
            session.exercises.append(
                SessionExercise(
                    exerciseID: exerciseID,
                    sets: [SetEntry(weight: lastWeight(for: exerciseID) ?? 0, reps: 10)]
                )
            )
        }
    }

    // Heart rate from the watch during the running session. Kept in memory:
    // persisting every 5-second reading would rewrite the whole history file.
    private var heartSum = 0.0
    private var heartCount = 0
    private var heartMax = 0.0
    private var watchEnergy: Double?

    func noteWatch(_ live: WorkoutLive) {
        guard data.activeSession != nil else { return }
        if live.heartRate > 0 && !live.paused {
            heartSum += Double(live.heartRate)
            heartCount += 1
            heartMax = max(heartMax, Double(live.heartRate))
        }
        if live.energyKcal > 0 { watchEnergy = live.energyKcal }
    }

    private func resetWatchTotals() {
        heartSum = 0
        heartCount = 0
        heartMax = 0
        watchEnergy = nil
    }

    func finishActive() {
        guard var session = data.activeSession else { return }
        session.end = Date()
        if heartCount > 0 {
            session.avgHeartRate = heartSum / Double(heartCount)
            session.maxHeartRate = heartMax
        }
        session.energyKcal = watchEnergy
        resetWatchTotals()
        // Drop sets never marked done and exercises left empty.
        session.exercises = session.exercises.compactMap { exercise in
            var copy = exercise
            copy.sets = exercise.sets.filter(\.done)
            return copy.sets.isEmpty ? nil : copy
        }
        mutate { data in
            data.activeSession = nil
            if !session.exercises.isEmpty {
                data.sessions.insert(session, at: 0)
            }
        }
    }

    func discardActive() {
        resetWatchTotals()
        mutate { $0.activeSession = nil }
    }

    func deleteSession(_ id: UUID) {
        mutate { $0.sessions.removeAll { $0.id == id } }
    }

    func setRestSeconds(_ seconds: Int) {
        mutate { $0.restSeconds = seconds }
    }

    /// Heaviest completed weight on the most recent session with this exercise.
    func lastWeight(for exerciseID: String) -> Double? {
        for session in data.sessions {
            let sets = session.exercises.filter { $0.exerciseID == exerciseID }.flatMap(\.sets).filter { !$0.isWarmup }
            if let best = sets.map(\.weight).max(), best > 0 { return best }
        }
        return nil
    }

    struct ExercisePoint: Identifiable, Sendable {
        let date: Date
        let oneRepMax: Double
        let topWeight: Double
        let volume: Double
        var id: Date { date }
    }

    /// One point per session for an exercise, oldest first.
    func history(for exerciseID: String) -> [ExercisePoint] {
        data.sessions.compactMap { session in
            let sets = session.exercises.filter { $0.exerciseID == exerciseID }.flatMap(\.sets).filter { !$0.isWarmup }
            guard !sets.isEmpty else { return nil }
            return ExercisePoint(
                date: session.start,
                oneRepMax: sets.map(\.estimatedOneRepMax).max() ?? 0,
                topWeight: sets.map(\.weight).max() ?? 0,
                volume: sets.map(\.volume).reduce(0, +)
            )
        }
        .sorted { $0.date < $1.date }
    }

    struct PersonalRecord: Identifiable, Sendable {
        let exerciseID: String
        let name: String
        let oneRepMax: Double
        let weight: Double
        let reps: Int
        let date: Date
        var id: String { exerciseID }
    }

    /// Best estimated one-rep max per exercise.
    var personalRecords: [PersonalRecord] {
        var best: [String: PersonalRecord] = [:]
        for session in data.sessions {
            for exercise in session.exercises {
                for set in exercise.sets where set.weight > 0 && !set.isWarmup {
                    let record = PersonalRecord(
                        exerciseID: exercise.exerciseID,
                        name: exerciseName(exercise.exerciseID),
                        oneRepMax: set.estimatedOneRepMax,
                        weight: set.weight,
                        reps: set.reps,
                        date: session.start
                    )
                    if record.oneRepMax > (best[exercise.exerciseID]?.oneRepMax ?? 0) {
                        best[exercise.exerciseID] = record
                    }
                }
            }
        }
        return best.values.sorted { $0.oneRepMax > $1.oneRepMax }
    }

    /// Completed sets per muscle group over the last 7 days, the usual way to
    /// check a programme is balanced.
    var weeklySetsByMuscle: [(muscle: MuscleGroup, sets: Int)] {
        let since = Date().addingTimeInterval(-7 * 24 * 3600)
        var counts: [MuscleGroup: Int] = [:]
        for session in data.sessions where session.start >= since {
            for exercise in session.exercises {
                let muscle = self.exercise(exercise.exerciseID)?.muscle ?? .fullBody
                counts[muscle, default: 0] += exercise.sets.filter { !$0.isWarmup }.count
            }
        }
        return MuscleGroup.allCases.compactMap { muscle in
            counts[muscle].map { (muscle: muscle, sets: $0) }
        }
    }

    // MARK: - Nutrition

    var allFoods: [Food] { data.customFoods + FitnessLibrary.foods }

    func addCustomFood(_ food: Food) {
        mutate { $0.customFoods.append(food) }
    }

    func log(food: Food, grams: Double, meal: Meal, on day: Date) {
        let factor = grams / 100
        let entry = FoodEntry(
            date: Self.moment(on: day),
            meal: meal,
            name: food.name,
            grams: grams,
            kcal: food.kcal * factor,
            protein: food.protein * factor,
            carbs: food.carbs * factor,
            fat: food.fat * factor
        )
        mutate { $0.foodEntries.append(entry) }
    }

    func quickAdd(name: String, kcal: Double, protein: Double, carbs: Double, fat: Double, meal: Meal, on day: Date) {
        let entry = FoodEntry(
            date: Self.moment(on: day), meal: meal, name: name.isEmpty ? tr("Quick add") : name,
            grams: 0, kcal: kcal, protein: protein, carbs: carbs, fat: fat
        )
        mutate { $0.foodEntries.append(entry) }
    }

    func deleteFood(_ id: UUID) {
        mutate { $0.foodEntries.removeAll { $0.id == id } }
    }

    func entries(on day: Date) -> [FoodEntry] {
        let calendar = Calendar.current
        return data.foodEntries.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }

    func totals(on day: Date) -> Macros {
        entries(on: day).reduce(Macros()) {
            $0 + Macros(kcal: $1.kcal, protein: $1.protein, carbs: $1.carbs, fat: $1.fat)
        }
    }

    /// Recently logged foods, newest first, for one-tap re-logging.
    var recentFoods: [Food] {
        var seen = Set<String>()
        var result: [Food] = []
        for entry in data.foodEntries.reversed() where entry.grams > 0 {
            guard !seen.contains(entry.name),
                  let food = allFoods.first(where: { $0.name == entry.name }) else { continue }
            seen.insert(entry.name)
            result.append(food)
            if result.count == 8 { break }
        }
        return result
    }

    /// A time on `day` for a new entry: now when it is today, midday otherwise.
    private static func moment(on day: Date) -> Date {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return Date() }
        return calendar.startOfDay(for: day).addingTimeInterval(12 * 3600)
    }

    // MARK: - Water

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    func water(on day: Date) -> Double { data.water[Self.dayKey(day)] ?? 0 }

    func addWater(_ ml: Double, on day: Date) {
        let key = Self.dayKey(day)
        mutate { $0.water[key] = max(0, ($0.water[key] ?? 0) + ml) }
    }

    // MARK: - Body

    var latestWeight: WeightEntry? { data.weights.max { $0.date < $1.date } }

    func addWeight(_ entry: WeightEntry) {
        mutate { $0.weights.append(entry) }
    }

    func deleteWeight(_ id: UUID) {
        mutate { $0.weights.removeAll { $0.id == id } }
    }

    func updateProfile(_ change: (inout BodyProfile) -> Void) {
        mutate { change(&$0.profile) }
    }

    var targets: NutritionTargets {
        NutritionTargets(profile: data.profile, weightKg: latestWeight?.kg ?? 70, age: Profile.age)
    }

    var bmi: Double? {
        guard let kg = latestWeight?.kg, data.profile.heightCm > 0 else { return nil }
        let metres = data.profile.heightCm / 100
        return kg / (metres * metres)
    }

    // MARK: - Weekly plan

    /// The routine planned for a weekday (1 = Sunday).
    func plannedRoutine(weekday: Int) -> Routine? {
        guard let id = data.plan[String(weekday)] else { return nil }
        return (data.routines + FitnessLibrary.routines).first { $0.id == id }
    }

    var todaysRoutine: Routine? {
        plannedRoutine(weekday: Calendar.current.component(.weekday, from: Date()))
    }

    func setPlan(weekday: Int, routine: UUID?) {
        mutate { $0.plan[String(weekday)] = routine }
    }

    func setWeeklyWorkoutGoal(_ goal: Int) {
        mutate { $0.weeklyWorkoutGoal = max(1, min(14, goal)) }
    }

    func setBarWeight(_ kg: Double) {
        mutate { $0.barWeight = kg }
    }

    // MARK: - Progression

    struct Suggestion: Sendable {
        let weight: Double
        let reps: Int
        let reason: String
    }

    /// Double progression, the standard way to keep getting stronger: when
    /// every work set reached the target reps last time, add the smallest
    /// sensible jump; otherwise stay and beat the reps.
    func suggestion(for exerciseID: String, targetReps: Int) -> Suggestion? {
        for session in data.sessions {
            let sets = session.exercises.filter { $0.exerciseID == exerciseID }
                .flatMap(\.sets).filter { !$0.isWarmup && $0.weight > 0 }
            guard let top = sets.map(\.weight).max() else { continue }
            let atTop = sets.filter { $0.weight == top }
            if atTop.allSatisfy({ $0.reps >= targetReps }) {
                let step = increment(for: exerciseID)
                return Suggestion(
                    weight: top + step,
                    reps: targetReps,
                    reason: String(format: tr("All sets reached %ld reps last time: add %@ kg"), targetReps, step.formatted())
                )
            }
            let best = atTop.map(\.reps).max() ?? 0
            return Suggestion(
                weight: top,
                reps: min(targetReps, best + 1),
                reason: String(format: tr("Same weight, aim for %ld reps"), min(targetReps, best + 1))
            )
        }
        return nil
    }

    /// Lower body moves take bigger jumps than upper body ones; dumbbells
    /// usually go up 2 kg a pair.
    private func increment(for exerciseID: String) -> Double {
        guard let exercise = exercise(exerciseID) else { return 2.5 }
        if exercise.equipment.lowercased().contains("dumbbell") { return 2 }
        switch exercise.muscle {
        case .legs, .glutes, .back: return 5
        default: return 2.5
        }
    }

    /// Ramp-up sets before a working weight: the empty bar, then about 50%,
    /// 70% and 85%, rounded to what can be loaded.
    static func warmupSets(for work: Double, bar: Double) -> [SetEntry] {
        guard work > bar + 10 else { return [] }
        func round(_ kg: Double) -> Double { (kg / 2.5).rounded() * 2.5 }
        var sets = [SetEntry(weight: bar, reps: 10, warmup: true)]
        for (share, reps) in [(0.5, 5), (0.7, 3), (0.85, 1)] {
            let kg = max(bar, round(work * share))
            if kg > (sets.last?.weight ?? 0) { sets.append(SetEntry(weight: kg, reps: reps, warmup: true)) }
        }
        return sets
    }

    func addWarmups(to sessionExerciseID: UUID) {
        updateActive { session in
            guard let e = session.exercises.firstIndex(where: { $0.id == sessionExerciseID }) else { return }
            let work = session.exercises[e].sets.filter { !$0.isWarmup }.map(\.weight).max() ?? 0
            let ramp = Self.warmupSets(for: work, bar: data.barWeight)
            session.exercises[e].sets.removeAll { $0.isWarmup }
            session.exercises[e].sets.insert(contentsOf: ramp, at: 0)
        }
    }

    /// Plates per side for a barbell total, heaviest first, greedy over the
    /// usual gym set. The remainder is what cannot be loaded exactly.
    static func plates(for total: Double, bar: Double) -> (plates: [Double], remainder: Double) {
        var side = max(0, (total - bar) / 2)
        var result: [Double] = []
        for plate in [25, 20, 15, 10, 5, 2.5, 1.25] {
            while side + 0.0001 >= plate {
                result.append(plate)
                side -= plate
            }
        }
        return (result, side * 2)
    }

    // MARK: - Training statistics

    var trainingDays: Set<Date> {
        let calendar = Calendar.current
        return Set(data.sessions.map { calendar.startOfDay(for: $0.start) })
    }

    struct WeekVolume: Identifiable, Sendable {
        let week: Date
        let volume: Double
        let sessions: Int
        var id: Date { week }
    }

    func weeklyVolume(weeks: Int) -> [WeekVolume] {
        let calendar = Calendar.current
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        return (0..<weeks).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek),
                  let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start) else { return nil }
            let sessions = data.sessions.filter { $0.start >= start && $0.start < end }
            return WeekVolume(week: start, volume: sessions.map(\.volume).reduce(0, +), sessions: sessions.count)
        }
    }

    var workoutsThisWeek: Int { weeklyVolume(weeks: 1).first?.sessions ?? 0 }

    /// Weeks in a row, up to last week, that met the weekly workout goal.
    var goalWeeksStreak: Int {
        let weeks = weeklyVolume(weeks: 52).dropLast()
        var count = 0
        for week in weeks.reversed() {
            if week.sessions >= data.weeklyWorkoutGoal { count += 1 } else { break }
        }
        return count
    }

    func recordIntervalSession() {
        mutate { $0.intervalSessions += 1 }
    }

    // MARK: - Fasting

    var activeFast: Fast? { data.fasts.first { $0.end == nil } }

    func startFast(goalHours: Double, at start: Date = Date()) {
        guard activeFast == nil else { return }
        mutate { $0.fasts.insert(Fast(start: start, goalHours: goalHours), at: 0) }
    }

    func endFast() {
        mutate { data in
            if let index = data.fasts.firstIndex(where: { $0.end == nil }) {
                data.fasts[index].end = Date()
            }
        }
    }

    func deleteFast(_ id: UUID) {
        mutate { $0.fasts.removeAll { $0.id == id } }
    }

    var completedFasts: Int { data.fasts.filter { $0.end != nil && $0.reachedGoal }.count }

    // MARK: - Measurements and photos

    func addMeasurement(_ entry: BodyMeasurement) {
        mutate { $0.measurements.append(entry) }
    }

    func deleteMeasurement(_ id: UUID) {
        mutate { $0.measurements.removeAll { $0.id == id } }
    }

    private var photoFolder: URL {
        let folder = url.deletingLastPathComponent().appendingPathComponent("photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func photoURL(_ photo: ProgressPhoto) -> URL { photoFolder.appendingPathComponent(photo.file) }

    /// Photos stay on this iPhone, in the app's own folder, never in the
    /// camera roll unless the user saves them there.
    func addPhoto(_ jpeg: Data, date: Date = Date()) {
        let name = UUID().uuidString + ".jpg"
        do {
            try jpeg.write(to: photoFolder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
            mutate { $0.photos.insert(ProgressPhoto(date: date, file: name), at: 0) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deletePhoto(_ photo: ProgressPhoto) {
        try? FileManager.default.removeItem(at: photoURL(photo))
        mutate { $0.photos.removeAll { $0.id == photo.id } }
    }

    // MARK: - Food favourites and copying

    func isFavorite(_ name: String) -> Bool { data.favoriteFoods.contains(name) }

    func toggleFavorite(_ name: String) {
        mutate { data in
            if let index = data.favoriteFoods.firstIndex(of: name) {
                data.favoriteFoods.remove(at: index)
            } else {
                data.favoriteFoods.append(name)
            }
        }
    }

    var favoriteFoods: [Food] {
        data.favoriteFoods.compactMap { name in allFoods.first { $0.name == name } }
    }

    /// Logs again everything eaten at `meal` on `from`, onto `to`.
    @discardableResult
    func copyMeal(_ meal: Meal, from: Date, to: Date) -> Int {
        let source = entries(on: from).filter { $0.meal == meal }
        guard !source.isEmpty else { return 0 }
        let moment = Self.moment(on: to)
        mutate { data in
            for entry in source {
                var copy = entry
                copy.id = UUID()
                copy.date = moment
                data.foodEntries.append(copy)
            }
        }
        return source.count
    }

    // MARK: - Achievements

    /// Records the first time each achievement is met, and returns the ones
    /// that are new so the screen can celebrate them.
    @discardableResult
    func recordAchievements(_ earned: Set<String>) -> [String] {
        let fresh = earned.subtracting(data.achievements.keys)
        guard !fresh.isEmpty else { return [] }
        mutate { data in
            for id in fresh { data.achievements[id] = Date() }
        }
        return Array(fresh)
    }

    // MARK: - Streaks used by achievements

    /// Days in a row, ending today or yesterday, with at least one food entry.
    var foodLoggingStreak: Int {
        let calendar = Calendar.current
        let days = Set(data.foodEntries.map { calendar.startOfDay(for: $0.date) })
        return Self.streak(in: days)
    }

    var waterGoalDays: Int {
        data.water.values.filter { $0 >= data.profile.waterGoalMl }.count
    }

    static func streak(in days: Set<Date>) -> Int {
        let calendar = Calendar.current
        var cursor = calendar.startOfDay(for: Date())
        if !days.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let before = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = before
        }
        return count
    }
}
