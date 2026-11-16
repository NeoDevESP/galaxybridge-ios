import Charts
import SwiftUI

/// The Fitness tab: today's training and eating at a glance, and the way into
/// gym, nutrition, body and achievements.
struct FitnessView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var coordinator: BridgeCoordinator

    @State private var earned = 0
    @State private var showActive = false

    var body: some View {
        NavigationStack {
            List {
                if fitness.activeSession != nil {
                    Section {
                        Button {
                            showActive = true
                        } label: {
                            Label("Workout in progress, tap to continue", systemImage: "dumbbell.fill")
                                .font(.headline)
                        }
                    }
                }

                Section {
                    TodayPlanCard { showActive = true }
                }

                Section("Today") {
                    let totals = fitness.totals(on: Date())
                    CalorieSummary(
                        eaten: totals.kcal,
                        target: fitness.targets.calories,
                        burned: coordinator.dashboard.today.activeEnergy
                    )
                    WaterRow(day: Date())
                }

                Section {
                    NavigationLink {
                        GymView()
                    } label: {
                        hubRow(tr("Gym"), detail: gymDetail, systemImage: "dumbbell.fill", tint: .orange)
                    }
                    NavigationLink {
                        NutritionView()
                    } label: {
                        hubRow(tr("Nutrition"), detail: tr("Food diary, macros, barcode scanner and water"), systemImage: "fork.knife", tint: .green)
                    }
                    NavigationLink {
                        BodyView()
                    } label: {
                        hubRow(tr("Body"), detail: bodyDetail, systemImage: "figure.arms.open", tint: .purple)
                    }
                    NavigationLink {
                        AchievementsView()
                    } label: {
                        hubRow(
                            tr("Achievements"),
                            detail: String(format: tr("%ld of %ld earned"), fitness.data.achievements.count, Achievement.all.count),
                            systemImage: "medal.fill",
                            tint: .yellow
                        )
                    }
                    NavigationLink {
                        WorkoutListView()
                    } label: {
                        hubRow(tr("Watch workouts"), detail: tr("Runs, walks and rides with routes"), systemImage: "figure.run", tint: .green)
                    }
                }

                Section("Tools") {
                    NavigationLink {
                        PlanEditorView()
                    } label: {
                        hubRow(tr("Weekly plan"), detail: tr("A routine for each day and a weekly goal"), systemImage: "calendar", tint: .orange)
                    }
                    NavigationLink {
                        GymStatsView()
                    } label: {
                        hubRow(tr("Statistics"), detail: tr("Training calendar, volume and balance"), systemImage: "chart.bar.xaxis", tint: .orange)
                    }
                    NavigationLink {
                        RepCounterView(movement: .squat, onSave: nil)
                            .toolbar(.hidden, for: .navigationBar, .tabBar)
                    } label: {
                        hubRow(tr("Rep counter"), detail: tr("The camera counts squats, push-ups, curls and more"), systemImage: "camera.viewfinder", tint: .teal)
                    }
                    NavigationLink {
                        IntervalTimerView()
                    } label: {
                        hubRow(tr("Interval timer"), detail: tr("Tabata, HIIT and EMOM"), systemImage: "timer", tint: .red)
                    }
                    NavigationLink {
                        FastingView()
                    } label: {
                        hubRow(tr("Fasting"), detail: fastingDetail, systemImage: "hourglass", tint: .purple)
                    }
                }
            }
            .navigationTitle("Fitness")
            .fullScreenCover(isPresented: $showActive) {
                NavigationStack { ActiveSessionView() }
            }
            .task { await coordinator.refreshAchievements() }
        }
    }

    private var gymDetail: String {
        guard let last = fitness.data.sessions.first else { return tr("Routines, sets and records") }
        return String(format: tr("Last: %@, %@"), last.name, last.start.formatted(.relative(presentation: .named)))
    }

    private var fastingDetail: String {
        guard let fast = fitness.activeFast else { return tr("Intermittent fasting timer") }
        return String(format: tr("Fasting for %@"), fast.duration.hoursMinutes)
    }

    private var bodyDetail: String {
        guard let weight = fitness.latestWeight else { return tr("Weight, measurements and photos") }
        return "\(weight.kg.oneDecimal) kg" + (fitness.bmi.map { " · BMI \($0.oneDecimal)" } ?? "")
    }

    private func hubRow(_ title: String, detail: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(title)).font(.headline)
                Text(tr(detail)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Body

struct BodyView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var coordinator: BridgeCoordinator
    @State private var adding = false

    private var sorted: [WeightEntry] { fitness.data.weights.sorted { $0.date < $1.date } }

    var body: some View {
        List {
            Section {
                HStack {
                    tile("Weight", fitness.latestWeight.map { $0.kg.oneDecimal } ?? "--", "kg")
                    tile("BMI", fitness.bmi.map { $0.oneDecimal } ?? "--", nil)
                    tile("Target", fitness.data.profile.targetWeightKg.map { $0.oneDecimal } ?? "--", "kg")
                }
                if sorted.count >= 2 {
                    Chart(sorted) { entry in
                        LineMark(x: .value("Date", entry.date), y: .value("kg", entry.kg))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(Color.purple)
                        PointMark(x: .value("Date", entry.date), y: .value("kg", entry.kg))
                            .foregroundStyle(Color.purple)
                        if let target = fitness.data.profile.targetWeightKg {
                            RuleMark(y: .value("Target", target))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 200)
                }
                if let change = changeText {
                    Text(change).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    adding = true
                } label: {
                    Label("Log weight", systemImage: "plus")
                }
                TargetWeightRow()
            }

            Section {
                NavigationLink {
                    BodyCompositionView(dashboard: coordinator.dashboard)
                } label: {
                    Label("Body composition from the watch", systemImage: "figure.arms.open")
                }
                NavigationLink {
                    MeasurementsView()
                } label: {
                    Label("Measurements", systemImage: "ruler")
                }
                NavigationLink {
                    ProgressPhotosView()
                } label: {
                    LabeledContent {
                        Text("\(fitness.data.photos.count)")
                    } label: {
                        Label("Progress photos", systemImage: "camera")
                    }
                }
            }

            Section("History") {
                if sorted.isEmpty {
                    Text("No entries yet.").foregroundStyle(.secondary)
                }
                ForEach(sorted.reversed()) { entry in
                    HStack {
                        Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(entry.kg.oneDecimal) kg").monospacedDigit()
                            let extra = [
                                entry.bodyFat.map { "\($0.oneDecimal)% fat" },
                                entry.waistCm.map { "waist \($0.noDecimals) cm" },
                            ].compactMap { $0 }
                            if !extra.isEmpty {
                                Text(extra.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { fitness.deleteWeight(entry.id) }
                    }
                }
            }
        }
        .navigationTitle("Body")
        .sheet(isPresented: $adding) {
            NavigationStack {
                WeightEntryView(start: fitness.latestWeight?.kg ?? 70) { entry in
                    fitness.addWeight(entry)
                    adding = false
                    // The watch's body composition sensor uses the latest weight.
                    coordinator.pushHealthConfig()
                }
            }
            .presentationDetents([.medium])
        }
    }

    /// Change over the last 30 days, the time scale where weight trends mean
    /// something rather than day-to-day water swings.
    private var changeText: String? {
        guard let latest = sorted.last else { return nil }
        let monthAgo = latest.date.addingTimeInterval(-30 * 24 * 3600)
        guard let reference = sorted.last(where: { $0.date <= monthAgo }) ?? sorted.first,
              reference.id != latest.id else { return nil }
        let delta = latest.kg - reference.kg
        let sign = delta > 0 ? "+" : ""
        return "\(sign)\(delta.oneDecimal) kg since " + reference.date.formatted(date: .abbreviated, time: .omitted)
    }

    private func tile(_ title: String, _ value: String, _ unit: String?) -> some View {
        VStack(spacing: 2) {
            Text(tr(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            if let unit { Text(tr(unit)).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TargetWeightRow: View {
    @EnvironmentObject private var fitness: FitnessStore
    @State private var value: Double = 0

    var body: some View {
        HStack {
            Text("Target weight")
            Spacer()
            NumberField(placeholder: "kg", value: $value).frame(width: 90)
            Text("kg")
        }
        .onAppear { value = fitness.data.profile.targetWeightKg ?? 0 }
        .onChange(of: value) { _, new in
            fitness.updateProfile { $0.targetWeightKg = new > 0 ? new : nil }
        }
    }
}

struct WeightEntryView: View {
    let start: Double
    let onSave: (WeightEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kg: Double = 0
    @State private var fat: Double = 0
    @State private var waist: Double = 0
    @State private var date = Date()

    var body: some View {
        Form {
            DatePicker("Date", selection: $date, in: ...Date(), displayedComponents: .date)
            row("Weight (kg)", $kg)
            row("Body fat (%) optional", $fat)
            row("Waist (cm) optional", $waist)
        }
        .navigationTitle("Log weight")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if kg == 0 { kg = start } }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    onSave(WeightEntry(
                        date: date, kg: kg,
                        bodyFat: fat > 0 ? fat : nil,
                        waistCm: waist > 0 ? waist : nil
                    ))
                }
                .disabled(kg < 20 || kg > 400)
            }
        }
    }

    private func row(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(tr(title))
            Spacer()
            NumberField(placeholder: "0", value: value).frame(width: 90)
        }
    }
}

// MARK: - Achievements

struct AchievementsView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var coordinator: BridgeCoordinator

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(String(format: tr("%ld of %ld earned"), fitness.data.achievements.count, Achievement.all.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(Achievement.Category.allCases, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(tr(category.rawValue)).font(.headline)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Achievement.all.filter { $0.category == category }) { achievement in
                                badge(achievement)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .groupedBackground()
        .navigationTitle("Achievements")
        .task { await coordinator.refreshAchievements() }
    }

    private func badge(_ achievement: Achievement) -> some View {
        let earnedAt = fitness.data.achievements[achievement.id]
        let progress = earnedAt != nil ? 1 : achievement.progress(coordinator.achievementContext)
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(earnedAt != nil ? AnyShapeStyle(Color.yellow.gradient) : AnyShapeStyle(Color.gray.opacity(0.15)))
                    .frame(width: 58, height: 58)
                Image(systemName: achievement.systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .font(.title2)
                    .foregroundStyle(earnedAt != nil ? .white : .secondary)
            }
            Text(achievement.localizedTitle)
                .font(.caption.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let earnedAt {
                Text(earnedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView(value: progress).tint(.yellow)
                Text(achievement.localizedDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .top)
        .cardStyle(padding: 8)
    }
}
