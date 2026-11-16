import Charts
import SwiftUI

/// Gym home: start a session, routines, history and progress.
struct GymView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @State private var editing: Routine?
    @State private var showActive = false

    var body: some View {
        List {
            Section {
                if fitness.activeSession != nil {
                    Button {
                        showActive = true
                    } label: {
                        Label("Continue current workout", systemImage: "play.circle.fill")
                            .font(.headline)
                    }
                } else {
                    Button {
                        fitness.startSession(from: nil)
                        showActive = true
                    } label: {
                        Label("Start an empty workout", systemImage: "plus.circle.fill")
                            .font(.headline)
                    }
                }
            }

            Section {
                ForEach(fitness.data.routines) { routine in
                    routineRow(routine, editable: true)
                }
                .onDelete { offsets in
                    for index in offsets { fitness.deleteRoutine(fitness.data.routines[index].id) }
                }
                Button {
                    editing = Routine(name: "New routine", items: [])
                } label: {
                    Label("Create a routine", systemImage: "square.and.pencil")
                }
            } header: {
                Text("My routines")
            }

            Section("Templates") {
                ForEach(FitnessLibrary.routines) { routine in
                    routineRow(routine, editable: false)
                }
            }

            Section {
                Toggle(isOn: Binding(get: { VoiceCoach.enabled }, set: { VoiceCoach.enabled = $0 })) {
                    Label("Voice coach", systemImage: "speaker.wave.2.fill")
                }
            } footer: {
                Text("Speaks the end of rest, interval changes and counted reps.")
            }

            Section("Progress") {
                NavigationLink {
                    GymStatsView()
                } label: {
                    Label("Statistics", systemImage: "chart.bar.xaxis")
                }
                NavigationLink {
                    RecordsView()
                } label: {
                    Label("Personal records", systemImage: "trophy.fill")
                }
                NavigationLink {
                    SessionHistoryView()
                } label: {
                    LabeledContent {
                        Text("\(fitness.data.sessions.count)")
                    } label: {
                        Label("Workout history", systemImage: "clock.arrow.circlepath")
                    }
                }
                let weekly = fitness.weeklySetsByMuscle
                if !weekly.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sets this week by muscle").font(.caption).foregroundStyle(.secondary)
                        Chart(weekly, id: \.muscle) { entry in
                            BarMark(
                                x: .value("Sets", entry.sets),
                                y: .value("Muscle", entry.muscle.title)
                            )
                            .foregroundStyle(Color.orange.gradient)
                        }
                        .frame(height: CGFloat(weekly.count) * 28 + 20)
                    }
                }
            }
        }
        .navigationTitle("Gym")
        .sheet(item: $editing) { routine in
            NavigationStack {
                RoutineEditorView(routine: routine) { saved in
                    fitness.saveRoutine(saved)
                    editing = nil
                }
            }
        }
        .fullScreenCover(isPresented: $showActive) {
            NavigationStack { ActiveSessionView() }
        }
    }

    private func routineRow(_ routine: Routine, editable: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(routine.name)).fontWeight(.medium)
                Text(routine.items.map { fitness.exerciseName($0.exerciseID) }.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if editable {
                Button {
                    editing = routine
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    var copy = routine
                    copy.id = UUID()
                    fitness.saveRoutine(copy)
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .buttonStyle(.borderless)
            }
            Button {
                fitness.startSession(from: routine)
                showActive = true
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(fitness.activeSession != nil)
        }
    }
}

// MARK: - Active session

struct ActiveSessionView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var coordinator: BridgeCoordinator
    @Environment(\.dismiss) private var dismiss

    @State private var picking = false
    @State private var restEndsAt: Date?
    @State private var confirmDiscard = false

    var body: some View {
        Group {
            if let session = fitness.activeSession {
                List {
                    Section {
                        header(session)
                        WatchWorkoutRow(client: coordinator.client, sessionID: session.id)
                    }
                    ForEach(session.exercises) { exercise in
                        Section {
                            ExerciseSetsEditor(exerciseID: exercise.id) { restEndsAt = Date().addingTimeInterval(Double(fitness.data.restSeconds)) }
                        } header: {
                            HStack {
                                Text(fitness.exerciseName(exercise.exerciseID))
                                Spacer()
                                if let last = fitness.lastWeight(for: exercise.exerciseID) {
                                    Text("last \(last.formatted()) kg")
                                }
                            }
                        }
                    }
                    Section {
                        Button {
                            picking = true
                        } label: {
                            Label("Add exercise", systemImage: "plus")
                        }
                    }
                    Section {
                        Button("Discard workout", role: .destructive) { confirmDiscard = true }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                EmptyHint(systemImage: "dumbbell", title: "No workout running", detail: "")
            }
        }
        .navigationTitle(fitness.activeSession?.name ?? "Workout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Finish") {
                    WatchWorkoutRow.stopIfStarted(coordinator.client, sessionID: fitness.activeSession?.id)
                    fitness.finishActive()
                    dismiss()
                }
                .fontWeight(.semibold)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let restEndsAt {
                RestTimerBar(endsAt: restEndsAt) { self.restEndsAt = nil }
            }
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                ExercisePickerView { exercise in
                    fitness.addExerciseToActive(exercise.id)
                    picking = false
                }
            }
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                WatchWorkoutRow.stopIfStarted(coordinator.client, sessionID: fitness.activeSession?.id)
                fitness.discardActive()
                dismiss()
            }
        }
    }

    private func header(_ session: GymSession) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack {
                VStack(alignment: .leading) {
                    Text("Duration").font(.caption).foregroundStyle(.secondary)
                    Text(Self.clock(context.date.timeIntervalSince(session.start)))
                        .font(.title2.monospacedDigit().weight(.semibold))
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Volume").font(.caption).foregroundStyle(.secondary)
                    Text("\(session.volume.noDecimals) kg").font(.title3.monospacedDigit())
                }
                VStack(alignment: .trailing) {
                    Text("Sets").font(.caption).foregroundStyle(.secondary)
                    Text("\(session.completedSets.count)").font(.title3.monospacedDigit())
                }
                .padding(.leading, 12)
            }
        }
    }

    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

/// The watch recording alongside a gym session: started on its own when the
/// session opens with the watch linked, live heart rate and zone here, and
/// finished with the session, so one tap on the iPhone gives a strength
/// workout with heart rate and calories on both.
struct WatchWorkoutRow: View {
    @ObservedObject var client: BridgeClient
    @EnvironmentObject private var fitness: FitnessStore
    let sessionID: UUID

    @AppStorage("gym.useWatch") private var useWatch = true

    private static let startedKey = "gym.watchStartedFor"

    static func stopIfStarted(_ client: BridgeClient, sessionID: UUID?) {
        guard let sessionID,
              UserDefaults.standard.string(forKey: startedKey) == sessionID.uuidString else { return }
        client.controlWatchWorkout("stop")
        UserDefaults.standard.removeObject(forKey: startedKey)
    }

    var body: some View {
        Group {
            if let live = client.liveWorkout {
                let zone = zoneIndex(live.heartRate)
                HStack(spacing: 14) {
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(live.heartRate > 0 ? "\(live.heartRate) bpm" : "-- bpm")
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(zoneColour(zone))
                        Text(zone > 0 ? String(format: tr("Zone %ld"), zone) : tr("Heart rate"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(live.energyKcal)) kcal").font(.headline.monospacedDigit())
                        Text(live.paused ? tr("Paused on the watch") : tr("Recording on the watch"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if client.isConnected {
                Toggle(isOn: $useWatch) {
                    Label("Record on the watch", systemImage: "applewatch")
                }
                if useWatch {
                    Button {
                        start()
                    } label: {
                        Label("Start heart rate on the watch", systemImage: "heart.circle")
                    }
                }
            } else {
                Label("Watch not connected: heart rate is not recorded", systemImage: "applewatch.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            // Once per session, and only when nothing is recording yet.
            if useWatch, client.isConnected, client.liveWorkout == nil,
               UserDefaults.standard.string(forKey: Self.startedKey) != sessionID.uuidString {
                start()
            }
        }
        .onChange(of: client.liveWorkout) { _, live in
            if let live { fitness.noteWatch(live) }
        }
    }

    private func start() {
        client.controlWatchWorkout("start:STRENGTH")
        UserDefaults.standard.set(sessionID.uuidString, forKey: Self.startedKey)
    }

    private func zoneIndex(_ bpm: Int) -> Int {
        let zones = HealthMath.zones(age: Profile.age)
        let value = Double(bpm)
        guard let first = zones.first, value >= first.lower else { return 0 }
        return zones.last(where: { value >= $0.lower })?.id ?? 0
    }

    private func zoneColour(_ zone: Int) -> Color {
        zone == 0 ? .primary : [Color.gray, .blue, .green, .orange, .red][max(0, min(4, zone - 1))]
    }
}

/// The sets of one exercise in the running session.
struct ExerciseSetsEditor: View {
    @EnvironmentObject private var fitness: FitnessStore
    let exerciseID: UUID
    let onSetDone: () -> Void

    @State private var plateWeight: Double?
    @State private var countingReps = false
    @State private var showInfo = false

    private var exercise: SessionExercise? {
        fitness.activeSession?.exercises.first { $0.id == exerciseID }
    }

    var body: some View {
        if let exercise {
            let workReps = exercise.sets.filter { !$0.isWarmup }.map(\.reps).max() ?? 10
            HStack(alignment: .top) {
                if let tip = fitness.suggestion(for: exercise.exerciseID, targetReps: workReps) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("\(tip.weight.formatted()) kg × \(tip.reps)", systemImage: "arrow.up.right.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(tip.reason).font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("First time: pick a weight you can lift for all the reps with good form.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button {
                        fitness.addWarmups(to: exerciseID)
                    } label: {
                        Label("Add warm-up sets", systemImage: "flame")
                    }
                    Button {
                        plateWeight = exercise.sets.filter { !$0.isWarmup }.map(\.weight).max() ?? 60
                    } label: {
                        Label("Plate calculator", systemImage: "circle.grid.2x1")
                    }
                    Button {
                        countingReps = true
                    } label: {
                        Label("Count reps with the camera", systemImage: "figure.strengthtraining.functional")
                    }
                    if fitness.exercise(exercise.exerciseID)?.instructions?.isEmpty == false {
                        Button {
                            showInfo = true
                        } label: {
                            Label("How to do it", systemImage: "info.circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
            .fullScreenCover(isPresented: $countingReps) {
                RepCounterView(
                    movement: RepMovement.guess(from: fitness.exercise(exercise.exerciseID)?.name ?? "")
                ) { reps in
                    fitness.updateActive { session in
                        guard let e = session.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
                        // Fill the first set not done yet, or add one.
                        if let s = session.exercises[e].sets.firstIndex(where: { !$0.done && !$0.isWarmup }) {
                            session.exercises[e].sets[s].reps = reps
                            session.exercises[e].sets[s].done = true
                        } else {
                            let weight = session.exercises[e].sets.last?.weight ?? 0
                            session.exercises[e].sets.append(SetEntry(weight: weight, reps: reps, done: true))
                        }
                    }
                    onSetDone()
                }
            }
            .sheet(isPresented: $showInfo) {
                if let info = fitness.exercise(exercise.exerciseID) {
                    NavigationStack { ExerciseInfoView(exercise: info) }
                }
            }
            .sheet(item: Binding(
                get: { plateWeight.map { PlateTarget(kg: $0) } },
                set: { plateWeight = $0?.kg }
            )) { target in
                NavigationStack { PlateCalculatorView(total: target.kg) }
                    .presentationDetents([.medium, .large])
            }

            HStack {
                Text("Set").frame(width: 32, alignment: .leading)
                Text("kg").frame(maxWidth: .infinity)
                Text("reps").frame(maxWidth: .infinity)
                Image(systemName: "checkmark").frame(width: 36)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                HStack {
                    Text(set.isWarmup ? "W" : "\(index + 1 - exercise.sets.filter(\.isWarmup).count)")
                        .frame(width: 32, alignment: .leading)
                        .foregroundStyle(set.isWarmup ? .orange : .secondary)
                    NumberField(placeholder: "0", value: weightBinding(set.id))
                        .frame(maxWidth: .infinity)
                    NumberField(placeholder: "0", value: repsBinding(set.id), decimals: false)
                        .frame(maxWidth: .infinity)
                    Button {
                        let wasDone = set.done
                        update(set.id) { $0.done.toggle() }
                        if !wasDone { onSetDone() }
                    } label: {
                        Image(systemName: set.done ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(set.done ? .green : .secondary)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                    .sensoryFeedback(.impact(weight: .medium), trigger: set.done)
                    .frame(width: 36)
                }
                .listRowBackground(set.done ? Color.green.opacity(0.08) : nil)
            }
            .onDelete { offsets in
                fitness.updateActive { session in
                    guard let e = session.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
                    session.exercises[e].sets.remove(atOffsets: offsets)
                    if session.exercises[e].sets.isEmpty { session.exercises.remove(at: e) }
                }
            }

            Button {
                fitness.updateActive { session in
                    guard let e = session.exercises.firstIndex(where: { $0.id == exerciseID }) else { return }
                    let last = session.exercises[e].sets.last
                    session.exercises[e].sets.append(SetEntry(weight: last?.weight ?? 0, reps: last?.reps ?? 10))
                }
            } label: {
                Label("Add set", systemImage: "plus")
                    .font(.subheadline)
            }
        }
    }

    private func update(_ setID: UUID, _ change: (inout SetEntry) -> Void) {
        fitness.updateActive { session in
            guard let e = session.exercises.firstIndex(where: { $0.id == exerciseID }),
                  let s = session.exercises[e].sets.firstIndex(where: { $0.id == setID }) else { return }
            change(&session.exercises[e].sets[s])
        }
    }

    private func current(_ setID: UUID) -> SetEntry? {
        exercise?.sets.first { $0.id == setID }
    }

    private func weightBinding(_ setID: UUID) -> Binding<Double> {
        Binding(
            get: { current(setID)?.weight ?? 0 },
            set: { value in update(setID) { $0.weight = value } }
        )
    }

    private func repsBinding(_ setID: UUID) -> Binding<Double> {
        Binding(
            get: { Double(current(setID)?.reps ?? 0) },
            set: { value in update(setID) { $0.reps = Int(value) } }
        )
    }
}

private struct PlateTarget: Identifiable {
    let kg: Double
    var id: Double { kg }
}

/// Counts down the rest between sets.
struct RestTimerBar: View {
    let endsAt: Date
    let onFinish: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = endsAt.timeIntervalSince(context.date)
            HStack {
                Image(systemName: "timer")
                Text(left > 0 ? "Rest " + ActiveSessionView.clock(left) : "Rest over, next set!")
                    .font(.headline.monospacedDigit())
                Spacer()
                Button(left > 0 ? "Skip" : "OK") { onFinish() }
                    .buttonStyle(.bordered)
            }
            .padding()
            .background(left > 0 ? Color.blue.opacity(0.15) : Color.green.opacity(0.2))
            .background(.regularMaterial)
            .onChange(of: Int(left.rounded(.up))) { _, seconds in
                if seconds == 10 { VoiceCoach.shared.say(tr("10 seconds")) }
                if seconds == 0 { VoiceCoach.shared.say(tr("Rest over. Next set!")) }
            }
        }
    }
}

/// A text field for a number that keeps what the user is typing ("72.")
/// instead of reformatting it on every keystroke.
struct NumberField: View {
    let placeholder: String
    @Binding var value: Double
    var decimals = true

    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(decimals ? .decimalPad : .numberPad)
            .multilineTextAlignment(.center)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { text = Self.format(value) }
            // Follow changes made elsewhere (a serving button, a copied set)
            // without fighting the user's own typing, which already matches.
            .onChange(of: value) { _, new in
                let typed = Double(text.replacingOccurrences(of: ",", with: ".")) ?? 0
                if typed != new { text = Self.format(new) }
            }
            .onChange(of: text) { _, new in
                let cleaned = new.replacingOccurrences(of: ",", with: ".")
                if cleaned.isEmpty {
                    value = 0
                } else if let parsed = Double(cleaned) {
                    value = parsed
                }
            }
    }

    static func format(_ value: Double) -> String {
        guard value != 0 else { return "" }
        return value.rounded() == value ? String(Int(value)) : String(value)
    }
}

@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// MARK: - Exercise picker

struct ExercisePickerView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @Environment(\.dismiss) private var dismiss
    let onPick: (Exercise) -> Void

    @State private var search = ""
    @State private var creating = false
    @State private var newName = ""
    @State private var newMuscle: MuscleGroup = .chest
    @State private var newEquipment = "Barbell"
    @State private var showAll = false
    @State private var equipment: String?
    @State private var info: Exercise?

    private var filtered: [Exercise] {
        // Searching always looks through all ~900; browsing shows the short
        // list unless asked for everything. Stretches only when searched for.
        var list = search.isEmpty && !showAll ? fitness.commonExercises : fitness.allExercises
        if search.isEmpty { list = list.filter { $0.category != "stretching" } }
        if let equipment { list = list.filter { $0.equipment == equipment } }
        guard !search.isEmpty else { return list }
        return list.filter { $0.name.localizedCaseInsensitiveContains(search) || tr($0.name).localizedCaseInsensitiveContains(search) }
    }

    private var equipmentKinds: [String] {
        Array(Set(fitness.allExercises.map(\.equipment))).sorted { tr($0) < tr($1) }
    }

    var body: some View {
        List {
            if creating {
                Section("New exercise") {
                    TextField("Name", text: $newName)
                    Picker("Muscle", selection: $newMuscle) {
                        ForEach(MuscleGroup.allCases) { Text($0.title).tag($0) }
                    }
                    TextField("Equipment", text: $newEquipment)
                    Button("Add") {
                        let exercise = fitness.addCustomExercise(
                            name: newName.trimmingCharacters(in: .whitespaces),
                            muscle: newMuscle,
                            equipment: newEquipment
                        )
                        onPick(exercise)
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section {
                Toggle("Show all exercises", isOn: $showAll)
                Picker("Equipment", selection: $equipment) {
                    Text("Any").tag(String?.none)
                    ForEach(equipmentKinds, id: \.self) { kind in
                        Text(tr(kind)).tag(String?.some(kind))
                    }
                }
            } footer: {
                Text("\(fitness.allExercises.count) exercises, most with step-by-step instructions and photos from free-exercise-db.")
            }
            ForEach(MuscleGroup.allCases) { muscle in
                let group = filtered.filter { $0.muscle == muscle }
                if !group.isEmpty {
                    Section(muscle.title) {
                        ForEach(group) { exercise in
                            HStack {
                                Button {
                                    onPick(exercise)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(exercise.displayName).foregroundStyle(.primary)
                                        Text(tr(exercise.equipment) + (exercise.level.map { " · " + tr($0.capitalized) } ?? ""))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if exercise.instructions?.isEmpty == false {
                                    Button {
                                        info = exercise
                                    } label: {
                                        Image(systemName: "info.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $info) { exercise in
            NavigationStack { ExerciseInfoView(exercise: exercise) }
        }
        .searchable(text: $search, prompt: "Search exercises")
        .navigationTitle("Exercises")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(creating ? "Hide" : "New") { creating.toggle() }
            }
        }
    }
}

// MARK: - Routine editor

struct RoutineEditorView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @Environment(\.dismiss) private var dismiss
    @State var routine: Routine
    let onSave: (Routine) -> Void
    @State private var picking = false

    var body: some View {
        List {
            Section("Name") {
                TextField("Routine name", text: $routine.name)
            }
            Section("Exercises") {
                ForEach($routine.items) { $item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(fitness.exerciseName(item.exerciseID)).fontWeight(.medium)
                        Stepper("\(item.sets) sets", value: $item.sets, in: 1...10)
                        Stepper("\(item.reps) reps", value: $item.reps, in: 1...50)
                    }
                }
                .onDelete { routine.items.remove(atOffsets: $0) }
                .onMove { routine.items.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    picking = true
                } label: {
                    Label("Add exercise", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Routine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { onSave(routine) }
                    .disabled(routine.name.isEmpty || routine.items.isEmpty)
            }
        }
        .sheet(isPresented: $picking) {
            NavigationStack {
                ExercisePickerView { exercise in
                    routine.items.append(RoutineItem(exerciseID: exercise.id, sets: 3, reps: 10))
                    picking = false
                }
            }
        }
    }
}

// MARK: - History and records

struct SessionHistoryView: View {
    @EnvironmentObject private var fitness: FitnessStore

    var body: some View {
        List {
            if fitness.data.sessions.isEmpty {
                EmptyHint(
                    systemImage: "dumbbell",
                    title: "No workouts logged",
                    detail: "Finish a gym session and it is saved here."
                )
            }
            ForEach(fitness.data.sessions) { session in
                NavigationLink {
                    SessionDetailView(session: session)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tr(session.name)).fontWeight(.medium)
                        Text(
                            session.start.formatted(date: .abbreviated, time: .shortened)
                                + " · " + session.duration.hoursMinutes
                                + " · \(session.volume.noDecimals) kg"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets { fitness.deleteSession(fitness.data.sessions[index].id) }
            }
        }
        .navigationTitle("History")
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var fitness: FitnessStore
    let session: GymSession

    var body: some View {
        List {
            Section {
                LabeledContent("Date", value: session.start.formatted(date: .complete, time: .shortened))
                LabeledContent("Duration", value: session.duration.hoursMinutes)
                LabeledContent("Volume", value: "\(session.volume.noDecimals) kg")
                LabeledContent("Sets", value: "\(session.completedSets.count)")
                if let average = session.avgHeartRate {
                    LabeledContent("Average heart rate", value: "\(average.noDecimals) bpm")
                }
                if let maximum = session.maxHeartRate {
                    LabeledContent("Maximum heart rate", value: "\(maximum.noDecimals) bpm")
                }
                if let energy = session.energyKcal, energy > 0 {
                    LabeledContent("Active energy", value: "\(energy.noDecimals) kcal")
                }
            }
            ForEach(session.exercises) { exercise in
                Section {
                    ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                        LabeledContent("Set \(index + 1)", value: "\(set.weight.formatted()) kg × \(set.reps)")
                    }
                    NavigationLink("Progress") {
                        ExerciseProgressView(exerciseID: exercise.exerciseID)
                    }
                } header: {
                    Text(fitness.exerciseName(exercise.exerciseID))
                }
            }
        }
        .navigationTitle(session.name)
    }
}

struct RecordsView: View {
    @EnvironmentObject private var fitness: FitnessStore

    var body: some View {
        List {
            let records = fitness.personalRecords
            if records.isEmpty {
                EmptyHint(
                    systemImage: "trophy",
                    title: "No records yet",
                    detail: "Your best set for each exercise appears here."
                )
            }
            ForEach(records) { record in
                NavigationLink {
                    ExerciseProgressView(exerciseID: record.exerciseID)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name).fontWeight(.medium)
                            Text("\(record.weight.formatted()) kg × \(record.reps) · "
                                + record.date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(record.oneRepMax.noDecimals + " kg").font(.headline.monospacedDigit())
                            Text("est. 1RM").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Personal records")
    }
}

struct ExerciseProgressView: View {
    @EnvironmentObject private var fitness: FitnessStore
    let exerciseID: String

    var body: some View {
        let points = fitness.history(for: exerciseID)
        List {
            if points.count >= 2 {
                Section("Estimated one-rep max") {
                    Chart(points) { point in
                        LineMark(x: .value("Date", point.date), y: .value("kg", point.oneRepMax))
                            .interpolationMethod(.monotone)
                        PointMark(x: .value("Date", point.date), y: .value("kg", point.oneRepMax))
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 200)
                }
            }
            Section("Sessions") {
                if points.isEmpty {
                    Text("Not logged yet.").foregroundStyle(.secondary)
                }
                ForEach(points.reversed()) { point in
                    LabeledContent(point.date.formatted(date: .abbreviated, time: .omitted)) {
                        Text("top \(point.topWeight.formatted()) kg · 1RM \(point.oneRepMax.noDecimals)")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            Section {
                Text("One-rep max is estimated with the Epley formula from your best set. It is most accurate for sets of 1-10 reps.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(fitness.exerciseName(exerciseID))
    }
}
