import Foundation

/// The watch's own Bluetooth trail, shipped over the bridge on every
/// connection and kept here next to the iPhone's, so one export shows both
/// sides of a reconnect that went wrong.
///
/// The watch sends its last lines each time, overlapping what came before;
/// lines are de-duplicated by their exact text, which starts with a
/// millisecond timestamp.
@MainActor
enum WatchTrail {
    private static let maximumLines = 800

    private static var url: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("watch-trail.log")
    }

    static func lines() -> [String] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    static func merge(_ text: String) {
        var current = lines()
        let seen = Set(current)
        let incoming = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty && !seen.contains($0) }
        guard !incoming.isEmpty else { return }
        current += incoming
        if current.count > maximumLines { current.removeFirst(current.count - maximumLines) }
        guard let url else { return }
        try? (current.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    static func clear() {
        guard let url else { return }
        try? Data().write(to: url, options: .atomic)
    }

    /// Both trails as one text file, for sharing.
    static func report() -> URL? {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String ?? "?") + " (" + (info?["CFBundleVersion"] as? String ?? "?") + ")"
        var text = "GalaxyBridge diagnostics\n"
        text += "Exported: \(Date().formatted(date: .abbreviated, time: .standard))\n"
        text += "iPhone app: \(version), iOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
        text += "===== iPhone trail (times MM-dd HH:mm:ss) =====\n"
        text += Breadcrumbs.current()
        text += "\n===== Watch trail (times MM-dd HH:mm:ss, watch clock) =====\n"
        text += lines().joined(separator: "\n")
        text += "\n"
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("GalaxyBridge-diagnostics.txt")
        do {
            try text.write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }
}
