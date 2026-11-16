import Charts
import MapKit
import SwiftUI

extension HealthKind {
    var tint: Color {
        switch self {
        case .steps: return .green
        case .energy: return .red
        case .distance: return .blue
        case .floors: return .orange
        case .heartRate, .restingHeartRate: return .pink
        case .hrv: return .purple
        case .spo2: return .teal
        case .respiratoryRate: return .cyan
        case .skinTemperature: return .orange
        case .bodyFat, .skeletalMuscle, .bodyWater, .bmr: return .indigo
        }
    }
}

/// Every category in one list, the way Apple's Health app has a Browse tab.
struct BrowseView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator

    var body: some View {
        NavigationStack {
            List {
                Section("Activity") {
                    row(.steps)
                    row(.distance)
                    row(.energy)
                    row(.floors)
                }

                Section("Heart") {
                    NavigationLink {
                        HeartView()
                    } label: {
                        Label("Heart rate today", systemImage: "heart.fill")
                            .foregroundStyle(.primary)
                    }
                    row(.heartRate)
                    row(.restingHeartRate)
                    row(.hrv)
                }

                Section("Heart health") {
                    NavigationLink {
                        EcgListView()
                    } label: {
                        Label("ECG recordings", systemImage: "waveform.path.ecg.rectangle")
                    }
                }

                Section("Respiratory") {
                    row(.spo2)
                    row(.respiratoryRate)
                }

                Section("Sleep") {
                    NavigationLink {
                        SleepDetailView()
                    } label: {
                        Label("Sleep and stages", systemImage: "bed.double.fill")
                    }
                    row(.skinTemperature)
                }

                Section("Body measurements") {
                    NavigationLink {
                        BodyCompositionView(dashboard: coordinator.dashboard)
                    } label: {
                        Label("Body composition", systemImage: "figure.arms.open")
                    }
                    row(.bodyFat)
                    row(.skeletalMuscle)
                    row(.bodyWater)
                    row(.bmr)
                }

                Section("Workouts") {
                    NavigationLink {
                        WorkoutListView()
                    } label: {
                        Label("All workouts", systemImage: "figure.run")
                    }
                }

                Section("Your progress") {
                    NavigationLink {
                        TrendsView()
                    } label: {
                        Label("Trends and records", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    NavigationLink {
                        DataQualityView()
                    } label: {
                        Label("Your data and export", systemImage: "externaldrive")
                    }
                }

                Section {
                } footer: {
                    Text("Blood oxygen, HRV, ECG, body composition, skin temperature and sleep stages come from the Samsung sensors and need Health Platform's developer mode on the watch.")
                }
            }
            .navigationTitle("Browse")
            .navigationDestination(for: HealthKind.self) { kind in
                MetricDetailView(kind: kind)
            }
        }
    }

    private func row(_ kind: HealthKind) -> some View {
        NavigationLink(value: kind) {
            Label {
                Text(kind.title)
            } icon: {
                Image(systemName: kind.systemImage).foregroundStyle(kind.tint)
            }
        }
    }
}

// MARK: - Heart

/// One day of heart rate: the curve with its range, resting estimate and how
/// the readings fall into training zones.
struct HeartView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator

    @State private var day = Date()
    @State private var points: [LocalHealthStore.TimePoint] = []
    @State private var zones: [HealthTrends.ZoneShare] = []
    @State private var loading = true

    private var values: [Double] { points.map(\.value) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                dayPicker

                if loading {
                    ProgressView().frame(height: 220).frame(maxWidth: .infinity)
                } else if points.isEmpty {
                    EmptyHint(
                        systemImage: "heart.slash",
                        title: "No heart rate this day",
                        detail: "The watch records heart rate while it is on your wrist and the app receives it on the next sync."
                    )
                } else {
                    chart
                        .cardStyle()
                    stats
                    zoneSection
                        .cardStyle()
                }

                NavigationLink(value: HealthKind.restingHeartRate) {
                    Label("Resting heart rate over time", systemImage: "chart.xyaxis.line")
                }
            }
            .padding()
        }
        .groupedBackground()
        .navigationTitle("Heart rate")
        .task(id: Calendar.current.startOfDay(for: day)) { await load() }
    }

    private var dayPicker: some View {
        HStack {
            Button {
                day = Calendar.current.date(byAdding: .day, value: -1, to: day) ?? day
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(day.formatted(date: .complete, time: .omitted))
                .font(.subheadline.weight(.medium))
            Spacer()
            Button {
                day = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(Calendar.current.isDateInToday(day))
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                RectangleMark(
                    x: .value("Time", point.date, unit: .minute),
                    yStart: .value("Low", point.min),
                    yEnd: .value("High", point.max),
                    width: 3
                )
                .foregroundStyle(Color.pink.opacity(0.25))
                LineMark(
                    x: .value("Time", point.date),
                    y: .value("bpm", point.value)
                )
                .foregroundStyle(Color.pink)
                .interpolationMethod(.monotone)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxisLabel("bpm")
        .frame(height: 220)
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricTile(
                title: "Resting (estimated)",
                value: HealthMath.restingEstimate(fiveMinuteAverages: values)?.noDecimals ?? "--",
                unit: "bpm",
                systemImage: "heart.text.square",
                tint: .pink
            )
            MetricTile(
                title: "Average",
                value: values.isEmpty ? "--" : (values.reduce(0, +) / Double(values.count)).noDecimals,
                unit: "bpm",
                systemImage: "chart.line.flattrend.xyaxis",
                tint: .pink
            )
            MetricTile(
                title: "Lowest",
                value: points.map(\.min).min()?.noDecimals ?? "--",
                unit: "bpm",
                systemImage: "arrow.down",
                tint: .pink
            )
            MetricTile(
                title: "Highest",
                value: points.map(\.max).max()?.noDecimals ?? "--",
                unit: "bpm",
                systemImage: "arrow.up",
                tint: .pink
            )
        }
    }

    private var zoneSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heart-rate zones").font(.headline)
            ForEach(zones) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Zone \(entry.zone.id) · \(entry.zone.name)")
                            .font(.caption)
                        Spacer()
                        Text("\(entry.zone.lower.noDecimals)-\(entry.zone.upper.noDecimals) bpm")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text((entry.share * 100).noDecimals + "%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                    GeometryReader { proxy in
                        Capsule()
                            .fill(zoneColour(entry.zone.id))
                            .frame(width: max(2, proxy.size.width * entry.share))
                    }
                    .frame(height: 6)
                }
            }
            Text("Share of the day's readings in each zone, with zones from your age (\(Int(Profile.age)), maximum \(HealthMath.maximumHeartRate(age: Profile.age).noDecimals) bpm). Change your age in Settings.")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func zoneColour(_ zone: Int) -> Color {
        [Color.gray, .blue, .green, .orange, .red][max(0, min(4, zone - 1))]
    }

    private func load() async {
        loading = true
        points = await coordinator.trends.intraday(.heartRate, day: day)
        zones = await coordinator.trends.zoneShares(day: day, age: Profile.age)
        loading = false
    }
}

// MARK: - Workouts

struct WorkoutListView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator
    @State private var workouts: [HealthDashboard.Workout] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && workouts.isEmpty {
                EmptyHint(
                    systemImage: "figure.run",
                    title: "No workouts yet",
                    detail: "Start a workout from GalaxyBridge on the watch; it appears here with its route, heart rate and calories once it syncs."
                )
            }
            ForEach(workouts) { workout in
                NavigationLink {
                    WorkoutDetailView(workout: workout)
                } label: {
                    WorkoutRow(workout: workout)
                }
            }
        }
        .navigationTitle("Workouts")
        .task {
            workouts = await coordinator.store.workouts(limit: 500).map(HealthDashboard.Workout.init(summary:))
            loaded = true
        }
    }
}

struct WorkoutRow: View {
    let workout: HealthDashboard.Workout

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: WorkoutStyle.symbol(for: workout.summary.type))
                .font(.title2)
                .foregroundStyle(.green)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.activity).fontWeight(.medium)
                Text(workout.start.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(workout.duration.hoursMinutes)
                    .font(.subheadline)
                    .monospacedDigit()
                if let distance = workout.distanceMeters {
                    Text((distance / 1000).oneDecimal + " km")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct WorkoutDetailView: View {
    let workout: HealthDashboard.Workout

    private var route: [CLLocationCoordinate2D] {
        (workout.summary.route ?? []).map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if route.count > 1 {
                    Map {
                        MapPolyline(coordinates: route)
                            .stroke(.green, lineWidth: 4)
                        if let first = route.first {
                            Marker("Start", systemImage: "flag", coordinate: first).tint(.green)
                        }
                        if let last = route.last {
                            Marker("End", systemImage: "flag.checkered", coordinate: last).tint(.red)
                        }
                    }
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    MetricTile(
                        title: "Duration",
                        value: workout.duration.hoursMinutes,
                        unit: nil,
                        systemImage: "timer",
                        tint: .yellow
                    )
                    MetricTile(
                        title: "Active energy",
                        value: workout.energyKcal?.noDecimals ?? "--",
                        unit: "kcal",
                        systemImage: "flame.fill",
                        tint: .red
                    )
                    MetricTile(
                        title: "Distance",
                        value: workout.distanceMeters.map { ($0 / 1000).oneDecimal } ?? "--",
                        unit: "km",
                        systemImage: "location.fill",
                        tint: .blue
                    )
                    MetricTile(
                        title: "Average pace",
                        value: pace ?? "--",
                        unit: pace == nil ? nil : "/km",
                        systemImage: "speedometer",
                        tint: .cyan
                    )
                    MetricTile(
                        title: "Average heart rate",
                        value: workout.summary.avgHeartRate?.noDecimals ?? "--",
                        unit: "bpm",
                        systemImage: "heart.fill",
                        tint: .pink
                    )
                    MetricTile(
                        title: "Maximum heart rate",
                        value: workout.summary.maxHeartRate?.noDecimals ?? "--",
                        unit: "bpm",
                        systemImage: "bolt.heart.fill",
                        tint: .pink
                    )
                }

                if trace.count > 2 {
                    heartRateChart
                    zonesBreakdown
                }

                Text(
                    workout.start.formatted(date: .complete, time: .shortened)
                        + " – " + workout.end.formatted(date: .omitted, time: .shortened)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
        .groupedBackground()
        .navigationTitle(workout.activity)
    }

    /// One reading every 10 s from the watch.
    private var trace: [Int] { workout.summary.heartRateTrace ?? [] }

    private var zones: [HealthMath.Zone] { HealthMath.zones(age: Profile.age) }

    private func zoneIndex(_ bpm: Int) -> Int {
        let value = Double(bpm)
        guard let first = zones.first, value >= first.lower else { return 0 }
        return zones.last(where: { value >= $0.lower })?.id ?? 0
    }

    private var heartRateChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Heart rate").font(.headline)
            Chart {
                ForEach(Array(trace.enumerated()), id: \.offset) { index, bpm in
                    LineMark(
                        x: .value("Minute", Double(index) / 6),
                        y: .value("bpm", bpm)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(.pink)
                }
            }
            .chartXAxisLabel("min")
            .chartYScale(domain: max(40, (trace.min() ?? 60) - 10)...((trace.max() ?? 180) + 10))
            .frame(height: 160)
        }
    }

    /// Time in each zone, each reading standing for 10 seconds.
    private var zonesBreakdown: some View {
        let counts = Dictionary(grouping: trace, by: zoneIndex).mapValues(\.count)
        let total = max(1, trace.count)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Time in zones").font(.headline)
            ForEach(zones.reversed()) { zone in
                let count = counts[zone.id] ?? 0
                HStack {
                    Text("\(zone.id)").font(.caption.monospacedDigit()).frame(width: 14)
                    Text(zone.name).font(.caption).frame(width: 90, alignment: .leading)
                    GeometryReader { proxy in
                        Capsule()
                            .fill([Color.gray, .blue, .green, .orange, .red][max(0, min(4, zone.id - 1))])
                            .frame(width: max(2, proxy.size.width * Double(count) / Double(total)))
                    }
                    .frame(height: 8)
                    Text(TimeInterval(count * 10).hoursMinutes)
                        .font(.caption.monospacedDigit())
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }

    /// Minutes per kilometre, only when there is a meaningful distance.
    private var pace: String? {
        guard let distance = workout.distanceMeters, distance > 200 else { return nil }
        let secondsPerKm = workout.duration / (distance / 1000)
        guard secondsPerKm.isFinite, secondsPerKm < 3600 else { return nil }
        return String(format: "%d:%02d", Int(secondsPerKm) / 60, Int(secondsPerKm) % 60)
    }
}

// MARK: - Trends

struct TrendsView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator
    @State private var insights: [HealthTrends.Insight] = []
    @State private var records = HealthTrends.Records()
    @State private var loading = true

    var body: some View {
        List {
            Section {
                if loading {
                    ProgressView()
                } else if insights.isEmpty {
                    Text("Trends appear after a few days of data.")
                        .foregroundStyle(.secondary)
                }
                ForEach(insights) { insight in
                    InsightRow(insight: insight)
                }
            } header: {
                Text("Last 7 days")
            } footer: {
                Text("Each figure compares your last week with the four weeks before it.")
            }

            Section("Streaks") {
                LabeledContent("Current step-goal streak", value: "\(records.currentStreak) days")
                LabeledContent("Longest step-goal streak", value: "\(records.longestStreak) days")
                LabeledContent("Days with data this year", value: "\(records.daysWithData)")
            }

            Section("Records") {
                recordRow("Most steps", records.bestSteps, format: { $0.noDecimals })
                recordRow("Longest distance", records.bestDistance, format: { ($0 / 1000).oneDecimal + " km" })
                recordRow("Most active energy", records.bestEnergy, format: { $0.noDecimals + " kcal" })
                recordRow("Lowest resting heart rate", records.lowestResting, format: { $0.noDecimals + " bpm" })
                if let night = records.longestSleep {
                    LabeledContent("Longest sleep") {
                        VStack(alignment: .trailing) {
                            Text(night.asleep.hoursMinutes)
                            Text(night.night.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("Workouts recorded", value: "\(records.workoutCount)")
                LabeledContent("Time training", value: records.workoutDuration.hoursMinutes)
            }
        }
        .navigationTitle("Trends and records")
        .task {
            insights = await coordinator.trends.insights()
            records = await coordinator.trends.records(stepGoal: coordinator.dashboard.stepGoal)
            loading = false
        }
    }

    @ViewBuilder
    private func recordRow(
        _ title: String,
        _ point: HealthTrends.DailyPoint?,
        format: (Double) -> String
    ) -> some View {
        if let point {
            let text = format(point.value)
            LabeledContent(title) {
                VStack(alignment: .trailing) {
                    Text(text)
                    Text(point.date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct InsightRow: View {
    let insight: HealthTrends.Insight

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: insight.systemImage)
                .foregroundStyle(insight.kind?.tint ?? .indigo)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(insight.title)).font(.subheadline.weight(.medium))
                Text(insight.sentence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(valueText)
                    .font(.subheadline.monospacedDigit())
                if let change = insight.change, abs(change) >= 3 {
                    Image(systemName: change > 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(insight.isPositive == true ? .green : .orange)
                }
            }
        }
    }

    private var valueText: String {
        let number = insight.unit == "km" || insight.unit == "h"
            ? insight.recent.oneDecimal
            : insight.recent.noDecimals
        return insight.unit.isEmpty ? number : number + " " + insight.unit
    }
}

/// A centred empty state, used wherever there is nothing to draw yet.
struct EmptyHint: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(tr(title)).font(.subheadline)
            Text(tr(detail))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
