import Foundation
import SQLite3
import os

/// The app's own health record: every sample the watch delivers, kept on the
/// iPhone in a SQLite file.
///
/// This is the source of truth for every screen. Apple Health is an optional
/// copy on top, because a sideloaded install cannot always get the HealthKit
/// entitlement, and the user's data should not depend on how the app was
/// signed.
///
/// Samples are keyed by the watch's deterministic uid, so a batch delivered
/// twice after a reconnect is a no-op. A batch is ACKed only after the
/// transaction here has committed, which keeps the watch's spool as the backup
/// until the phone really has the data.
///
/// Day grouping uses SQLite's `localtime`, which follows the device time zone,
/// so "today" here is the same day the user sees on the lock screen.
actor LocalHealthStore {

    struct DayStat: Sendable {
        let day: Date
        let sum: Double
        let min: Double
        let max: Double
        let average: Double
        let count: Int
    }

    struct TimePoint: Sendable, Identifiable {
        let date: Date
        let value: Double
        var min: Double = 0
        var max: Double = 0
        var id: Date { date }
    }

    struct Segment: Sendable {
        let start: Date
        let end: Date
        let value: Double
    }

    struct Summary: Sendable {
        var samples = 0
        var workouts = 0
        var oldest: Date?
        var newest: Date?
        var bytes: Int64 = 0
    }

    enum StoreError: Error, LocalizedError {
        case sqlite(String)
        var errorDescription: String? {
            switch self {
            case .sqlite(let message): return "Local database: \(message)"
            }
        }
    }

    private var db: OpaquePointer?
    private let url: URL
    private let log = Logger(subsystem: "dev.galaxybridge.companion", category: "store")

    /// SQLite must copy bound text, because Swift strings are temporary.
    nonisolated(unsafe) private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appendingPathComponent("health.sqlite")
    }

    // MARK: - Setup

    private func open() throws -> OpaquePointer {
        if let db { return db }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw StoreError.sqlite("cannot open \(url.lastPathComponent)")
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("""
            CREATE TABLE IF NOT EXISTS samples (
                uid TEXT PRIMARY KEY,
                metric TEXT NOT NULL,
                value REAL NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                received_ms INTEGER NOT NULL
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS samples_metric_start ON samples(metric, start_ms)")
        try exec("""
            CREATE TABLE IF NOT EXISTS workouts (
                uid TEXT PRIMARY KEY,
                type TEXT NOT NULL,
                start_ms INTEGER NOT NULL,
                end_ms INTEGER NOT NULL,
                json TEXT NOT NULL
            )
            """)
        try exec("CREATE INDEX IF NOT EXISTS workouts_start ON workouts(start_ms)")
        try exec("""
            CREATE TABLE IF NOT EXISTS ecg (
                uid TEXT PRIMARY KEY,
                start_ms INTEGER NOT NULL,
                json TEXT NOT NULL
            )
            """)
        return handle
    }

    /// A consistent copy of the whole database at `destination`, taken while
    /// the app keeps running (SQLite's VACUUM INTO).
    func snapshot(to destination: URL) throws {
        _ = try open()
        try? FileManager.default.removeItem(at: destination)
        let path = destination.path.replacingOccurrences(of: "'", with: "''")
        try exec("VACUUM INTO '\(path)'")
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw StoreError.sqlite("not open") }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw StoreError.sqlite(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let db = try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    /// Runs a read query, handing each row to `row`.
    private func query(_ sql: String, _ bind: [Any] = [], row: (OpaquePointer) -> Void) {
        do {
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bindAll(statement, bind)
            while sqlite3_step(statement) == SQLITE_ROW {
                row(statement)
            }
        } catch {
            log.error("query failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func bindAll(_ statement: OpaquePointer, _ values: [Any]) {
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case let text as String:
                sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case let number as Int64:
                sqlite3_bind_int64(statement, position, number)
            case let number as Int:
                sqlite3_bind_int64(statement, position, Int64(number))
            case let number as Double:
                sqlite3_bind_double(statement, position, number)
            default:
                sqlite3_bind_null(statement, position)
            }
        }
    }

    // MARK: - Writes

    /// Stores a batch atomically and returns how many samples were new.
    @discardableResult
    func insert(_ samples: [HealthSample]) throws -> Int {
        let db = try open()
        try exec("BEGIN IMMEDIATE")
        do {
            let statement = try prepare("""
                INSERT OR IGNORE INTO samples (uid, metric, value, start_ms, end_ms, received_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            var inserted = 0
            for sample in samples where sample.end >= sample.start && sample.value.isFinite {
                sqlite3_reset(statement)
                bindAll(statement, [sample.uid, sample.metric.rawValue, sample.value, sample.start, sample.end, now])
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
                }
                inserted += Int(sqlite3_changes(db))
            }
            try exec("COMMIT")
            return inserted
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Tops today up to the watch's own running total when samples went
    /// missing here (a wipe, a reinstall, a batch lost before this build).
    /// The filler covers midnight to the reading, under a uid fixed per day
    /// and total, so it is written once and later totals add only the rest.
    func fillGaps(_ totals: [DayTotal]) throws -> [HealthSample] {
        var fillers: [HealthSample] = []
        for total in totals where total.at > total.dayStart && total.value.isFinite {
            var stored = 0.0
            query(
                "SELECT COALESCE(SUM(value), 0) FROM samples WHERE metric = ? AND start_ms >= ? AND start_ms < ?",
                [total.metric.rawValue, total.dayStart, total.dayStart + 86_400_000]
            ) { row in stored = sqlite3_column_double(row, 0) }
            let gap = total.value - stored
            let threshold = total.metric == .distance ? 10.0 : (total.metric == .activeEnergy ? 5.0 : 1.0)
            guard gap >= threshold else { continue }
            fillers.append(
                HealthSample(
                    metric: total.metric,
                    value: gap,
                    start: total.dayStart,
                    end: total.at,
                    uid: "fill-\(total.metric.rawValue)-\(total.dayStart)-\(Int64(total.value.rounded()))"
                )
            )
        }
        if !fillers.isEmpty { _ = try insert(fillers) }
        return fillers
    }

    func insert(workout: WorkoutSummary) throws {
        let data = try JSONEncoder().encode(workout)
        let json = String(decoding: data, as: UTF8.self)
        let statement = try prepare("""
            INSERT OR REPLACE INTO workouts (uid, type, start_ms, end_ms, json) VALUES (?, ?, ?, ?, ?)
            """)
        defer { sqlite3_finalize(statement) }
        bindAll(statement, [workout.uid, workout.type, workout.start, workout.end, json])
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.sqlite("workout insert failed")
        }
    }

    func insert(ecg record: EcgRecord) throws {
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        let statement = try prepare("INSERT OR REPLACE INTO ecg (uid, start_ms, json) VALUES (?, ?, ?)")
        defer { sqlite3_finalize(statement) }
        bindAll(statement, [record.uid, record.start, json])
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.sqlite("ecg insert failed")
        }
    }

    func ecgRecords(limit: Int = 100) -> [EcgRecord] {
        var result: [EcgRecord] = []
        let decoder = JSONDecoder()
        query("SELECT json FROM ecg ORDER BY start_ms DESC LIMIT ?", [limit]) { row in
            if let record = try? decoder.decode(EcgRecord.self, from: Data(Self.text(row, 0).utf8)) {
                result.append(record)
            }
        }
        return result
    }

    /// Removes one metric's samples lying wholly inside the range: how a
    /// wrongly recorded night or nap is taken out.
    @discardableResult
    func deleteSamples(_ metric: Metric, from start: Date, to end: Date) throws -> Int {
        let db = try open()
        let statement = try prepare("DELETE FROM samples WHERE metric = ? AND start_ms >= ? AND end_ms <= ?")
        defer { sqlite3_finalize(statement) }
        bindAll(statement, [metric.rawValue, Self.millis(start), Self.millis(end)])
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw StoreError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return Int(sqlite3_changes(db))
    }

    func deleteAll() throws {
        _ = try open()
        try exec("DELETE FROM samples")
        try exec("DELETE FROM workouts")
        try exec("DELETE FROM ecg")
        try exec("VACUUM")
    }

    // MARK: - Reads

    private static let dayExpression =
        "strftime('%Y-%m-%d', start_ms / 1000, 'unixepoch', 'localtime')"

    private static func dayParser() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    /// One row per local day that has at least one sample. Days without data
    /// are absent, never zero.
    func dailyStats(_ metric: Metric, from start: Date, to end: Date = Date()) -> [DayStat] {
        var result: [DayStat] = []
        let formatter = Self.dayParser()
        query(
            """
            SELECT \(Self.dayExpression) AS day, SUM(value), MIN(value), MAX(value), AVG(value), COUNT(*)
            FROM samples WHERE metric = ? AND start_ms >= ? AND start_ms < ?
            GROUP BY day ORDER BY day
            """,
            [metric.rawValue, Self.millis(start), Self.millis(end)]
        ) { row in
            guard let day = formatter.date(from: Self.text(row, 0)) else { return }
            result.append(
                DayStat(
                    day: day,
                    sum: sqlite3_column_double(row, 1),
                    min: sqlite3_column_double(row, 2),
                    max: sqlite3_column_double(row, 3),
                    average: sqlite3_column_double(row, 4),
                    count: Int(sqlite3_column_int64(row, 5))
                )
            )
        }
        return result
    }

    /// Totals or averages in fixed buckets (e.g. one hour, five minutes).
    func buckets(
        _ metric: Metric,
        from start: Date,
        to end: Date = Date(),
        seconds: Int
    ) -> [TimePoint] {
        var result: [TimePoint] = []
        let size = Int64(seconds) * 1000
        query(
            """
            SELECT (start_ms / ?) * ? AS bucket, SUM(value), AVG(value), MIN(value), MAX(value)
            FROM samples WHERE metric = ? AND start_ms >= ? AND start_ms < ?
            GROUP BY bucket ORDER BY bucket
            """,
            [size, size, metric.rawValue, Self.millis(start), Self.millis(end)]
        ) { row in
            let cumulative = metric.isCumulative
            result.append(
                TimePoint(
                    date: Self.date(sqlite3_column_int64(row, 0)),
                    value: cumulative ? sqlite3_column_double(row, 1) : sqlite3_column_double(row, 2),
                    min: sqlite3_column_double(row, 3),
                    max: sqlite3_column_double(row, 4)
                )
            )
        }
        return result
    }

    func latest(_ metric: Metric) -> TimePoint? {
        var point: TimePoint?
        query(
            "SELECT end_ms, value FROM samples WHERE metric = ? ORDER BY end_ms DESC LIMIT 1",
            [metric.rawValue]
        ) { row in
            point = TimePoint(date: Self.date(sqlite3_column_int64(row, 0)), value: sqlite3_column_double(row, 1))
        }
        return point
    }

    /// Raw values in a window, for percentiles and zone counts.
    func values(_ metric: Metric, from start: Date, to end: Date = Date()) -> [Double] {
        var result: [Double] = []
        query(
            "SELECT value FROM samples WHERE metric = ? AND start_ms >= ? AND start_ms < ?",
            [metric.rawValue, Self.millis(start), Self.millis(end)]
        ) { row in
            result.append(sqlite3_column_double(row, 0))
        }
        return result
    }

    func segments(_ metric: Metric, from start: Date, to end: Date = Date()) -> [Segment] {
        var result: [Segment] = []
        query(
            """
            SELECT start_ms, end_ms, value FROM samples
            WHERE metric = ? AND end_ms >= ? AND start_ms < ? ORDER BY start_ms
            """,
            [metric.rawValue, Self.millis(start), Self.millis(end)]
        ) { row in
            result.append(
                Segment(
                    start: Self.date(sqlite3_column_int64(row, 0)),
                    end: Self.date(sqlite3_column_int64(row, 1)),
                    value: sqlite3_column_double(row, 2)
                )
            )
        }
        return result
    }

    func workouts(limit: Int = 200, since: Date? = nil) -> [WorkoutSummary] {
        var result: [WorkoutSummary] = []
        let decoder = JSONDecoder()
        query(
            "SELECT json FROM workouts WHERE start_ms >= ? ORDER BY start_ms DESC LIMIT ?",
            [Self.millis(since ?? .distantPast), limit]
        ) { row in
            let json = Self.text(row, 0)
            if let workout = try? decoder.decode(WorkoutSummary.self, from: Data(json.utf8)) {
                result.append(workout)
            }
        }
        return result
    }

    /// Every sample since `start`, oldest first: the export and the Apple
    /// Health copy both read this.
    func allSamples(since start: Date) -> [HealthSample] {
        var result: [HealthSample] = []
        query(
            "SELECT uid, metric, value, start_ms, end_ms FROM samples WHERE start_ms >= ? ORDER BY start_ms",
            [Self.millis(start)]
        ) { row in
            guard let metric = Metric(rawValue: Self.text(row, 1)) else { return }
            result.append(
                HealthSample(
                    metric: metric,
                    value: sqlite3_column_double(row, 2),
                    start: sqlite3_column_int64(row, 3),
                    end: sqlite3_column_int64(row, 4),
                    uid: Self.text(row, 0)
                )
            )
        }
        return result
    }

    func summary() -> Summary {
        var summary = Summary()
        query("SELECT COUNT(*), MIN(start_ms), MAX(end_ms) FROM samples") { row in
            summary.samples = Int(sqlite3_column_int64(row, 0))
            if sqlite3_column_type(row, 1) != SQLITE_NULL {
                summary.oldest = Self.date(sqlite3_column_int64(row, 1))
                summary.newest = Self.date(sqlite3_column_int64(row, 2))
            }
        }
        query("SELECT COUNT(*) FROM workouts") { row in
            summary.workouts = Int(sqlite3_column_int64(row, 0))
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        summary.bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return summary
    }
}

extension Metric {
    /// Cumulative metrics add up over a day; the rest are point readings.
    var isCumulative: Bool {
        switch self {
        case .steps, .activeEnergy, .distance, .floors: return true
        case .heartRate, .spo2, .sleep, .restingHeartRate, .hrv, .skinTemperature, .bodyFat,
             .skeletalMuscle, .bodyWater, .bmr, .respiratoryRate:
            return false
        }
    }
}
