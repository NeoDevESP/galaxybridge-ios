import SwiftUI

/// Settings that actually reach the watch.
///
/// Changing a metric toggle or the flush interval sends a HEALTH_CONFIG message,
/// so the watch stops collecting what you turned off. Continuous heart rate is
/// off by default and labelled with its cost, because it is the single setting
/// here that can halve the watch's battery life.
struct SettingsView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator

    @State private var enabled: Set<Metric> = Set(Metric.allCases)
    @State private var continuousHeartRate = false
    @State private var sleepStages = true
    @State private var flushMinutes: Double = 5
    @State private var dirty = false
    @State private var age: Double = Profile.age
    @State private var copying = false
    @State private var copyResult: String?
    @State private var language = AppLanguage.current
    @State private var languageChanged = false

    var body: some View {
        NavigationStack {
            Form {
                Section("What the watch collects") {
                    ForEach(Metric.allCases, id: \.self) { metric in
                        Toggle(Self.label(for: metric), isOn: binding(for: metric))
                    }
                }

                Section {
                    Toggle("Sleep stages", isOn: $sleepStages)
                        .onChange(of: sleepStages) { _, _ in dirty = true }
                } footer: {
                    Text("The watch tracks your nights itself, from movement and every heartbeat, and works out awake, REM, light and deep sleep, breathing rate and skin temperature. Costs some battery overnight.")
                }

                Section {
                    Toggle("Continuous heart rate", isOn: $continuousHeartRate)
                        .onChange(of: continuousHeartRate) { _, _ in dirty = true }
                } footer: {
                    Text("Off by default. Wear OS samples passively most of the time; forcing continuous measurement raises the sampling rate and is the biggest single drain on the watch battery.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Send health data every \(Int(flushMinutes)) min")
                        Slider(value: $flushMinutes, in: 1...30, step: 1)
                            .onChange(of: flushMinutes) { _, _ in dirty = true }
                    }
                } footer: {
                    Text("Samples are queued on the watch and deleted only once this iPhone confirms Apple Health accepted them, so a longer interval costs freshness, never data.")
                }

                Section {
                    Picker("Language", selection: $language) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .onChange(of: language) { _, value in
                        AppLanguage.current = value
                        languageChanged = true
                    }
                    if languageChanged {
                        Button("Close the app to apply") { exit(0) }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("The new language applies the next time the app opens. You can also change it in the iPhone's Settings > GalaxyBridge > Language.")
                }

                GoalsSection(dashboard: coordinator.dashboard)

                Section {
                    Stepper(value: $age, in: 10...100) {
                        LabeledContent("Age", value: "\(Int(age))")
                    }
                    .onChange(of: age) { _, value in Profile.age = value }
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Used only for heart-rate zones. Stays on this iPhone.")
                }

                Section {
                    Button("Apply to the watch") {
                        push()
                    }
                    .disabled(!dirty || !coordinator.client.isConnected)
                } footer: {
                    if !coordinator.client.isConnected {
                        Text("The watch is not connected, so changes cannot be delivered yet.")
                    } else if dirty {
                        Text("Not sent yet.")
                    } else {
                        Text("The watch has these settings.")
                    }
                }

                Section {
                    LabeledContent(
                        "Status",
                        value: coordinator.health.missingEntitlement
                            ? "Not available in this install"
                            : (coordinator.health.authorized ? "Copying" : "Off")
                    )
                    LabeledContent("Samples copied", value: "\(coordinator.health.samplesWritten)")
                    if coordinator.health.authorized {
                        Button(copying ? "Copying…" : "Copy all history to Apple Health") {
                            copying = true
                            Task {
                                let count = await coordinator.copyToAppleHealth()
                                copyResult = "Copied \(count) samples."
                                copying = false
                            }
                        }
                        .disabled(copying)
                        if let copyResult {
                            Text(copyResult).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Request Health access again") {
                        Task { await coordinator.requestHealthAccess() }
                    }
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    if let error = coordinator.health.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Apple Health (optional)")
                } footer: {
                    Text("Your data is always kept in this app. Apple Health is only an extra copy, and it needs an install signed with the HealthKit entitlement, which SideStore cannot provide.")
                }

                Section {
                    NavigationLink {
                        RemindersView()
                    } label: {
                        Label("Reminders", systemImage: "bell.badge")
                    }
                    Button {
                        UserDefaults.standard.set(false, forKey: "onboarding.done")
                    } label: {
                        Label("Show the welcome again", systemImage: "sparkles")
                    }
                }

                Section {
                    NavigationLink {
                        DataQualityView()
                    } label: {
                        Label("Your data and export", systemImage: "externaldrive")
                    }
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "waveform.path")
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear { load() }
        }
    }

    private func binding(for metric: Metric) -> Binding<Bool> {
        Binding(
            get: { enabled.contains(metric) },
            set: { isOn in
                if isOn { enabled.insert(metric) } else { enabled.remove(metric) }
                dirty = true
            }
        )
    }

    private func push() {
        coordinator.watchSettings = BridgeCoordinator.WatchSettings(
            enabled: Metric.allCases.filter { enabled.contains($0) },
            flushMinutes: Int(flushMinutes),
            continuousHeartRate: continuousHeartRate,
            sleepStages: sleepStages
        )
        coordinator.pushHealthConfig()
        dirty = false
    }

    private func load() {
        let settings = coordinator.watchSettings
        enabled = Set(settings.enabled)
        flushMinutes = Double(settings.flushMinutes)
        continuousHeartRate = settings.continuousHeartRate
        sleepStages = settings.sleepStages
        dirty = false
    }

    private static func label(for metric: Metric) -> String {
        switch metric {
        case .steps: return tr("Steps")
        case .heartRate: return tr("Heart rate")
        case .activeEnergy: return tr("Active energy")
        case .distance: return tr("Distance")
        case .floors: return tr("Floors climbed")
        case .spo2: return tr("Blood oxygen")
        case .sleep: return tr("Sleep")
        case .restingHeartRate: return tr("Resting heart rate")
        case .hrv: return tr("Heart rate variability")
        case .skinTemperature: return tr("Skin temperature")
        case .bodyFat: return tr("Body fat")
        case .skeletalMuscle: return tr("Skeletal muscle")
        case .bodyWater: return tr("Body water")
        case .bmr: return tr("Basal metabolic rate")
        case .respiratoryRate: return tr("Respiratory rate")
        }
    }
}

/// Its own view so the goals get a real binding: `dashboard` is a plain
/// property on the coordinator, not a published one, so it cannot be projected
/// through `$coordinator`.
private struct GoalsSection: View {
    @ObservedObject var dashboard: HealthDashboard

    var body: some View {
        Section("Daily goals") {
            goalRow("Steps", value: $dashboard.stepGoal, step: 500)
            goalRow("Active energy (kcal)", value: $dashboard.energyGoal, step: 50)
            goalRow("Distance (m)", value: $dashboard.distanceGoal, step: 500)
        }
    }

    private func goalRow(_ title: String, value: Binding<Double>, step: Double) -> some View {
        Stepper(value: value, in: step...100_000, step: step) {
            LabeledContent(title, value: value.wrappedValue.noDecimals)
        }
    }
}
