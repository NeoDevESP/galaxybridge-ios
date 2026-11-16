import SwiftUI

/// One day of eating: calories against the target, macros, water and meals.
struct NutritionView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var coordinator: BridgeCoordinator

    @State private var day = Date()
    @State private var adding: Meal?

    var body: some View {
        let totals = fitness.totals(on: day)
        let targets = fitness.targets
        List {
            Section {
                DayStepper(day: $day)
            }

            Section {
                CalorieSummary(
                    eaten: totals.kcal,
                    target: targets.calories,
                    burned: Calendar.current.isDateInToday(day) ? coordinator.dashboard.today.activeEnergy : nil
                )
                MacroBar(title: "Protein", value: totals.protein, target: targets.protein, colour: .red)
                MacroBar(title: "Carbs", value: totals.carbs, target: targets.carbs, colour: .blue)
                MacroBar(title: "Fat", value: totals.fat, target: targets.fat, colour: .yellow)
            }

            Section("Water") {
                WaterRow(day: day)
            }

            ForEach(Meal.allCases) { meal in
                mealSection(meal)
            }

            Section {
                NavigationLink {
                    TargetsView()
                } label: {
                    Label("Goals and targets", systemImage: "target")
                }
                NavigationLink {
                    FastingView()
                } label: {
                    Label("Fasting", systemImage: "hourglass")
                }
            }
        }
        .navigationTitle("Nutrition")
        .sheet(item: $adding) { meal in
            NavigationStack {
                AddFoodView(meal: meal, day: day) { adding = nil }
            }
        }
    }

    private func mealSection(_ meal: Meal) -> some View {
        let entries = fitness.entries(on: day).filter { $0.meal == meal }
        let kcal = entries.map(\.kcal).reduce(0, +)
        return Section {
            ForEach(entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr(entry.name))
                        Text(
                            (entry.grams > 0 ? "\(entry.grams.noDecimals) g · " : "")
                                + "P \(entry.protein.noDecimals) · C \(entry.carbs.noDecimals) · F \(entry.fat.noDecimals)"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(entry.kcal.noDecimals) kcal").font(.subheadline.monospacedDigit())
                }
            }
            .onDelete { offsets in
                for index in offsets { fitness.deleteFood(entries[index].id) }
            }
            Button {
                adding = meal
            } label: {
                Label("Add food", systemImage: "plus")
            }
            if entries.isEmpty {
                let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day
                if fitness.entries(on: yesterday).contains(where: { $0.meal == meal }) {
                    Button {
                        fitness.copyMeal(meal, from: yesterday, to: day)
                    } label: {
                        Label("Same as yesterday", systemImage: "doc.on.doc")
                    }
                }
            }
        } header: {
            HStack {
                Label(meal.title, systemImage: meal.systemImage)
                Spacer()
                if kcal > 0 { Text("\(kcal.noDecimals) kcal") }
            }
        }
    }
}

struct DayStepper: View {
    @Binding var day: Date

    var body: some View {
        HStack {
            Button {
                day = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            Spacer()
            Text(
                Calendar.current.isDateInToday(day)
                    ? "Today"
                    : day.formatted(date: .abbreviated, time: .omitted)
            )
            .font(.headline)
            Spacer()
            Button {
                day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(Calendar.current.isDateInToday(day))
        }
    }
}

struct CalorieSummary: View {
    let eaten: Double
    let target: Double
    let burned: Double?

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading) {
                    Text("Eaten").font(.caption).foregroundStyle(.secondary)
                    Text(eaten.noDecimals).font(.title.monospacedDigit().weight(.semibold))
                }
                Spacer()
                VStack {
                    Text("Remaining").font(.caption).foregroundStyle(.secondary)
                    Text((target - eaten).noDecimals)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(eaten > target ? .orange : .primary)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Target").font(.caption).foregroundStyle(.secondary)
                    Text(target.noDecimals).font(.title3.monospacedDigit())
                }
            }
            ProgressView(value: min(eaten, target), total: max(target, 1))
                .tint(eaten > target ? .orange : .green)
            if let burned, burned > 0 {
                HStack {
                    Image(systemName: "flame.fill").foregroundStyle(.red)
                    Text("\(burned.noDecimals) kcal active today, from the watch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct MacroBar: View {
    let title: String
    let value: Double
    let target: Double
    let colour: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(tr(title)).font(.subheadline)
                Spacer()
                Text("\(value.noDecimals) / \(target.noDecimals) g")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(value, target), total: max(target, 1))
                .tint(colour)
        }
    }
}

struct WaterRow: View {
    @EnvironmentObject private var fitness: FitnessStore
    let day: Date

    var body: some View {
        let amount = fitness.water(on: day)
        let goal = fitness.data.profile.waterGoalMl
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "drop.fill").foregroundStyle(.cyan)
                Text("\((amount / 1000).formatted(.number.precision(.fractionLength(2)))) L")
                    .font(.headline.monospacedDigit())
                Text("of \((goal / 1000).formatted()) L").foregroundStyle(.secondary)
                Spacer()
                Button {
                    fitness.addWater(-250, on: day)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(amount <= 0)
                Button {
                    fitness.addWater(250, on: day)
                } label: {
                    Label("Glass", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }
            ProgressView(value: min(amount, goal), total: max(goal, 1)).tint(.cyan)
        }
    }
}

// MARK: - Adding food

struct AddFoodView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @Environment(\.dismiss) private var dismiss
    @State var meal: Meal
    let day: Date
    let onDone: () -> Void

    @State private var search = ""
    @State private var chosen: Food?
    @State private var showQuickAdd = false
    @State private var showCreate = false
    @State private var showScanner = false

    private var results: [Food] {
        guard !search.isEmpty else { return fitness.allFoods }
        return fitness.allFoods.filter {
            $0.name.localizedCaseInsensitiveContains(search) || tr($0.name).localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Meal", selection: $meal) {
                    ForEach(Meal.allCases) { Text($0.title).tag($0) }
                }
                Button {
                    showScanner = true
                } label: {
                    Label("Scan a barcode", systemImage: "barcode.viewfinder")
                }
                Button {
                    showQuickAdd = true
                } label: {
                    Label("Quick add calories", systemImage: "bolt.fill")
                }
                Button {
                    showCreate = true
                } label: {
                    Label("Create a food", systemImage: "square.and.pencil")
                }
            }
            if search.isEmpty && !fitness.favoriteFoods.isEmpty {
                Section("Favourites") {
                    ForEach(fitness.favoriteFoods) { foodRow($0) }
                }
            }
            if search.isEmpty && !fitness.recentFoods.isEmpty {
                Section("Recent") {
                    ForEach(fitness.recentFoods) { foodRow($0) }
                }
            }
            Section(search.isEmpty ? "All foods" : "Results") {
                ForEach(results) { foodRow($0) }
            }
        }
        .searchable(text: $search, prompt: "Search foods")
        .navigationTitle(String(format: tr("Add to %@"), meal.title.lowercased()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { onDone() }
            }
        }
        .sheet(item: $chosen) { food in
            NavigationStack {
                FoodAmountView(food: food) { grams in
                    fitness.log(food: food, grams: grams, meal: meal, on: day)
                    chosen = nil
                    onDone()
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showQuickAdd) {
            NavigationStack {
                QuickAddView { name, kcal, protein, carbs, fat in
                    fitness.quickAdd(name: name, kcal: kcal, protein: protein, carbs: carbs, fat: fat, meal: meal, on: day)
                    showQuickAdd = false
                    onDone()
                }
            }
        }
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                BarcodeLookupView { food in
                    showScanner = false
                    chosen = food
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                CreateFoodView { food in
                    fitness.addCustomFood(food)
                    showCreate = false
                    chosen = food
                }
            }
        }
    }

    private func foodRow(_ food: Food) -> some View {
        Button {
            chosen = food
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(food.custom ? food.name : tr(food.name)).foregroundStyle(.primary)
                        if fitness.isFavorite(food.name) {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        }
                    }
                    Text("per 100 g · P \(food.protein.noDecimals) C \(food.carbs.noDecimals) F \(food.fat.noDecimals)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(food.kcal.noDecimals) kcal").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                fitness.toggleFavorite(food.name)
            } label: {
                Image(systemName: fitness.isFavorite(food.name) ? "star.slash" : "star")
            }
            .tint(.yellow)
        }
    }
}

struct FoodAmountView: View {
    let food: Food
    let onLog: (Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var grams: Double = 0

    var body: some View {
        let factor = grams / 100
        Form {
            Section {
                HStack {
                    Text("Amount")
                    Spacer()
                    NumberField(placeholder: "g", value: $grams)
                        .frame(width: 100)
                    Text("g")
                }
                HStack {
                    ForEach([0.5, 1, 1.5, 2], id: \.self) { multiple in
                        Button("\((food.serving * multiple).noDecimals) g") {
                            grams = food.serving * multiple
                        }
                        .buttonStyle(.bordered)
                        .font(.caption)
                    }
                }
            }
            Section {
                LabeledContent("Calories", value: "\((food.kcal * factor).noDecimals) kcal")
                LabeledContent("Protein", value: "\((food.protein * factor).oneDecimal) g")
                LabeledContent("Carbs", value: "\((food.carbs * factor).oneDecimal) g")
                LabeledContent("Fat", value: "\((food.fat * factor).oneDecimal) g")
            }
            Section {
                Button("Add") { onLog(grams) }
                    .disabled(grams <= 0)
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(food.custom ? food.name : tr(food.name))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if grams == 0 { grams = food.serving } }
        .id(food.id)
    }
}

struct QuickAddView: View {
    let onAdd: (String, Double, Double, Double, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kcal: Double = 0
    @State private var protein: Double = 0
    @State private var carbs: Double = 0
    @State private var fat: Double = 0

    var body: some View {
        Form {
            TextField("Name (optional)", text: $name)
            row("Calories (kcal)", $kcal)
            row("Protein (g)", $protein)
            row("Carbs (g)", $carbs)
            row("Fat (g)", $fat)
        }
        .navigationTitle("Quick add")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add") { onAdd(name, kcal, protein, carbs, fat) }.disabled(kcal <= 0)
            }
        }
    }

    private func row(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(tr(title))
            Spacer()
            NumberField(placeholder: "0", value: value).frame(width: 100)
        }
    }
}

struct CreateFoodView: View {
    let onCreate: (Food) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kcal: Double = 0
    @State private var protein: Double = 0
    @State private var carbs: Double = 0
    @State private var fat: Double = 0
    @State private var serving: Double = 100

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
            }
            Section("Per 100 g (from the label)") {
                row("Calories (kcal)", $kcal)
                row("Protein (g)", $protein)
                row("Carbs (g)", $carbs)
                row("Fat (g)", $fat)
            }
            Section {
                row("Usual serving (g)", $serving)
            }
        }
        .navigationTitle("New food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    onCreate(
                        Food(
                            id: "custom." + UUID().uuidString, name: name, kcal: kcal,
                            protein: protein, carbs: carbs, fat: fat,
                            serving: serving > 0 ? serving : 100, custom: true
                        )
                    )
                }
                .disabled(name.isEmpty || kcal <= 0)
            }
        }
    }

    private func row(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(tr(title))
            Spacer()
            NumberField(placeholder: "0", value: value).frame(width: 100)
        }
    }
}

// MARK: - Targets and profile

struct TargetsView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @State private var age: Double = Profile.age
    @State private var useCustom = false
    @State private var custom: Double = 2000

    var body: some View {
        let profile = fitness.data.profile
        let targets = fitness.targets
        Form {
            Section {
                Picker("Sex", selection: binding(\.sex)) {
                    ForEach(Sex.allCases) { Text($0.title).tag($0) }
                }
                Stepper(value: $age, in: 10...100) {
                    LabeledContent("Age", value: "\(Int(age))")
                }
                .onChange(of: age) { _, value in Profile.age = value }
                Stepper(value: binding(\.heightCm), in: 120...230) {
                    LabeledContent("Height", value: "\(Int(profile.heightCm)) cm")
                }
                LabeledContent(
                    "Weight",
                    value: fitness.latestWeight.map { "\($0.kg.oneDecimal) kg" } ?? "Log it in Body"
                )
                Picker("Activity", selection: binding(\.activity)) {
                    ForEach(ActivityLevel.allCases) { Text($0.title).tag($0) }
                }
                Picker("Goal", selection: binding(\.goal)) {
                    ForEach(FitnessGoal.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("About you")
            }

            Section {
                LabeledContent("Basal metabolism", value: "\(targets.bmr.noDecimals) kcal")
                LabeledContent("Maintenance", value: "\(targets.maintenance.noDecimals) kcal")
                Toggle("Set calories by hand", isOn: $useCustom)
                if useCustom {
                    Stepper(value: $custom, in: 1000...6000, step: 50) {
                        LabeledContent("Daily calories", value: custom.noDecimals)
                    }
                }
                LabeledContent("Daily target", value: "\(targets.calories.noDecimals) kcal")
                LabeledContent("Protein", value: "\(targets.protein.noDecimals) g")
                LabeledContent("Carbs", value: "\(targets.carbs.noDecimals) g")
                LabeledContent("Fat", value: "\(targets.fat.noDecimals) g")
            } header: {
                Text("Daily targets")
            } footer: {
                Text("Estimated with the Mifflin-St Jeor equation and your activity level. A starting point: adjust it after two or three weeks of tracking your weight.")
            }

            Section("Water") {
                Stepper(value: binding(\.waterGoalMl), in: 1000...5000, step: 250) {
                    LabeledContent("Daily goal", value: "\((profile.waterGoalMl / 1000).formatted()) L")
                }
            }
        }
        .navigationTitle("Goals and targets")
        .onAppear {
            useCustom = profile.customCalories != nil
            custom = profile.customCalories ?? targets.calories.rounded()
        }
        .onChange(of: useCustom) { _, on in
            fitness.updateProfile { $0.customCalories = on ? custom : nil }
        }
        .onChange(of: custom) { _, value in
            if useCustom { fitness.updateProfile { $0.customCalories = value } }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<BodyProfile, T>) -> Binding<T> {
        Binding(
            get: { fitness.data.profile[keyPath: keyPath] },
            set: { value in fitness.updateProfile { $0[keyPath: keyPath] = value } }
        )
    }
}
