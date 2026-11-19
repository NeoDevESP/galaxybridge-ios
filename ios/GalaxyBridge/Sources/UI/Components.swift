import SwiftUI

/// The grouped look of Apple's own Health app: content on white (or dark grey)
/// cards with continuous corners, over the grouped system background.
extension View {
    func cardStyle(padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }

    /// Background for scrolling screens that hold cards.
    func groupedBackground() -> some View {
        self.background(Color(.systemGroupedBackground).ignoresSafeArea())
    }
}

/// A single activity ring: a faint track and a stroke that deepens towards its
/// end, with a round cap.
struct ActivityRing: View {
    let progress: Double
    let colour: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(colour.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(
                    AngularGradient(
                        colors: [colour.opacity(0.75), colour],
                        center: .center,
                        startAngle: .degrees(0),
                        endAngle: .degrees(360 * max(min(progress, 1), 0.01))
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: progress >= 1 ? colour.opacity(0.65) : .clear, radius: lineWidth * 0.6)
                .animation(.spring(response: 1.0, dampingFraction: 0.82), value: progress)
        }
    }
}

/// The three-ring stack for today: energy, steps, distance.
struct RingStack: View {
    let energy: Double
    let energyGoal: Double
    let steps: Double
    let stepGoal: Double
    let distance: Double
    let distanceGoal: Double
    var size: CGFloat = 190

    /// Starts empty so each ring sweeps round when the screen appears.
    @State private var shown = false

    static let energyColour = Color(red: 0.98, green: 0.07, blue: 0.31)
    static let stepsColour = Color(red: 0.65, green: 1.0, blue: 0.0)
    static let distanceColour = Color(red: 0.0, green: 0.88, blue: 1.0)

    /// How many rings are closed, so closing one taps the wrist of the phone.
    private var closedRings: Int {
        guard shown else { return 0 }
        return [energyGoal > 0 && energy >= energyGoal, stepGoal > 0 && steps >= stepGoal,
                distanceGoal > 0 && distance >= distanceGoal].filter { $0 }.count
    }

    var body: some View {
        let line = size * 16 / 190
        ZStack {
            ActivityRing(
                progress: shown && energyGoal > 0 ? energy / energyGoal : 0,
                colour: Self.energyColour,
                lineWidth: line
            )
            ActivityRing(
                progress: shown && stepGoal > 0 ? steps / stepGoal : 0,
                colour: Self.stepsColour,
                lineWidth: line
            )
            .padding(size * 22 / 190)
            ActivityRing(
                progress: shown && distanceGoal > 0 ? distance / distanceGoal : 0,
                colour: Self.distanceColour,
                lineWidth: line
            )
            .padding(size * 44 / 190)
        }
        .frame(width: size, height: size)
        .onAppear { shown = true }
        .sensoryFeedback(.success, trigger: closedRings) { old, new in new > old }
        .accessibilityElement()
        .accessibilityLabel(
            "\(Int(energy)) of \(Int(energyGoal)) kilocalories, \(Int(steps)) of \(Int(stepGoal)) steps, "
                + String(format: "%.1f of %.1f kilometres", distance / 1000, distanceGoal / 1000)
        )
    }
}

/// One metric tile. `value` is pre-formatted; this view does not guess units.
struct MetricTile: View {
    @State private var appeared = false
    let title: String
    let value: String
    let unit: String?
    let systemImage: String
    let tint: Color
    var footnote: String?
    /// Shows a chevron, for tiles that open a detail screen.
    var navigable = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .symbolEffect(.bounce, value: appeared)
                Text(tr(title))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if navigable {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let unit {
                    Text(tr(unit))
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            if let footnote {
                Text(tr(footnote))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 12)
        .onAppear { appeared = true }
    }
}

/// Connection pill, used in the header of every tab so the state is never more
/// than a glance away.
struct LinkPill: View {
    let connected: Bool
    let scanning: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: connected ? "applewatch.radiowaves.left.and.right" : "applewatch.slash")
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.pulse, isActive: scanning && !connected)
                .foregroundStyle(connected ? .green : (scanning ? .orange : .secondary))
            Text(connected ? "Connected" : (scanning ? "Searching" : "Offline"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.thinMaterial, in: Capsule())
    }
}

extension Double {
    var oneDecimal: String { String(format: "%.1f", self) }
    var noDecimals: String { String(format: "%.0f", self) }
}

extension TimeInterval {
    /// "7 h 42 min", or nil-safe "--" handled by the caller.
    var hoursMinutes: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours) h \(minutes) min" : "\(minutes) min"
    }
}
