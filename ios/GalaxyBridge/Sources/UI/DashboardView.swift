import Charts
import SwiftUI

/// Today's summary: rings, every metric the watch delivers, today by the hour,
/// how this week compares, and the latest workouts. Each tile opens its history.
///
/// A tile shows "--" when there is no sample rather than a zero, because zero
/// steps and "the watch never sent steps" are different problems.
struct DashboardView: View {
    @EnvironmentObject private var coordinator: BridgeCoordinator
    @ObservedObject private var dashboard: HealthDashboard

    @State private var insights: [HealthTrends.Insight] = []

    init(dashboard: HealthDashboard) {
        self.dashboard = dashboard
    }

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if !dashboard.hasAnyData {
                        waitingCard
                    }

                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased())
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 18) {
                        RingStack(
                            energy: dashboard.today.activeEnergy,
                            energyGoal: dashboard.energyGoal,
                            steps: dashboard.today.steps,
                            stepGoal: dashboard.stepGoal,
                            distance: dashboard.today.distanceMeters,
                            distanceGoal: dashboard.distanceGoal,
                            size: 140
                        )
                        VStack(alignment: .leading, spacing: 10) {
                            heroValue(
                                "Energy",
                                dashboard.today.activeEnergy.noDecimals,
                                "/ " + dashboard.energyGoal.noDecimals + " kcal",
                                RingStack.energyColour
                            )
                            heroValue(
                                "Steps",
                                dashboard.today.steps.noDecimals,
                                "/ " + dashboard.stepGoal.noDecimals,
                                RingStack.stepsColour
                            )
                            heroValue(
                                "Distance",
                                (dashboard.today.distanceMeters / 1000).oneDecimal,
                                "/ " + (dashboard.distanceGoal / 1000).oneDecimal + " km",
                                RingStack.distanceColour
                            )
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .environment(\.colorScheme, .dark)

                    ReadinessCard(readiness: dashboard.readiness, stress: dashboard.stress)

                    metricGrid

                    sleepRow

                    measurementsRow

                    stepsByHour

                    heartCard

                    if !insights.isEmpty {
                        insightCard
                    }

                    workoutSection

                    Text(footer)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .groupedBackground()
            .navigationTitle("Summary")
            .navigationDestination(for: HealthKind.self) { kind in
                MetricDetailView(kind: kind)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    LinkPill(
                        connected: coordinator.client.isConnected,
                        scanning: coordinator.client.isScanning
                    )
                }
            }
            .refreshable { await reload() }
            .task { await reload() }
        }
    }

    private func reload() async {
        await dashboard.refresh()
        insights = await coordinator.trends.insights()
    }

    private var footer: String {
        guard let last = dashboard.lastSampleAt else { return tr("Nothing received from the watch yet") }
        let when = Calendar.current.isDateInToday(last)
            ? last.formatted(date: .omitted, time: .shortened)
            : last.formatted(date: .abbreviated, time: .shortened)
        return String(format: tr("Latest data from the watch: %@"), when)
    }

    private var waitingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Waiting for the first sync", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
            Text("Everything the watch measures is stored in this app. The watch sends it every few minutes while connected, so the rings fill in shortly after it links.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var metricGrid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            tile(
                .heartRate,
                value: dashboard.heartRate.latest?.noDecimals,
                footnote: heartRateFootnote
            )
            tile(
                .restingHeartRate,
                value: dashboard.restingHeartRate?.noDecimals,
                footnote: tr("estimated today")
            )
            tile(.steps, value: dashboard.today.steps > 0 ? dashboard.today.steps.noDecimals : nil)
            tile(
                .distance,
                value: dashboard.today.distanceMeters > 0
                    ? (dashboard.today.distanceMeters / 1000).oneDecimal
                    : nil
            )
            tile(
                .energy,
                value: dashboard.today.activeEnergy > 0 ? dashboard.today.activeEnergy.noDecimals : nil
            )
            tile(.floors, value: dashboard.today.floors > 0 ? dashboard.today.floors.noDecimals : nil)
            tile(
                .spo2,
                value: dashboard.spo2.map { HealthKind.spo2.display($0.value).noDecimals },
                footnote: dashboard.spo2.map { Self.when($0.date) } ?? tr("measure on the watch")
            )
            tile(
                .hrv,
                value: dashboard.hrv?.value.noDecimals,
                footnote: dashboard.hrv.map { Self.when($0.date) } ?? tr("every 30 min on the watch")
            )
            tile(
                .respiratoryRate,
                value: dashboard.latest[.respiratoryRate]?.value.oneDecimal,
                footnote: dashboard.latest[.respiratoryRate].map { Self.when($0.date) } ?? tr("measured while you sleep")
            )
            tile(
                .skinTemperature,
                value: dashboard.latest[.skinTemperature]?.value.oneDecimal,
                footnote: dashboard.latest[.skinTemperature].map { Self.when($0.date) } ?? tr("overnight or on demand")
            )
        }
    }

    /// One navigable tile. `value` is nil when there is no sample, which is what
    /// turns into "--" rather than a fabricated zero.
    private func tile(_ kind: HealthKind, value: String?, footnote: String? = nil) -> some View {
        NavigationLink(value: kind) {
            MetricTile(
                title: kind == .restingHeartRate ? tr("Resting") : kind.title,
                value: value ?? "--",
                unit: kind.unit.isEmpty ? nil : kind.unit,
                systemImage: kind.systemImage,
                tint: kind.tint,
                footnote: footnote,
                navigable: true
            )
        }
        .buttonStyle(.plain)
    }

    static func when(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    private var heartRateFootnote: String? {
        guard let at = dashboard.heartRate.at else { return nil }
        var text = at.formatted(date: .omitted, time: .shortened)
        if let low = dashboard.heartRate.min, let high = dashboard.heartRate.max {
            text += " · today \(low.noDecimals)-\(high.noDecimals)"
        }
        return text
    }

    @ViewBuilder
    private var sleepRow: some View {
        if dashboard.lastNight.count > 1 {
            NavigationLink {
                SleepDetailView()
            } label: {
                LastNightCard(segments: dashboard.lastNight, score: dashboard.sleepScore)
            }
            .buttonStyle(.plain)
        } else {
            plainSleepRow
        }
    }

    /// ECG and body composition, both measured on demand on the watch.
    private var measurementsRow: some View {
        HStack(spacing: 12) {
            NavigationLink {
                EcgListView()
            } label: {
                MetricTile(
                    title: tr("ECG"),
                    value: dashboard.latestEcg?.averageHeartRate.map { $0.noDecimals } ?? "--",
                    unit: dashboard.latestEcg?.averageHeartRate == nil ? nil : "bpm",
                    systemImage: "waveform.path.ecg.rectangle.fill",
                    tint: .red,
                    footnote: dashboard.latestEcg.map { EcgDetailView.verdict($0.rhythm) } ?? tr("30 s on the watch"),
                    navigable: true
                )
            }
            .buttonStyle(.plain)
            NavigationLink {
                BodyCompositionView(dashboard: dashboard)
            } label: {
                MetricTile(
                    title: tr("Body fat"),
                    value: dashboard.latest[.bodyFat]?.value.oneDecimal ?? "--",
                    unit: "%",
                    systemImage: "figure.arms.open",
                    tint: .indigo,
                    footnote: dashboard.latest[.skeletalMuscle].map { tr("muscle") + " " + $0.value.oneDecimal + " kg" }
                        ?? tr("body composition"),
                    navigable: true
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var plainSleepRow: some View {
        NavigationLink {
            SleepDetailView()
        } label: {
            MetricTile(
                title: tr("Sleep"),
                value: dashboard.sleepLastNight?.hoursMinutes ?? "--",
                unit: nil,
                systemImage: "bed.double.fill",
                tint: .indigo,
                footnote: sleepFootnote,
                navigable: true
            )
        }
        .buttonStyle(.plain)
    }

    private var sleepFootnote: String {
        guard let bed = dashboard.bedtime, let wake = dashboard.wakeTime else {
            return tr("last night")
        }
        return bed.formatted(date: .omitted, time: .shortened)
            + " – " + wake.formatted(date: .omitted, time: .shortened)
    }

    /// One line beside the rings: what, how much, and the goal.
    private func heroValue(_ title: String, _ value: String, _ goal: String, _ colour: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(tr(title))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(goal)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(colour)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }

    private var ringLegend: some View {
        HStack(spacing: 0) {
            legendItem(.red, "Energy", dashboard.today.activeEnergy, dashboard.energyGoal, "kcal")
            legendItem(.green, "Steps", dashboard.today.steps, dashboard.stepGoal, nil)
            legendItem(
                .blue,
                "Distance",
                dashboard.today.distanceMeters / 1000,
                dashboard.distanceGoal / 1000,
                "km"
            )
        }
    }

    private func legendItem(
        _ colour: Color,
        _ title: String,
        _ value: Double,
        _ goal: Double,
        _ unit: String?
    ) -> some View {
        VStack(spacing: 2) {
            Text(tr(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(unit == "km" ? value.oneDecimal : value.noDecimals)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .foregroundStyle(colour)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("of " + (unit == "km" ? goal.oneDecimal : goal.noDecimals) + (unit.map { " " + $0 } ?? ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var stepsByHour: some View {
        if !dashboard.hourlySteps.isEmpty {
            NavigationLink(value: HealthKind.steps) {
                card(title: "Steps by hour", systemImage: "figure.walk", tint: .green) {
                    Chart(dashboard.hourlySteps) { point in
                        BarMark(
                            x: .value("Hour", point.date, unit: .hour),
                            y: .value("Steps", point.value)
                        )
                        .foregroundStyle(Color.green.gradient)
                    }
                    .chartXScale(domain: dayDomain)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    }
                    .frame(height: 120)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var heartCard: some View {
        if !dashboard.heartToday.isEmpty {
            NavigationLink {
                HeartView()
            } label: {
                card(title: "Heart rate today", systemImage: "heart.fill", tint: .pink) {
                    Chart(dashboard.heartToday) { point in
                        LineMark(
                            x: .value("Time", point.date),
                            y: .value("bpm", point.value)
                        )
                        .foregroundStyle(Color.pink)
                        .interpolationMethod(.monotone)
                    }
                    .chartXScale(domain: dayDomain)
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour())
                        }
                    }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 120)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var insightCard: some View {
        NavigationLink {
            TrendsView()
        } label: {
            card(title: "This week", systemImage: "chart.line.uptrend.xyaxis", tint: .indigo) {
                VStack(spacing: 10) {
                    ForEach(insights.prefix(3)) { insight in
                        InsightRow(insight: insight)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var workoutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Workouts").font(.title3.bold())
                Spacer()
                if !dashboard.workouts.isEmpty {
                    NavigationLink("See all") { WorkoutListView() }
                        .font(.subheadline)
                }
            }
            if dashboard.workouts.isEmpty {
                Text("None yet. Start one from GalaxyBridge on the watch and it appears here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(dashboard.workouts.prefix(3)) { workout in
                    NavigationLink {
                        WorkoutDetailView(workout: workout)
                    } label: {
                        WorkoutRow(workout: workout)
                            .cardStyle(padding: 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dayDomain: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: Date())
        return start...start.addingTimeInterval(24 * 3600)
    }

    private func card<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tr(title), systemImage: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            content()
        }
        .cardStyle()
    }
}
