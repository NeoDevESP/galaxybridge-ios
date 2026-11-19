import Foundation

/// Sleep split into separate stretches wherever nothing was recorded for a
/// while, so a nap in the afternoon is never added to the night before it.
enum SleepSessions {

    struct Session: Sendable {
        let segments: [LocalHealthStore.Segment]

        var start: Date { segments.first?.start ?? .distantPast }
        var end: Date { segments.map(\.end).max() ?? .distantPast }

        /// Value 1 is awake; everything else is a stage of sleep.
        var asleep: TimeInterval {
            segments.filter { $0.value != 1 }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        }

        var awake: TimeInterval {
            segments.filter { $0.value == 1 }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        }

        /// Short and started in the daytime: a nap, kept apart from the night.
        var isNap: Bool {
            let hour = Calendar.current.component(.hour, from: start)
            return asleep < 3 * 3600 && (9...19).contains(hour)
        }
    }

    /// Longer than this with nothing recorded starts a new stretch.
    static let gap: TimeInterval = 90 * 60

    static func split(_ segments: [LocalHealthStore.Segment]) -> [Session] {
        var sessions: [Session] = []
        var current: [LocalHealthStore.Segment] = []
        var currentEnd = Date.distantPast
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if !current.isEmpty && segment.start.timeIntervalSince(currentEnd) > gap {
                sessions.append(Session(segments: current))
                current = []
            }
            current.append(segment)
            currentEnd = max(currentEnd, segment.end)
        }
        if !current.isEmpty {
            sessions.append(Session(segments: current))
        }
        return sessions
    }
}
