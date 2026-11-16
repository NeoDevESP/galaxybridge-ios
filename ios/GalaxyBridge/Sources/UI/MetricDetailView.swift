import Charts
import SwiftUI

/// One metric over time: the chart, the numbers behind it, and how much of the
/// window actually has data.
///
/// The gap count is not a footnote. A 30-day average over 9 days of data is a
/// different statement than one over 30, and the screen says which you are
/// looking at instead of letting the average imply the second.
struct MetricDetailView: View {
    typealias Kind = HealthKind

    let kind: Kind
    @EnvironmentObject private var coordinator: BridgeCoordinator

    @State private var window: HealthTrends.Window = .week
    @State private var series = HealthTrends.Series()
    @State private var low = HealthTrends.Series()
    @State private var high = HealthTrends.Series()
    @State private var loading = true

    private var points: [HealthTrends.DailyPoint] {
        series.points.map { HealthTrends.DailyPoint(date: $0.date, value: kind.display($0.value)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Window", selection: $window) {
                    ForEach(HealthTrends.Window.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                chart
                    .cardStyle()

                statsGrid

                coverageNote

                Text(tr(footnote))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding()
        }
        .groupedBackground()
        .navigationTitle(kind.title)
        .task(id: window) { await load() }
    }

    @ViewBuilder
    private var chart: some View {
        if loading {
            ProgressView().frame(height: 220)
        } else if points.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "chart.line.downtrend.xyaxis")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No samples in this window")
                    .font(.subheadline)
                Text("Nothing is drawn rather than drawing zeros.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 220)
            .frame(maxWidth: .infinity)
        } else {
            Chart {
                if kind.isCumulative {
                    ForEach(points) { point in
                        BarMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value(kind.title, point.value)
                        )
                        .foregroundStyle(kind.tint)
                    }
                } else {
                    // The band is the day's measured min-max, not a confidence
                    // interval: it shows the spread the watch actually saw.
                    ForEach(bandPoints) { band in
                        RectangleMark(
                            x: .value("Day", band.date, unit: .day),
                            yStart: .value("Low", band.low),
                            yEnd: .value("High", band.high),
                            width: .ratio(0.35)
                        )
                        .foregroundStyle(kind.tint.opacity(0.18))
                    }
                    ForEach(points) { point in
                        LineMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value(kind.title, point.value)
                        )
                        .foregroundStyle(kind.tint)
                        .interpolationMethod(.monotone)
                        PointMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value(kind.title, point.value)
                        )
                        .foregroundStyle(kind.tint)
                        .symbolSize(28)
                    }
                }
            }
            .chartYAxisLabel(kind.unit)
            .frame(height: 220)
        }
    }

    /// What the numbers on this screen are, in one sentence.
    private var footnote: String {
        switch kind {
        case .hrv:
            return tr("HRV as RMSSD from beat-to-beat intervals, every 30 minutes by day and through the night. Compare it with your own baseline, not with other people's numbers.")
        case .restingHeartRate:
            return tr("Estimated per day from the lowest stretch of your heart rate, the way wearables usually define resting. Not a medical measurement.")
        case .spo2:
            return tr("Measured on demand on the watch, and hourly while you sleep. Wrist readings are an estimate, not a pulse oximeter.")
        case .respiratoryRate:
            return tr("Breaths per minute while asleep, worked out from how your heart rate rises and falls with each breath. Most adults sit between 12 and 20.")
        case .skinTemperature:
            return tr("Wrist skin temperature, overnight or on demand. It is not body temperature; watch how it changes against your own usual.")
        case .bodyFat, .skeletalMuscle, .bodyWater, .bmr:
            return tr("From the watch's bioelectrical impedance sensor, using your height, weight, sex and age. Measure at the same time of day for comparable numbers.")
        default:
            return tr("Measured by the watch and stored in this app. It reports what was recorded and is not a medical device.")
        }
    }

    private struct Band: Identifiable {
        let date: Date
        let low: Double
        let high: Double
        var id: Date { date }
    }

    private var bandPoints: [Band] {
        let highs = Dictionary(uniqueKeysWithValues: high.points.map { ($0.date, $0.value) })
        return low.points.compactMap { point in
            guard let top = highs[point.date] else { return nil }
            return Band(
                date: point.date,
                low: kind.display(point.value),
                high: kind.display(top)
            )
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            if kind.isCumulative {
                MetricTile(
                    title: "Daily average",
                    value: series.average.map { kind.display($0) }?.formatted(unit: kind.unit) ?? "--",
                    unit: kind.unit.isEmpty ? nil : kind.unit,
                    systemImage: "chart.bar",
                    tint: kind.tint
                )
                MetricTile(
                    title: "Window total",
                    value: points.isEmpty ? "--" : points.map(\.value).reduce(0, +).formatted(unit: kind.unit),
                    unit: kind.unit.isEmpty ? nil : kind.unit,
                    systemImage: "sum",
                    tint: kind.tint
                )
            } else {
                MetricTile(
                    title: "Average",
                    value: series.average.map { kind.display($0) }?.formatted(unit: kind.unit) ?? "--",
                    unit: kind.unit.isEmpty ? nil : kind.unit,
                    systemImage: "chart.line.flattrend.xyaxis",
                    tint: kind.tint
                )
                MetricTile(
                    title: "Range seen",
                    value: rangeText,
                    unit: kind.unit.isEmpty ? nil : kind.unit,
                    systemImage: "arrow.up.arrow.down",
                    tint: kind.tint
                )
            }
            MetricTile(
                title: "Best day",
                value: series.maximum.map { kind.display($0) }?.formatted(unit: kind.unit) ?? "--",
                unit: kind.unit.isEmpty ? nil : kind.unit,
                systemImage: "arrow.up.right",
                tint: kind.tint
            )
            MetricTile(
                title: "Days with data",
                value: "\(points.count)",
                unit: String(format: tr("of %ld"), window.rawValue),
                systemImage: "calendar",
                tint: .secondary
            )
        }
    }

    private var rangeText: String {
        guard let lowest = low.minimum, let highest = high.maximum else { return "--" }
        return kind.display(lowest).formatted(unit: kind.unit)
            + "-" + kind.display(highest).formatted(unit: kind.unit)
    }

    @ViewBuilder
    private var coverageNote: some View {
        let gaps = series.gaps(in: window.rawValue)
        if gaps > 0 && !loading {
            Text("\(gaps) of the \(window.rawValue) days have no sample at all, so the averages above describe \(points.count) days, not \(window.rawValue).")
            .font(.caption)
            .foregroundStyle(.secondary)
            .cardStyle(padding: 10)
        }
    }

    private func load() async {
        loading = true
        let trends = coordinator.trends
        if kind.isCumulative {
            series = await trends.dailyTotals(kind, days: window.rawValue)
        } else {
            series = await trends.dailyAverages(kind, days: window.rawValue)
            if kind == .restingHeartRate {
                low = HealthTrends.Series()
                high = HealthTrends.Series()
            } else {
                let band = await trends.dailyRange(kind, days: window.rawValue)
                low = band.low
                high = band.high
            }
        }
        loading = false
    }
}

extension Double {
    /// Sensible precision per unit: no one needs 7432.0000001 steps.
    func formatted(unit: String) -> String {
        switch unit {
        case "km", "ms": return String(format: "%.1f", self)
        case "%": return String(format: "%.0f", self)
        default: return String(format: "%.0f", self)
        }
    }
}
