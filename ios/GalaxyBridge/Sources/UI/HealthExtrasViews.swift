import Charts
import SwiftUI

// MARK: - Readiness

/// Today's readiness score with what it is made of, plus stress from HRV.
struct ReadinessCard: View {
    let readiness: Readiness?
    let stress: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Readiness", systemImage: "bolt.heart.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.mint)
                Spacer()
                if let stress {
                    Label {
                        Text("Stress \(tr(StressLevel.label(stress)))")
                    } icon: {
                        Image(systemName: "brain.head.profile")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(stress >= 50 ? .orange : .secondary)
                }
            }
            if let readiness {
                HStack(spacing: 16) {
                    ScoreRing(score: readiness.score, tint: tint(readiness.score))
                        .frame(width: 74, height: 74)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr(readiness.label))
                            .font(.title3.weight(.semibold))
                        ForEach(readiness.parts) { part in
                            HStack {
                                Text(tr(part.title)).font(.caption)
                                Spacer()
                                Text("\(part.score)")
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(tint(part.score))
                            }
                        }
                    }
                }
            } else {
                Text("Wear the watch overnight and the score appears in the morning, from your sleep, HRV and resting heart rate against your own usual.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private func tint(_ score: Int) -> Color {
        switch score {
        case 70...: return .green
        case 50..<70: return .yellow
        default: return .orange
        }
    }
}

struct ScoreRing: View {
    let score: Int
    let tint: Color

    var body: some View {
        ZStack {
            ActivityRing(progress: Double(score) / 100, colour: tint, lineWidth: 9)
            Text("\(score)")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Hypnogram

extension LocalHealthStore.Segment: Identifiable {
    var id: Date { start }
}

/// A night as a staircase of stages, the chart every sleep app uses.
struct HypnogramView: View {
    let segments: [LocalHealthStore.Segment]

    static func name(_ value: Double) -> String {
        switch Int(value) {
        case 1: return tr("Awake")
        case 2: return tr("REM")
        case 3: return tr("Light")
        case 4: return tr("Deep")
        default: return tr("Asleep")
        }
    }

    static func colour(_ value: Double) -> Color {
        switch Int(value) {
        case 1: return .orange
        case 2: return .cyan
        case 3: return .blue
        case 4: return .indigo
        default: return .purple
        }
    }

    /// Awake at the top, deep at the bottom.
    private func level(_ value: Double) -> Int {
        switch Int(value) {
        case 1: return 4
        case 2: return 3
        case 3: return 2
        case 4: return 1
        default: return 2
        }
    }

    var body: some View {
        Chart(segments) { segment in
            RectangleMark(
                xStart: .value("Start", segment.start),
                xEnd: .value("End", segment.end),
                yStart: .value("Stage", level(segment.value) - 1),
                yEnd: .value("Stage", level(segment.value))
            )
            .foregroundStyle(Self.colour(segment.value).gradient)
            .cornerRadius(3)
        }
        .chartYScale(domain: 0...4)
        .chartYAxis {
            AxisMarks(values: [0.5, 1.5, 2.5, 3.5]) { value in
                AxisValueLabel {
                    let names = [tr("Deep"), tr("Light"), tr("REM"), tr("Awake")]
                    if let v = value.as(Double.self) { Text(names[Int(v)]) }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 2)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .frame(height: 150)
    }
}

/// Last night: score, hypnogram and time in each stage.
struct LastNightCard: View {
    let segments: [LocalHealthStore.Segment]
    let score: SleepScore?

    private func total(_ stage: Double) -> TimeInterval {
        segments.filter { $0.value == stage }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last night").font(.headline)
                Spacer()
                if let score {
                    Text("Score \(score.total)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.indigo)
                }
            }
            HypnogramView(segments: segments)
                .drawIn()
            HStack {
                ForEach([4.0, 3.0, 2.0, 1.0], id: \.self) { stage in
                    VStack(spacing: 2) {
                        Circle().fill(HypnogramView.colour(stage)).frame(width: 8, height: 8)
                        Text(HypnogramView.name(stage)).font(.caption2).foregroundStyle(.secondary)
                        Text(total(stage).hoursMinutes).font(.caption.monospacedDigit().weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .cardStyle()
    }
}

// MARK: - ECG

struct EcgListView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator
    @State private var records: [EcgRecord] = []

    var body: some View {
        List {
            if records.isEmpty {
                Section {
                    EmptyHint(
                        systemImage: "waveform.path.ecg.rectangle",
                        title: "No ECGs yet",
                        detail: "On the watch open GalaxyBridge, tap ECG, rest your arm on a table and hold a fingertip on the top button for 30 seconds."
                    )
                }
            }
            ForEach(records) { record in
                NavigationLink {
                    EcgDetailView(record: record)
                } label: {
                    HStack {
                        Image(systemName: EcgDetailView.symbol(record.rhythm))
                            .foregroundStyle(EcgDetailView.colour(record.rhythm))
                        VStack(alignment: .leading) {
                            Text(EcgDetailView.verdict(record.rhythm)).font(.headline)
                            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let hr = record.averageHeartRate {
                            Text("\(Int(hr)) bpm").font(.subheadline.monospacedDigit())
                        }
                    }
                }
            }
            Section {
            } footer: {
                Text("A single-lead ECG from a consumer watch. It cannot detect a heart attack and is not a diagnosis. If you feel unwell, call emergency services.")
            }
        }
        .navigationTitle("ECG")
        .task { records = await coordinator.store.ecgRecords() }
    }
}

struct EcgDetailView: View {
    let record: EcgRecord

    static func verdict(_ rhythm: String) -> String {
        switch rhythm {
        case "regular": return tr("Regular rhythm")
        case "irregular": return tr("Irregular rhythm")
        default: return tr("Inconclusive")
        }
    }

    static func symbol(_ rhythm: String) -> String {
        switch rhythm {
        case "regular": return "checkmark.circle.fill"
        case "irregular": return "exclamationmark.triangle.fill"
        default: return "questionmark.circle.fill"
        }
    }

    static func colour(_ rhythm: String) -> Color {
        switch rhythm {
        case "regular": return .green
        case "irregular": return .orange
        default: return .secondary
        }
    }

    private var explanation: LocalizedStringKey {
        switch record.rhythm {
        case "regular":
            return "The time between beats was steady, as in a normal rhythm."
        case "irregular":
            return "The time between beats varied a lot. This can be harmless (extra beats, movement) but if it repeats, show these recordings to a doctor."
        default:
            return "The trace was too noisy, too short, or the heart rate was outside 45-130 bpm. Rest your arm on a table, stay still and try again."
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: Self.symbol(record.rhythm))
                        .font(.largeTitle)
                        .foregroundStyle(Self.colour(record.rhythm))
                    VStack(alignment: .leading) {
                        Text(Self.verdict(record.rhythm)).font(.title2.weight(.semibold))
                        if let hr = record.averageHeartRate {
                            Text("\(Int(hr)) bpm average · \(record.beats) beats")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .cardStyle()

                EcgTrace(record: record)
                    .cardStyle(padding: 8)

                Text(explanation)
                    .font(.subheadline)
                    .cardStyle()

                Text("Not a diagnosis. A single-lead watch ECG cannot detect a heart attack.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .groupedBackground()
        .navigationTitle(record.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The trace on ECG paper: 25 mm/s and 10 mm/mV, one row per 6 seconds.
struct EcgTrace: View {
    let record: EcgRecord
    private let secondsPerRow = 6.0

    var body: some View {
        let rate = Double(max(record.sampleRate, 1))
        let perRow = Int(rate * secondsPerRow)
        let rows = stride(from: 0, to: record.microvolts.count, by: perRow).map { start in
            Array(record.microvolts[start..<min(start + perRow, record.microvolts.count)])
        }
        VStack(spacing: 6) {
            ForEach(rows.indices, id: \.self) { index in
                Canvas { context, size in
                    // Paper grid: 0.2 s major lines.
                    var grid = Path()
                    let majors = Int(secondsPerRow / 0.2)
                    for i in 0...majors {
                        let x = size.width * Double(i) / Double(majors)
                        grid.move(to: CGPoint(x: x, y: 0))
                        grid.addLine(to: CGPoint(x: x, y: size.height))
                    }
                    for i in 0...4 {
                        let y = size.height * Double(i) / 4
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    context.stroke(grid, with: .color(.red.opacity(0.15)), lineWidth: 0.5)

                    let samples = rows[index]
                    guard samples.count > 1 else { return }
                    // +-1 mV fills the row.
                    var trace = Path()
                    for (i, uv) in samples.enumerated() {
                        let x = size.width * Double(i) / Double(perRow)
                        let y = size.height / 2 - Double(uv) / 1000 * size.height / 2.2
                        let point = CGPoint(x: x, y: min(max(y, 0), size.height))
                        if i == 0 { trace.move(to: point) } else { trace.addLine(to: point) }
                    }
                    context.stroke(trace, with: .color(.primary), lineWidth: 1.1)
                }
                .frame(height: 90)
            }
        }
        .accessibilityLabel("ECG trace")
    }
}

// MARK: - Body composition

struct BodyCompositionView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator
    @ObservedObject var dashboard: HealthDashboard

    private let kinds: [HealthKind] = [.bodyFat, .skeletalMuscle, .bodyWater, .bmr]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(kinds) { kind in
                        NavigationLink(value: kind) {
                            MetricTile(
                                title: kind.title,
                                value: dashboard.latest[kind].map { $0.value.oneDecimal } ?? "--",
                                unit: kind.unit,
                                systemImage: kind.systemImage,
                                tint: kind.tint,
                                footnote: dashboard.latest[kind].map { DashboardView.when($0.date) },
                                navigable: true
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Label("How to measure", systemImage: "hand.point.up.left.fill")
                        .font(.subheadline.weight(.semibold))
                    Text("On the watch open GalaxyBridge and tap Body composition. Put your middle and ring fingers on the two buttons, keep your arms away from your body and stay still for about 15 seconds. Measure at the same time of day, before eating or training, for comparable numbers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Your height, sex and age come from Fitness > Body and Settings; the latest weight you logged is sent to the watch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .cardStyle()
            }
            .padding()
        }
        .groupedBackground()
        .navigationTitle("Body composition")
        .navigationDestination(for: HealthKind.self) { kind in
            MetricDetailView(kind: kind)
        }
        .task { coordinator.pushHealthConfig() }
    }
}

/// Training load, recovery and cardio fitness, from the load and VO2max the
/// watch works out for each session.
struct TrainingCard: View {
    let status: TrainingStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Training", systemImage: "figure.run")
                .symbolRenderingMode(.hierarchical)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Load, 7 days").font(.caption).foregroundStyle(.secondary)
                    Text(status.acute.noDecimals)
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .contentTransition(.numericText(value: status.acute))
                    Text(tr(status.label))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    loadBar
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recovery").font(.caption).foregroundStyle(.secondary)
                    if status.recoveryLeftHours > 0 {
                        Text("\(status.recoveryLeftHours) h")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text("to recover").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Ready")
                            .font(.system(.title2, design: .rounded, weight: .bold))
                            .foregroundStyle(.green)
                        Text("for a hard session").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let vo2 = status.vo2Max {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cardio fitness").font(.caption).foregroundStyle(.secondary)
                        Text(vo2.oneDecimal)
                            .font(.system(.title2, design: .rounded, weight: .bold))
                        Text(tr(TrainingStatus.fitnessLabel(vo2)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .cardStyle()
    }

    private var tint: Color {
        switch status.label {
        case "Optimal": return .green
        case "High": return .orange
        case "Very high": return .red
        default: return .secondary
        }
    }

    /// Where this week sits against the usual: the green band is 0.8-1.3.
    private var loadBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let marker = min(max((status.ratio ?? 0) / 2, 0), 1) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Color.green.opacity(0.45))
                    .frame(width: w * 0.25)
                    .offset(x: w * 0.4)
                Circle().fill(tint).frame(width: 10, height: 10).offset(x: marker - 5)
            }
        }
        .frame(height: 10)
        .padding(.top, 2)
    }
}

/// Last night's oxygen, and a warning when skin temperature and resting pulse
/// both rose: the usual sign of the body fighting something off.
struct NightSignalsCard: View {
    let signals: NightSignals

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if signals.mayBeIll {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your body may be fighting something off")
                            .font(.subheadline.weight(.semibold))
                        Text("Skin temperature and resting pulse were both above normal last night. Take it easy today.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "thermometer.medium").foregroundStyle(.orange)
                }
            }
            HStack(spacing: 16) {
                if let min = signals.oxygenMin {
                    signal("Oxygen low", "\(Int((min * 100).rounded())) %", min < 0.90 ? .orange : .cyan)
                    signal("Drops below 90 %", "\(signals.oxygenDrops)", signals.oxygenDrops > 0 ? .orange : .secondary)
                }
                if let skin = signals.skinDelta {
                    signal("Skin temperature", String(format: "%+.1f °C", skin), abs(skin) >= 0.5 ? .orange : .secondary)
                }
            }
        }
        .cardStyle()
    }

    private func signal(_ title: LocalizedStringKey, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.headline, design: .rounded)).foregroundStyle(tint)
        }
    }
}

