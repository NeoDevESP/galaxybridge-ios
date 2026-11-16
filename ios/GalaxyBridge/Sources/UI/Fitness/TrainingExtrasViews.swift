import Charts
import SwiftUI

// MARK: - Weekly plan

/// Today's planned routine and the week's workout goal, at the top of Fitness.
struct TodayPlanCard: View {
    @EnvironmentObject private var fitness: FitnessStore
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("This week", systemImage: "calendar")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Text("\(fitness.workoutsThisWeek) of \(fitness.data.weeklyWorkoutGoal) workouts")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(
                value: min(1, Double(fitness.workoutsThisWeek) / Double(max(1, fitness.data.weeklyWorkoutGoal)))
            )
            .tint(.orange)
            WeekStrip()
            if let routine = fitness.todaysRoutine {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Today").font(.caption).foregroundStyle(.secondary)
                        Text(tr(routine.name)).font(.headline)
                    }
                    Spacer()
                    Button {
                        fitness.startSession(from: routine)
                        onStart()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(fitness.activeSession != nil)
                }
            } else {
                Text("Rest day, or no routine planned for today.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Seven dots for this week: trained, planned, or neither.
struct WeekStrip: View {
    @EnvironmentObject private var fitness: FitnessStore

    var body: some View {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        let trained = fitness.trainingDays
        HStack {
            ForEach(days, id: \.self) { day in
                let weekday = calendar.component(.weekday, from: day)
                let done = trained.contains(calendar.startOfDay(for: day))
                let planned = fitness.plannedRoutine(weekday: weekday) != nil
                VStack(spacing: 4) {
                    Text(day.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption2)
                        .foregroundStyle(calendar.isDateInToday(day) ? .primary : .secondary)
                    ZStack {
                        Circle()
                            .fill(done ? Color.orange : Color.clear)
                        Circle()
                            .strokeBorder(planned ? Color.orange : Color.secondary.opacity(0.3), lineWidth: 1.5)
                        if done {
                            Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 24, height: 24)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct PlanEditorView: View {
    @EnvironmentObject private var fitness: FitnessStore

    private var routines: [Routine] { fitness.data.routines + FitnessLibrary.routines }

    var body: some View {
        Form {
            Section {
                Stepper(value: Binding(
                    get: { fitness.data.weeklyWorkoutGoal },
                    set: { fitness.setWeeklyWorkoutGoal($0) }
                ), in: 1...14) {
                    LabeledContent("Workouts per week", value: "\(fitness.data.weeklyWorkoutGoal)")
                }
            } footer: {
                Text("Weeks in a row that meet this goal count towards achievements.")
            }
            Section("Routine for each day") {
                ForEach(Self.weekdayOrder(), id: \.self) { weekday in
                    Picker(Calendar.current.weekdaySymbols[weekday - 1].capitalized, selection: Binding(
                        get: { fitness.data.plan[String(weekday)] },
                        set: { fitness.setPlan(weekday: weekday, routine: $0) }
                    )) {
                        Text("Rest").tag(UUID?.none)
                        ForEach(routines) { routine in
                            Text(tr(routine.name)).tag(UUID?.some(routine.id))
                        }
                    }
                }
            }
        }
        .navigationTitle("Weekly plan")
        .onDisappear { Reminders.reschedule(fitness: fitness) }
    }

    /// Weekdays starting on the locale's first day of the week.
    static func weekdayOrder() -> [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }
}

// MARK: - Plates and warm-ups

struct PlateCalculatorView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @Environment(\.dismiss) private var dismiss
    @State var total: Double

    var body: some View {
        let result = FitnessStore.plates(for: total, bar: fitness.data.barWeight)
        Form {
            Section {
                HStack {
                    Text("Total")
                    Spacer()
                    NumberField(placeholder: "kg", value: $total).frame(width: 90)
                    Text("kg")
                }
                Picker("Bar", selection: Binding(
                    get: { fitness.data.barWeight },
                    set: { fitness.setBarWeight($0) }
                )) {
                    ForEach([20.0, 15, 10, 7.5], id: \.self) { kg in
                        Text("\(kg.formatted()) kg").tag(kg)
                    }
                }
            }
            Section("Each side") {
                if result.plates.isEmpty {
                    Text("Just the bar.").foregroundStyle(.secondary)
                } else {
                    BarbellDrawing(plates: result.plates)
                        .frame(height: 110)
                    Text(result.plates.map { $0.formatted() }.joined(separator: " + ") + " kg")
                        .font(.headline.monospacedDigit())
                }
                if result.remainder > 0.01 {
                    Text("\(result.remainder.formatted()) kg cannot be loaded with standard plates.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Plate calculator")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
        }
    }
}

/// One side of the bar with its plates, sized by weight and coloured the
/// way competition plates are.
struct BarbellDrawing: View {
    let plates: [Double]

    private func colour(_ kg: Double) -> Color {
        switch kg {
        case 25: return .red
        case 20: return .blue
        case 15: return .yellow
        case 10: return .green
        default: return .gray
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            Rectangle().fill(.gray).frame(width: 30, height: 10)
            Rectangle().fill(.gray.opacity(0.8)).frame(width: 8, height: 30)
            ForEach(Array(plates.enumerated()), id: \.offset) { _, kg in
                RoundedRectangle(cornerRadius: 3)
                    .fill(colour(kg).gradient)
                    .frame(width: kg >= 10 ? 16 : 10, height: 30 + min(kg, 25) * 3)
                    .overlay(
                        Text(kg.formatted())
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(-90))
                            .foregroundStyle(.white)
                    )
            }
            Rectangle().fill(.gray).frame(width: 40, height: 10)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Statistics

struct GymStatsView: View {
    @EnvironmentObject private var fitness: FitnessStore

    var body: some View {
        let weeks = fitness.weeklyVolume(weeks: 12)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    stat(tr("This week"), "\(fitness.workoutsThisWeek)", tr("workouts"))
                    stat(tr("Goal streak"), "\(fitness.goalWeeksStreak)", tr("weeks"))
                    stat(tr("All time"), "\(fitness.data.sessions.count)", tr("workouts"))
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Training calendar").font(.headline)
                    TrainingHeatmap(days: fitness.trainingDays, weeks: 16)
                }
                .cardStyle()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Volume per week").font(.headline)
                    Chart(weeks) { week in
                        BarMark(
                            x: .value("Week", week.week, unit: .weekOfYear),
                            y: .value("kg", week.volume)
                        )
                        .foregroundStyle(Color.orange.gradient)
                    }
                    .chartYAxisLabel("kg")
                    .frame(height: 180)
                    Text("Weight × reps of every completed work set. Rising volume over weeks is what drives muscle growth.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .cardStyle()

                let weekly = fitness.weeklySetsByMuscle
                if !weekly.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sets this week by muscle").font(.headline)
                        Chart(weekly, id: \.muscle) { entry in
                            BarMark(x: .value("Sets", entry.sets), y: .value("Muscle", entry.muscle.title))
                                .foregroundStyle(Color.orange.gradient)
                            RuleMark(x: .value("Target", 10))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: CGFloat(weekly.count) * 28 + 20)
                        Text("Around 10 hard sets per muscle a week is a common target for growth.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .cardStyle()
                }
            }
            .padding()
        }
        .groupedBackground()
        .navigationTitle("Statistics")
    }

    private func stat(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(tr(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title2, design: .rounded, weight: .bold))
            Text(tr(unit)).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Weeks as columns, days as rows, a filled square for each training day.
struct TrainingHeatmap: View {
    let days: Set<Date>
    let weeks: Int

    var body: some View {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())?.start ?? Date()
        let first = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek) ?? thisWeek
        let today = calendar.startOfDay(for: Date())
        HStack(spacing: 3) {
            ForEach(0..<weeks, id: \.self) { week in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { day in
                        let date = calendar.date(byAdding: .day, value: week * 7 + day, to: first) ?? first
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                date > today
                                    ? Color.clear
                                    : (days.contains(date) ? Color.orange : Color.secondary.opacity(0.15))
                            )
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
    }
}

// MARK: - Interval timer

/// Work and rest rounds with a countdown, haptics on every change, and the
/// common presets: Tabata, HIIT, EMOM.
struct IntervalTimerView: View {
    @EnvironmentObject private var fitness: FitnessStore

    struct Preset: Identifiable, Hashable {
        let id: String
        let name: String
        let work: Int
        let rest: Int
        let rounds: Int
    }

    static let presets = [
        Preset(id: "tabata", name: "Tabata", work: 20, rest: 10, rounds: 8),
        Preset(id: "hiit", name: "HIIT 40/20", work: 40, rest: 20, rounds: 10),
        Preset(id: "emom", name: "EMOM 10", work: 60, rest: 0, rounds: 10),
        Preset(id: "long", name: "Intervals 2/1", work: 120, rest: 60, rounds: 6),
    ]

    @State private var work = 20
    @State private var rest = 10
    @State private var rounds = 8
    @State private var warmup = 10
    @State private var running = false

    var body: some View {
        Form {
            Section("Presets") {
                ForEach(Self.presets) { preset in
                    Button {
                        work = preset.work
                        rest = preset.rest
                        rounds = preset.rounds
                    } label: {
                        LabeledContent(preset.name, value: "\(preset.work)s / \(preset.rest)s × \(preset.rounds)")
                    }
                    .foregroundStyle(.primary)
                }
            }
            Section("Custom") {
                Stepper(value: $work, in: 5...600, step: 5) { LabeledContent("Work", value: "\(work) s") }
                Stepper(value: $rest, in: 0...600, step: 5) { LabeledContent("Rest", value: "\(rest) s") }
                Stepper(value: $rounds, in: 1...50) { LabeledContent("Rounds", value: "\(rounds)") }
                Stepper(value: $warmup, in: 0...60, step: 5) { LabeledContent("Get ready", value: "\(warmup) s") }
                Toggle("Voice coach", isOn: Binding(get: { VoiceCoach.enabled }, set: { VoiceCoach.enabled = $0 }))
                LabeledContent("Total", value: ActiveSessionView.clock(Double(warmup + rounds * (work + rest) - rest)))
            }
            Section {
                Button {
                    running = true
                } label: {
                    Label("Start", systemImage: "play.fill").font(.headline)
                }
            }
        }
        .navigationTitle("Interval timer")
        .fullScreenCover(isPresented: $running) {
            IntervalRunView(work: work, rest: rest, rounds: rounds, warmup: warmup) { finished in
                if finished { fitness.recordIntervalSession() }
                running = false
            }
        }
    }
}

struct IntervalRunView: View {
    let work: Int
    let rest: Int
    let rounds: Int
    let warmup: Int
    let onClose: (Bool) -> Void

    enum Phase: Equatable { case ready, work(Int), rest(Int), done }

    @State private var started = Date()
    @State private var pausedAt: Date?
    @State private var pausedTotal: TimeInterval = 0
    @State private var lastPhase: Phase = .ready

    /// Where the timer is after `elapsed` seconds, and how long is left in it.
    private func phase(at elapsed: Double) -> (Phase, Double, Double) {
        var t = elapsed
        if t < Double(warmup) { return (.ready, Double(warmup) - t, Double(warmup)) }
        t -= Double(warmup)
        for round in 1...rounds {
            if t < Double(work) { return (.work(round), Double(work) - t, Double(work)) }
            t -= Double(work)
            if round < rounds && rest > 0 {
                if t < Double(rest) { return (.rest(round), Double(rest) - t, Double(rest)) }
                t -= Double(rest)
            }
        }
        return (.done, 0, 1)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let now = pausedAt ?? context.date
            let elapsed = now.timeIntervalSince(started) - pausedTotal
            let state = phase(at: elapsed)
            let current = state.0
            let left = state.1
            let length = state.2
            let colour: Color = {
                switch current {
                case .ready: return .yellow
                case .work: return .green
                case .rest: return .blue
                case .done: return .orange
                }
            }()
            ZStack {
                colour.opacity(0.18).ignoresSafeArea()
                VStack(spacing: 28) {
                    Text(title(current))
                        .font(.system(.largeTitle, design: .rounded, weight: .heavy))
                        .foregroundStyle(colour)
                    ZStack {
                        ActivityRing(progress: current == .done ? 1 : 1 - left / length, colour: colour, lineWidth: 22)
                        Text(current == .done ? "✓" : "\(Int(left.rounded(.up)))")
                            .font(.system(size: 88, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                    }
                    .frame(width: 260, height: 260)
                    HStack(spacing: 20) {
                        Button(current == .done ? tr("Close") : tr("Stop")) { onClose(current == .done) }
                            .buttonStyle(.bordered)
                        if current != .done {
                            Button(pausedAt == nil ? tr("Pause") : tr("Resume")) {
                                if let pausedAt {
                                    pausedTotal += Date().timeIntervalSince(pausedAt)
                                    self.pausedAt = nil
                                } else {
                                    pausedAt = Date()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(colour)
                        }
                    }
                    .controlSize(.large)
                }
            }
            .sensoryFeedback(.impact(weight: .heavy), trigger: current)
            .onChange(of: current) { _, new in
                lastPhase = new
                VoiceCoach.shared.say(spoken(new))
            }
            .onChange(of: Int(left.rounded(.up))) { _, seconds in
                if current != .done, (1...3).contains(seconds) { VoiceCoach.shared.say("\(seconds)", interrupt: false) }
            }
        }
        .onAppear {
            started = Date()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func spoken(_ phase: Phase) -> String {
        switch phase {
        case .ready: return tr("Get ready")
        case .work(let round): return String(format: tr("Round %ld of %ld. Go!"), round, rounds)
        case .rest: return tr("Rest")
        case .done: return tr("Workout complete. Well done!")
        }
    }

    private func title(_ phase: Phase) -> String {
        switch phase {
        case .ready: return tr("Get ready")
        case .work(let round): return String(format: tr("Work %ld/%ld"), round, rounds)
        case .rest: return tr("Rest")
        case .done: return tr("Done!")
        }
    }
}
