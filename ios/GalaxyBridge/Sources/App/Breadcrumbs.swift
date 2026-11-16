import Foundation
import os

/// An append-only trail on disk, shown in the Diagnostics tab after a restart.
///
/// A sideloaded app cannot be attached to a debugger, and its crash reports are
/// buried in Settings behind a list of hundreds of files. When the app dies,
/// the only question that matters is how far it got, and the answer has to
/// survive the process. So every interesting step writes one line here, with a
/// marker for the process start, and the previous run's trail is read back and
/// displayed on the next launch.
///
/// Writes are small, flushed immediately and never block on a reply, because a
/// buffered log is empty exactly when it is needed.
enum Breadcrumbs {

    private static let log = Logger(subsystem: "dev.galaxybridge.companion", category: "trail")
    private static let queue = DispatchQueue(label: "dev.galaxybridge.breadcrumbs")
    private static let maximumBytes = 64 * 1024

    private static var url: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("breadcrumbs.log")
    }

    /// The trail as it stood when this process started, i.e. including whatever
    /// the run that died managed to write.
    private(set) static var previousRun: String = ""

    /// Call once, as early as possible.
    static func startRun(version: String) {
        previousRun = read()
        drop("=== launch \(version) at \(stamp()) ===")
    }

    static func drop(_ message: String) {
        log.info("\(message, privacy: .public)")
        queue.async {
            guard let url else { return }
            let line = stamp() + "  " + message + "\n"
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                // Append, and keep the file from growing without bound by
                // starting over once it is large: the recent past is what
                // matters, and a trail nobody can open is useless.
                if let size = try? handle.seekToEnd(), size > maximumBytes {
                    // Keep the newer half rather than wiping everything: the
                    // lead-up to a problem is the useful part.
                    try? handle.seek(toOffset: size / 2)
                    var tail = (try? handle.readToEnd()) ?? Data()
                    if let newline = tail.firstIndex(of: 0x0A) {
                        tail = tail.subdata(in: tail.index(after: newline)..<tail.endIndex)
                    }
                    try? handle.truncate(atOffset: 0)
                    try? handle.write(contentsOf: tail)
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// The trail as it stands now, this run included.
    static func current() -> String {
        queue.sync { read() }
    }

    static func clear() {
        queue.async {
            guard let url else { return }
            try? Data().write(to: url, options: .atomic)
        }
        previousRun = ""
    }

    private static func read() -> String {
        guard let url, let data = try? Data(contentsOf: url) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}
