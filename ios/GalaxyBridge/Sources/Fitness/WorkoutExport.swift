import Foundation

/// A workout as a TCX file, the format Strava, Garmin Connect, TrainingPeaks
/// and most training apps import: the route with altitude when there is one,
/// and the heart rate the watch recorded every 10 seconds.
enum WorkoutExport {

    static func tcx(_ workout: WorkoutSummary) -> URL? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func time(_ ms: Int64) -> String { iso.string(from: Date(timeIntervalSince1970: Double(ms) / 1000)) }

        let trace = workout.heartRateTrace ?? []
        func heartRate(at ms: Int64) -> Int? {
            guard !trace.isEmpty else { return nil }
            let index = Int((ms - workout.start) / 10_000)
            let bpm = trace[min(max(index, 0), trace.count - 1)]
            return bpm > 0 ? bpm : nil
        }

        var points = ""
        if let route = workout.route, route.count > 1 {
            for point in route {
                points += "<Trackpoint><Time>\(time(point.t))</Time>"
                points += "<Position><LatitudeDegrees>\(point.lat)</LatitudeDegrees>"
                points += "<LongitudeDegrees>\(point.lon)</LongitudeDegrees></Position>"
                if let alt = point.alt { points += "<AltitudeMeters>\(alt)</AltitudeMeters>" }
                if let bpm = heartRate(at: point.t) { points += "<HeartRateBpm><Value>\(bpm)</Value></HeartRateBpm>" }
                points += "</Trackpoint>\n"
            }
        } else {
            for (index, bpm) in trace.enumerated() where bpm > 0 {
                points += "<Trackpoint><Time>\(time(workout.start + Int64(index) * 10_000))</Time>"
                points += "<HeartRateBpm><Value>\(bpm)</Value></HeartRateBpm></Trackpoint>\n"
            }
        }

        let seconds = Double(workout.activeDurationMs ?? (workout.end - workout.start)) / 1000
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
        <Activities><Activity Sport="\(sport(workout.type))">
        <Id>\(time(workout.start))</Id>
        <Lap StartTime="\(time(workout.start))">
        <TotalTimeSeconds>\(Int(seconds))</TotalTimeSeconds>
        <DistanceMeters>\(Int(workout.distanceMeters))</DistanceMeters>
        <Calories>\(Int(workout.activeEnergyKcal))</Calories>
        \(workout.avgHeartRate.map { "<AverageHeartRateBpm><Value>\(Int($0))</Value></AverageHeartRateBpm>" } ?? "")
        \(workout.maxHeartRate.map { "<MaximumHeartRateBpm><Value>\(Int($0))</Value></MaximumHeartRateBpm>" } ?? "")
        <Intensity>Active</Intensity><TriggerMethod>Manual</TriggerMethod>
        <Track>
        \(points)</Track>
        </Lap>
        <Creator xsi:type="Device_t" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><Name>Galaxy Watch</Name></Creator>
        </Activity></Activities>
        </TrainingCenterDatabase>
        """

        let stamp = Date(timeIntervalSince1970: Double(workout.start) / 1000)
            .formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalaxyBridge-\(workout.type.lowercased())-\(stamp).tcx")
        do {
            try xml.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// TCX knows three sports; everything else is "Other".
    private static func sport(_ type: String) -> String {
        switch type.uppercased() {
        case "RUNNING", "INDOOR_RUN", "WALKING", "HIKING": return "Running"
        case "BIKING": return "Biking"
        default: return "Other"
        }
    }
}
