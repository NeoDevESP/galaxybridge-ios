import Charts
import SwiftUI

/// Sleep by night, split into the stages the watch worked out.
///
/// The score's formula is in `SleepScore`, in the open, and each night opens
/// its hypnogram. The screen says plainly that wrist staging is an estimate,
/// because a consumer sensor inferring REM from movement and pulse is not
/// polysomnography.
struct SleepDetailView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator

    @State private var nights: [HealthTrends.SleepNight] = []
    @State private var window: HealthTrends.Window = .week
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Window", selection: $window) {
                    ForEach(HealthTrends.Window.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                if loading {
                    ProgressView().frame(height: 220).frame(maxWidth: .infinity)
                } else if nights.isEmpty {
                    emptyState
                } else {
                    chart
                        .cardStyle()
                    summary
                    if hasStages { legend }
                    nightList
                }

                Text("The watch tracks each night itself: it notices when you fall asleep, keeps every heartbeat and movement, and estimates awake, REM, light and deep sleep from them. An estimate from wrist sensors, not a sleep study.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
        .groupedBackground()
        .navigationTitle("Sleep")
        .task(id: window) { await load() }
    }

    private var hasStages: Bool { nights.contains(where: \.hasStages) }

    @ViewBuilder
    private var chart: some View {
        if hasStages {
            stagedChart
        } else {
            // Wear OS gives third-party apps asleep/awake, not stages, so the
            // honest chart is one bar per night.
            Chart(nights) { night in
                BarMark(
                    x: .value("Night", night.night, unit: .day),
                    y: .value("Hours", night.asleep / 3600)
                )
                .foregroundStyle(Color.indigo.gradient)
            }
            .chartYAxisLabel("hours")
            .frame(height: 240)
        }
    }

    private var stagedChart: some View {
        Chart {
            ForEach(nights) { night in
                BarMark(
                    x: .value("Night", night.night, unit: .day),
                    y: .value("Hours", night.deep / 3600)
                )
                .foregroundStyle(by: .value("Stage", "Deep"))
                BarMark(
                    x: .value("Night", night.night, unit: .day),
                    y: .value("Hours", night.core / 3600)
                )
                .foregroundStyle(by: .value("Stage", "Core"))
                BarMark(
                    x: .value("Night", night.night, unit: .day),
                    y: .value("Hours", night.rem / 3600)
                )
                .foregroundStyle(by: .value("Stage", "REM"))
            }
        }
        .chartForegroundStyleScale([
            "Deep": Color.indigo,
            "Core": Color.blue,
            "REM": Color.teal,
        ])
        .chartYAxisLabel("hours")
        .frame(height: 240)
    }

    private var summary: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            MetricTile(
                title: "Average asleep",
                value: averageAsleep?.hoursMinutes ?? "--",
                unit: nil,
                systemImage: "bed.double.fill",
                tint: .indigo,
                footnote: String(format: tr("over %ld nights with data"), nights.count)
            )
            MetricTile(
                title: "Usual bedtime",
                value: averageClock(nights.compactMap(\.bedtime)) ?? "--",
                unit: nil,
                systemImage: "moon.fill",
                tint: .indigo
            )
            MetricTile(
                title: "Usual wake-up",
                value: averageClock(nights.compactMap(\.wake)) ?? "--",
                unit: nil,
                systemImage: "sunrise.fill",
                tint: .orange
            )
            MetricTile(
                title: "Nights recorded",
                value: "\(nights.count)",
                unit: String(format: tr("of %ld"), window.rawValue),
                systemImage: "calendar",
                tint: .secondary
            )
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendDot(.indigo, "Deep")
            legendDot(.blue, "Light")
            legendDot(.teal, "REM")
            legendDot(.orange, "Awake, excluded from totals")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendDot(_ colour: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(label)
        }
    }

    private var nightList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By night").font(.headline)
            ForEach(nights.reversed()) { night in
                NavigationLink {
                    NightDetailView(night: night)
                } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(night.night.formatted(date: .abbreviated, time: .omitted))
                            .font(.subheadline)
                        if let bed = night.bedtime, let wake = night.wake {
                            Text(
                                bed.formatted(date: .omitted, time: .shortened) + " – "
                                    + wake.formatted(date: .omitted, time: .shortened)
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(night.asleep.hoursMinutes)
                        .font(.subheadline)
                        .monospacedDigit()
                    if night.awake > 60 {
                        Text("+\(night.awake.hoursMinutes) awake")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .cardStyle(padding: 10)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bed.double")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No sleep data from the watch")
                .font(.subheadline)
            Text("Wear the watch to bed. It notices when you fall asleep and wake up, and the night appears here, with its stages, after the next sync.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var averageAsleep: TimeInterval? {
        guard !nights.isEmpty else { return nil }
        return nights.map(\.asleep).reduce(0, +) / Double(nights.count)
    }

    /// Average clock time of a set of moments, wrapping around midnight so
    /// 23:30 and 00:30 average to midnight rather than to noon.
    private func averageClock(_ dates: [Date]) -> String? {
        guard !dates.isEmpty else { return nil }
        let calendar = Calendar.current
        var x = 0.0
        var y = 0.0
        for date in dates {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let minutes = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
            let angle = minutes / 1440 * 2 * Double.pi
            x += cos(angle)
            y += sin(angle)
        }
        var angle = atan2(y, x)
        if angle < 0 { angle += 2 * Double.pi }
        let minutes = Int(angle / (2 * Double.pi) * 1440) % 1440
        let components = DateComponents(hour: minutes / 60, minute: minutes % 60)
        guard let date = calendar.date(from: components) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var averageDeep: TimeInterval? {
        guard !nights.isEmpty else { return nil }
        return nights.map(\.deep).reduce(0, +) / Double(nights.count)
    }

    private var averageREM: TimeInterval? {
        guard !nights.isEmpty else { return nil }
        return nights.map(\.rem).reduce(0, +) / Double(nights.count)
    }

    private func load() async {
        loading = true
        nights = await coordinator.trends.sleepNights(days: window.rawValue)
        loading = false
    }
}

/// One night: its score, hypnogram, and time in each stage.
struct NightDetailView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator
    let night: HealthTrends.SleepNight

    @State private var segments: [LocalHealthStore.Segment] = []

    private var score: SleepScore {
        let staged = night.deep + night.rem > 0
        return SleepScore(
            asleep: night.asleep,
            deep: staged ? night.deep : nil,
            rem: staged ? night.rem : nil,
            awakenings: segments.filter { $0.value == 1 }.count
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 16) {
                    ScoreRing(score: score.total, tint: .indigo)
                        .frame(width: 80, height: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sleep score").font(.headline)
                        Text("Duration \(score.duration)/50 · Deep \(score.deep)/20")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("REM \(score.rem)/20 · Continuity \(score.continuity)/10")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                if segments.count > 1 {
                    LastNightCard(segments: segments, score: nil)
                }

                Text("Duration counts for half: 7 to 9 hours gets full marks. Deep and REM get full marks at 15% and 20% of the night, the usual adult share. Each wake-up costs two points of continuity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .groupedBackground()
        .navigationTitle(night.night.formatted(date: .abbreviated, time: .omitted))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let from = night.night.addingTimeInterval(-18 * 3600)
            let to = night.night.addingTimeInterval(18 * 3600)
            let all = await coordinator.store.segments(.sleep, from: from, to: to)
            let calendar = Calendar.current
            segments = all.filter { calendar.startOfDay(for: $0.end) == night.night }
        }
    }
}
