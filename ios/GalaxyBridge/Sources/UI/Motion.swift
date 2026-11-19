import SwiftUI

/// The app's motion, built only from what iOS itself offers (the same tools
/// Apple's apps use): zoom transitions, scroll transitions, mesh gradients,
/// numeric text, symbol effects and sensory feedback. No third-party library:
/// these stay smooth, cost nothing to ship and follow Reduce Motion.

extension View {
    /// Cards settle in as they scroll into view, the way Health's do.
    func scrollSettle() -> some View {
        scrollTransition(.interactive, axis: .vertical) { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1 : 0.94)
                .opacity(phase.isIdentity ? 1 : 0.6)
                .blur(radius: phase.isIdentity ? 0 : 1)
        }
    }

    /// Marks the view a detail screen zooms out of (iOS 18; a push before).
    @ViewBuilder
    func zoomSource<ID: Hashable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// The detail screen that grows out of its card and shrinks back into it.
    @ViewBuilder
    func zoomDestination<ID: Hashable>(_ id: ID, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

/// A number that rolls its digits from zero when it first appears, then to
/// each new value.
struct RollingNumber: View {
    let value: Double
    var decimals = 0

    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(String(format: "%.\(decimals)f", shown))
            .monospacedDigit()
            .contentTransition(.numericText(value: shown))
            .onAppear {
                if reduceMotion {
                    shown = value
                } else {
                    withAnimation(.smooth(duration: 1.1)) { shown = value }
                }
            }
            .onChange(of: value) { _, new in
                withAnimation(.snappy) { shown = new }
            }
    }
}

/// A dark, slowly drifting glow in the ring colours, behind today's rings.
/// A mesh gradient on iOS 18; plain black before, and still with Reduce Motion.
struct AuroraBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if #available(iOS 18.0, *) {
            if reduceMotion {
                Color.black
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    MeshGradient(
                        width: 3,
                        height: 3,
                        points: Self.points(at: Float(context.date.timeIntervalSinceReferenceDate)),
                        colors: Self.colours
                    )
                }
            }
        } else {
            Color.black
        }
    }

    /// The middle points drift slowly; the corners stay pinned.
    private static func points(at t: Float) -> [SIMD2<Float>] {
        let top = SIMD2<Float>(0.5 + 0.08 * sin(t * 0.5), 0)
        let left = SIMD2<Float>(0, 0.5 + 0.1 * cos(t * 0.4))
        let centre = SIMD2<Float>(0.45 + 0.12 * sin(t * 0.6), 0.5 + 0.12 * cos(t * 0.5))
        let right = SIMD2<Float>(1, 0.5 + 0.1 * sin(t * 0.45))
        let bottom = SIMD2<Float>(0.5 + 0.08 * cos(t * 0.55), 1)
        return [
            SIMD2<Float>(0, 0), top, SIMD2<Float>(1, 0),
            left, centre, right,
            SIMD2<Float>(0, 1), bottom, SIMD2<Float>(1, 1),
        ]
    }

    private static let colours: [Color] = [
        .black, RingStack.energyColour.opacity(0.28), .black,
        RingStack.stepsColour.opacity(0.16), .black, RingStack.distanceColour.opacity(0.24),
        .black, RingStack.energyColour.opacity(0.14), .black,
    ]
}

/// Reveals its content from left to right when it appears: a chart drawing in.
struct DrawIn: ViewModifier {
    @State private var reveal: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                Rectangle().scaleEffect(x: reveal, anchor: .leading)
            }
            .onAppear {
                if reduceMotion {
                    reveal = 1
                } else {
                    withAnimation(.easeOut(duration: 1.0).delay(0.15)) { reveal = 1 }
                }
            }
    }
}

extension View {
    func drawIn() -> some View { modifier(DrawIn()) }
}
