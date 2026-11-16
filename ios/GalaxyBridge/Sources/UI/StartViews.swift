import SwiftUI

// MARK: - Splash

/// Continues the system launch screen (same colour, same logo) into the app:
/// the watch settles, the name fades in, then the whole thing fades away.
struct SplashView: View {
    let onFinish: () -> Void
    @State private var settled = false
    @State private var beat = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 1.0, green: 0.44, blue: 0.33), Color("LaunchBackground"), Color(red: 0.69, green: 0.09, blue: 0.55)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(settled ? 1 : 0)
            Color("LaunchBackground").opacity(settled ? 0 : 1)
            VStack(spacing: 22) {
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180)
                    .scaleEffect(beat ? 1.06 : (settled ? 1 : 0.94))
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                VStack(spacing: 4) {
                    Text("GalaxyBridge")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("Your watch, your health, your training")
                        .font(.subheadline.weight(.medium))
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .opacity(settled ? 1 : 0)
                .offset(y: settled ? 0 : 12)
            }
        }
        .ignoresSafeArea()
        .task {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) { settled = true }
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeOut(duration: 0.18)) { beat = true }
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { beat = false }
            try? await Task.sleep(for: .milliseconds(650))
            onFinish()
        }
    }
}

// MARK: - First run

struct OnboardingView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @EnvironmentObject private var coordinator: BridgeCoordinator
    let onDone: () -> Void

    @State private var page = 0
    @State private var language = AppLanguage.current
    @State private var sex: Sex = .male
    @State private var age: Double = Profile.age
    @State private var height: Double = 175
    @State private var weight: Double = 75
    @State private var goal: FitnessGoal = .maintain
    @State private var reminders = Reminders.settings

    private let pages = 5

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                profile.tag(1)
                watch.tag(2)
                sleepPage.tag(3)
                remindersPage.tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button {
                if page < pages - 1 {
                    if page == 1 { saveProfile() }
                    withAnimation { page += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(page < pages - 1 ? tr("Continue") : tr("Start"))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
        }
        .groupedBackground()
        .sensoryFeedback(.selection, trigger: page)
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image("LaunchLogo")
                    .resizable().scaledToFit().frame(width: 110)
                    .padding(22)
                    .background(
                        LinearGradient(
                            colors: [Color(red: 1.0, green: 0.44, blue: 0.33), Color(red: 0.69, green: 0.09, blue: 0.55)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 36, style: .continuous)
                    )
                    .padding(.top, 30)
                Text("Welcome to GalaxyBridge")
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                Text("Your Galaxy Watch, your health and your training, together on your iPhone.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 14) {
                    feature("heart.text.square.fill", .pink, "Health from the watch", "Heart rate, HRV, blood oxygen, ECG, body composition and more.")
                    feature("bed.double.fill", .indigo, "Sleep with stages", "Awake, REM, light and deep, worked out by the watch itself.")
                    feature("dumbbell.fill", .orange, "Gym, nutrition and body", "Routines, progression, barcode scanner, fasting and photos.")
                    feature("lock.fill", .green, "Private", "Everything stays on this iPhone. No account, no cloud.")
                }
                .cardStyle()
                Picker("Language", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: language) { _, value in AppLanguage.current = value }
                if language != .system && !AppLanguage.active.hasPrefix(language.rawValue) {
                    Text("The language changes the next time the app opens.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .padding(.bottom, 30)
        }
    }

    private var profile: some View {
        Form {
            Section {
                Picker("Sex", selection: $sex) {
                    ForEach(Sex.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Stepper(value: $age, in: 12...100) { LabeledContent("Age", value: "\(Int(age))") }
                Stepper(value: $height, in: 120...230) { LabeledContent("Height", value: "\(Int(height)) cm") }
                Stepper(value: $weight, in: 30...250, step: 0.5) {
                    LabeledContent("Weight", value: "\(weight.oneDecimal) kg")
                }
                Picker("Goal", selection: $goal) {
                    ForEach(FitnessGoal.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("About you")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .padding(.top, 30)
            } footer: {
                Text("Used for heart-rate zones, calorie targets and the watch's body composition sensor. It stays on this iPhone.")
            }
        }
        .scrollContentBackground(.hidden)
        .onAppear {
            sex = fitness.data.profile.sex
            height = fitness.data.profile.heightCm
            goal = fitness.data.profile.goal
            weight = fitness.latestWeight?.kg ?? weight
        }
    }

    private var watch: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Set up the watch")
                    .font(.title2.bold())
                    .padding(.top, 30)
                step(1, "Install the watch app", "From the tablet console, which finds the watch and installs GalaxyBridge without typing addresses.")
                step(2, "Turn on Health Platform's developer mode", "On the watch: Settings > Apps > Health Platform, and tap it about ten times until [Dev mode] appears. This unlocks blood oxygen, HRV, ECG, body composition, skin temperature and sleep stages.")
                step(3, "Link it to this iPhone", "In My Watch, type the 6-digit code shown on the watch. After that it reconnects by itself.")
                Text("You can do this later; the app works for gym, nutrition and body tracking straight away.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var sleepPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sleep and readiness")
                    .font(.title2.bold())
                    .padding(.top, 30)
                feature("moon.zzz.fill", .indigo, "Wear it to bed", "The watch notices when you fall asleep and records every heartbeat and movement. Keep 20% battery or more at bedtime.")
                feature("bolt.heart.fill", .mint, "Readiness every morning", "After a few nights the app learns your usual HRV and resting heart rate and scores how recovered you are.")
                feature("chart.xyaxis.line", .blue, "Gets better with time", "Baselines need about a week of data. The first days are a starting point.")
            }
            .padding()
        }
    }

    private var remindersPage: some View {
        Form {
            Section {
                Toggle("Drink water", isOn: $reminders.water)
                Toggle("Planned workout", isOn: $reminders.workout)
                Toggle("Morning readiness", isOn: $reminders.morning)
                Toggle("Bedtime: wear the watch", isOn: $reminders.bedtime)
                Toggle("Fast complete", isOn: $reminders.fasting)
            } header: {
                Text("Reminders")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                    .textCase(nil)
                    .padding(.top, 30)
            } footer: {
                Text("Times can be changed later in Settings > Reminders.")
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func feature(_ symbol: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(title)).font(.headline)
                Text(tr(detail)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(tr(title)).font(.headline)
                Text(tr(detail)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func saveProfile() {
        Profile.age = age
        fitness.updateProfile {
            $0.sex = sex
            $0.heightCm = height
            $0.goal = goal
        }
        if abs((fitness.latestWeight?.kg ?? 0) - weight) > 0.05 {
            fitness.addWeight(WeightEntry(date: Date(), kg: weight))
        }
        coordinator.pushHealthConfig()
    }

    private func finish() {
        Reminders.settings = reminders
        let wanted = reminders.water || reminders.workout || reminders.morning || reminders.bedtime || reminders.fasting
        Task {
            if wanted { await Reminders.requestPermission() }
            Reminders.reschedule(fitness: fitness)
        }
        onDone()
    }
}

// MARK: - Reminder settings

struct RemindersView: View {
    @EnvironmentObject private var fitness: FitnessStore
    @State private var settings = Reminders.settings
    @State private var denied = false

    var body: some View {
        Form {
            Section {
                Toggle("Drink water", isOn: $settings.water)
                if settings.water {
                    Stepper(value: $settings.waterEveryHours, in: 1...4) {
                        LabeledContent("Every", value: "\(settings.waterEveryHours) h")
                    }
                    Stepper(value: $settings.waterFrom, in: 5...12) {
                        LabeledContent("From", value: "\(settings.waterFrom):00")
                    }
                    Stepper(value: $settings.waterTo, in: 14...23) {
                        LabeledContent("Until", value: "\(settings.waterTo):00")
                    }
                }
            }
            Section {
                Toggle("Planned workout", isOn: $settings.workout)
                if settings.workout {
                    timePicker("At", hour: $settings.workoutHour, minute: $settings.workoutMinute)
                }
            } footer: {
                Text("Only on days with a routine in your weekly plan.")
            }
            Section {
                Toggle("Morning readiness", isOn: $settings.morning)
                if settings.morning {
                    timePicker("At", hour: $settings.morningHour, minute: $settings.morningMinute)
                }
                Toggle("Bedtime: wear the watch", isOn: $settings.bedtime)
                if settings.bedtime {
                    timePicker("At", hour: $settings.bedtimeHour, minute: $settings.bedtimeMinute)
                }
            }
            Section {
                Toggle("Fast complete", isOn: $settings.fasting)
            }
            if denied {
                Section {
                    Text("Notifications are off for GalaxyBridge. Turn them on in the iPhone's Settings > Notifications.")
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("Reminders")
        .onChange(of: settings) { _, value in
            Reminders.settings = value
            Task {
                denied = !(await Reminders.requestPermission())
                Reminders.reschedule(fitness: fitness)
                Reminders.fastChanged(fitness.activeFast)
            }
        }
    }

    private func timePicker(_ title: LocalizedStringKey, hour: Binding<Int>, minute: Binding<Int>) -> some View {
        DatePicker(
            title,
            selection: Binding(
                get: {
                    Calendar.current.date(bySettingHour: hour.wrappedValue, minute: minute.wrappedValue, second: 0, of: Date()) ?? Date()
                },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    hour.wrappedValue = parts.hour ?? 0
                    minute.wrappedValue = parts.minute ?? 0
                }
            ),
            displayedComponents: .hourAndMinute
        )
    }
}
