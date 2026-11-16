import CryptoKit
import Foundation

/// Built-in exercises, foods and routines, so the app is useful before the
/// user has typed anything.
enum FitnessLibrary {

    static let exercises: [Exercise] = {
        let list: [(String, MuscleGroup, String)] = [
            ("Bench press", .chest, "Barbell"),
            ("Incline bench press", .chest, "Barbell"),
            ("Dumbbell bench press", .chest, "Dumbbells"),
            ("Incline dumbbell press", .chest, "Dumbbells"),
            ("Chest fly", .chest, "Dumbbells"),
            ("Cable crossover", .chest, "Cable"),
            ("Push-up", .chest, "Bodyweight"),
            ("Dips", .chest, "Bodyweight"),
            ("Deadlift", .back, "Barbell"),
            ("Barbell row", .back, "Barbell"),
            ("Dumbbell row", .back, "Dumbbells"),
            ("Pull-up", .back, "Bodyweight"),
            ("Chin-up", .back, "Bodyweight"),
            ("Lat pulldown", .back, "Cable"),
            ("Seated cable row", .back, "Cable"),
            ("T-bar row", .back, "Machine"),
            ("Face pull", .shoulders, "Cable"),
            ("Overhead press", .shoulders, "Barbell"),
            ("Dumbbell shoulder press", .shoulders, "Dumbbells"),
            ("Lateral raise", .shoulders, "Dumbbells"),
            ("Front raise", .shoulders, "Dumbbells"),
            ("Rear delt fly", .shoulders, "Dumbbells"),
            ("Arnold press", .shoulders, "Dumbbells"),
            ("Barbell curl", .biceps, "Barbell"),
            ("Dumbbell curl", .biceps, "Dumbbells"),
            ("Hammer curl", .biceps, "Dumbbells"),
            ("Preacher curl", .biceps, "Machine"),
            ("Cable curl", .biceps, "Cable"),
            ("Triceps pushdown", .triceps, "Cable"),
            ("Skull crusher", .triceps, "Barbell"),
            ("Overhead triceps extension", .triceps, "Dumbbells"),
            ("Close-grip bench press", .triceps, "Barbell"),
            ("Back squat", .legs, "Barbell"),
            ("Front squat", .legs, "Barbell"),
            ("Leg press", .legs, "Machine"),
            ("Bulgarian split squat", .legs, "Dumbbells"),
            ("Lunge", .legs, "Dumbbells"),
            ("Leg extension", .legs, "Machine"),
            ("Leg curl", .legs, "Machine"),
            ("Romanian deadlift", .legs, "Barbell"),
            ("Calf raise", .legs, "Machine"),
            ("Goblet squat", .legs, "Dumbbells"),
            ("Hip thrust", .glutes, "Barbell"),
            ("Glute bridge", .glutes, "Bodyweight"),
            ("Cable kickback", .glutes, "Cable"),
            ("Hip abduction", .glutes, "Machine"),
            ("Plank", .core, "Bodyweight"),
            ("Crunch", .core, "Bodyweight"),
            ("Hanging leg raise", .core, "Bodyweight"),
            ("Cable crunch", .core, "Cable"),
            ("Russian twist", .core, "Bodyweight"),
            ("Ab wheel rollout", .core, "Other"),
            ("Kettlebell swing", .fullBody, "Kettlebell"),
            ("Clean and press", .fullBody, "Barbell"),
            ("Burpee", .fullBody, "Bodyweight"),
            ("Thruster", .fullBody, "Barbell"),
            ("Treadmill", .cardio, "Machine"),
            ("Rowing machine", .cardio, "Machine"),
            ("Stationary bike", .cardio, "Machine"),
            ("Elliptical", .cardio, "Machine"),
            ("Jump rope", .cardio, "Other"),
        ]
        return list.map { name, muscle, equipment in
            Exercise(id: "lib." + slug(name), name: name, muscle: muscle, equipment: equipment)
        }
    }()

    static func exerciseID(_ name: String) -> String { "lib." + slug(name) }

    /// About 860 more exercises from free-exercise-db (public domain), with
    /// step-by-step instructions and photos. Loaded on first use.
    static let database: [Exercise] = {
        struct Entry: Decodable {
            let id: String
            let name: String
            let muscle: MuscleGroup
            let equipment: String
            let level: String?
            let category: String?
            let primary: [String]
            let secondary: [String]
            let instructions: [String]
            let images: [String]
        }
        guard let url = Bundle.main.url(forResource: "exercises-db", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.map {
            Exercise(
                id: $0.id, name: $0.name, muscle: $0.muscle, equipment: $0.equipment,
                level: $0.level, category: $0.category, primary: $0.primary, secondary: $0.secondary,
                instructions: $0.instructions, images: $0.images
            )
        }
    }()

    /// Photos for database exercises, fetched when shown.
    static func imageURL(_ path: String) -> URL? {
        URL(string: "https://raw.githubusercontent.com/yuhonas/free-exercise-db/main/exercises/" + path)
    }

    /// Starting routines in the most common splits. Copied when used, so
    /// editing one never changes the template.
    static let routines: [Routine] = [Routine]([
        Routine(name: "Push", items: [
            item("Bench press", 4, 8), item("Incline dumbbell press", 3, 10),
            item("Overhead press", 3, 8), item("Lateral raise", 3, 15),
            item("Triceps pushdown", 3, 12),
        ]),
        Routine(name: "Pull", items: [
            item("Deadlift", 3, 5), item("Pull-up", 3, 8), item("Barbell row", 3, 10),
            item("Face pull", 3, 15), item("Barbell curl", 3, 10),
        ]),
        Routine(name: "Legs", items: [
            item("Back squat", 4, 6), item("Romanian deadlift", 3, 10), item("Leg press", 3, 12),
            item("Leg curl", 3, 12), item("Calf raise", 4, 15),
        ]),
        Routine(name: "Full body", items: [
            item("Back squat", 3, 8), item("Bench press", 3, 8), item("Barbell row", 3, 8),
            item("Overhead press", 2, 10), item("Plank", 3, 1),
        ]),
        Routine(name: "Upper", items: [
            item("Bench press", 4, 6), item("Barbell row", 4, 8), item("Dumbbell shoulder press", 3, 10),
            item("Lat pulldown", 3, 10), item("Dumbbell curl", 2, 12), item("Triceps pushdown", 2, 12),
        ]),
        Routine(name: "Lower", items: [
            item("Back squat", 4, 6), item("Hip thrust", 3, 10), item("Bulgarian split squat", 3, 10),
            item("Leg curl", 3, 12), item("Hanging leg raise", 3, 12),
        ]),
    ]).map { routine in
        // A fixed id per template, so the weekly plan still finds it after
        // the app restarts.
        var copy = routine
        copy.id = stableID("routine." + routine.name)
        return copy
    }

    static func stableID(_ text: String) -> UUID {
        let d = Array(Insecure.MD5.hash(data: Data(text.utf8)))
        return UUID(uuid: (d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
                           d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]))
    }

    private static func item(_ name: String, _ sets: Int, _ reps: Int) -> RoutineItem {
        RoutineItem(exerciseID: exerciseID(name), sets: sets, reps: reps)
    }

    /// Common foods per 100 g, rounded. Approximate reference values: labels
    /// on the actual product are always more accurate.
    static let foods: [Food] = {
        let list: [(String, Double, Double, Double, Double, Double)] = [
            // name, kcal, protein, carbs, fat, typical serving (g)
            ("Chicken breast, cooked", 165, 31, 0, 3.6, 150),
            ("Turkey breast", 135, 29, 0, 1.5, 150),
            ("Beef, lean, cooked", 217, 26, 0, 12, 150),
            ("Pork loin, cooked", 196, 27, 0, 9, 150),
            ("Salmon, cooked", 206, 22, 0, 13, 150),
            ("Tuna, canned in water", 116, 26, 0, 1, 80),
            ("Hake / white fish", 90, 18, 0, 1.5, 150),
            ("Egg", 143, 13, 0.7, 10, 60),
            ("Egg white", 52, 11, 0.7, 0.2, 100),
            ("Ham, cured (jamón serrano)", 241, 31, 0, 13, 40),
            ("Cooked ham", 115, 18, 1.5, 4, 50),
            ("Greek yogurt, plain", 97, 9, 4, 5, 125),
            ("Skyr / high-protein yogurt", 63, 11, 4, 0.2, 150),
            ("Milk, semi-skimmed", 47, 3.4, 4.8, 1.6, 250),
            ("Cottage cheese", 98, 11, 3.4, 4.3, 100),
            ("Cheese, cured", 390, 26, 0.5, 32, 30),
            ("Fresh cheese (queso fresco)", 175, 12, 3, 13, 60),
            ("Whey protein powder", 380, 78, 8, 5, 30),
            ("White rice, cooked", 130, 2.7, 28, 0.3, 200),
            ("Brown rice, cooked", 123, 2.7, 26, 1, 200),
            ("Pasta, cooked", 158, 5.8, 31, 0.9, 200),
            ("Bread, white", 265, 9, 49, 3.2, 60),
            ("Bread, wholemeal", 247, 13, 41, 3.4, 60),
            ("Oats", 389, 17, 66, 7, 50),
            ("Potato, boiled", 87, 1.9, 20, 0.1, 200),
            ("Sweet potato, baked", 90, 2, 21, 0.2, 200),
            ("Quinoa, cooked", 120, 4.4, 21, 1.9, 180),
            ("Lentils, cooked", 116, 9, 20, 0.4, 200),
            ("Chickpeas, cooked", 164, 8.9, 27, 2.6, 200),
            ("Beans, cooked", 127, 8.7, 23, 0.5, 200),
            ("Banana", 89, 1.1, 23, 0.3, 120),
            ("Apple", 52, 0.3, 14, 0.2, 180),
            ("Orange", 47, 0.9, 12, 0.1, 150),
            ("Strawberries", 32, 0.7, 7.7, 0.3, 150),
            ("Blueberries", 57, 0.7, 14, 0.3, 100),
            ("Grapes", 69, 0.7, 18, 0.2, 150),
            ("Broccoli", 34, 2.8, 7, 0.4, 150),
            ("Spinach", 23, 2.9, 3.6, 0.4, 100),
            ("Tomato", 18, 0.9, 3.9, 0.2, 120),
            ("Lettuce / salad mix", 15, 1.4, 2.9, 0.2, 100),
            ("Carrot", 41, 0.9, 10, 0.2, 80),
            ("Avocado", 160, 2, 8.5, 15, 70),
            ("Olive oil", 884, 0, 0, 100, 10),
            ("Butter", 717, 0.9, 0.1, 81, 10),
            ("Almonds", 579, 21, 22, 50, 30),
            ("Walnuts", 654, 15, 14, 65, 30),
            ("Peanut butter", 588, 25, 20, 50, 20),
            ("Dark chocolate 70%", 598, 7.8, 46, 43, 20),
            ("Honey", 304, 0.3, 82, 0, 15),
            ("Orange juice", 45, 0.7, 10, 0.2, 250),
            ("Beer", 43, 0.5, 3.6, 0, 330),
            ("Red wine", 85, 0.1, 2.6, 0, 150),
            ("Cola", 42, 0, 10.6, 0, 330),
            ("Pizza", 266, 11, 33, 10, 250),
            ("Hamburger", 250, 13, 30, 9, 220),
            ("Spanish omelette (tortilla)", 190, 6, 13, 13, 150),
            ("Croissant", 406, 8, 46, 21, 60),
            ("Granola", 471, 10, 64, 20, 50),
            ("Rice cakes", 387, 8, 82, 2.8, 20),
        ]
        return list.map { name, kcal, protein, carbs, fat, serving in
            Food(id: "lib." + slug(name), name: name, kcal: kcal, protein: protein,
                 carbs: carbs, fat: fat, serving: serving)
        }
    }()

    static func slug(_ name: String) -> String {
        name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}
