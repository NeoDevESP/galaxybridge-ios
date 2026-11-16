import XCTest

final class LocalHealthStoreTests: XCTestCase {

    private func sample(_ metric: Metric, _ value: Double, at date: Date, uid: String) -> HealthSample {
        let ms = Int64(date.timeIntervalSince1970 * 1000)
        return HealthSample(metric: metric, value: value, start: ms, end: ms + 60_000, uid: uid)
    }

    func testDuplicateBatchIsStoredOnce() async throws {
        let store = LocalHealthStore()
        try await store.deleteAll()
        // Yesterday at noon, not "now": run just after midnight, ten minutes
        // ago was the previous day and the test failed on the clock alone.
        let now = Calendar.current.date(
            byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date())
        )!.addingTimeInterval(12 * 3600)
        let batch = [
            sample(.steps, 100, at: now.addingTimeInterval(-600), uid: "a"),
            sample(.steps, 250, at: now.addingTimeInterval(-300), uid: "b"),
        ]
        let first = try await store.insert(batch)
        let second = try await store.insert(batch)
        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 0, "a batch delivered twice must not double the steps")

        let today = await store.dailyStats(.steps, from: Calendar.current.startOfDay(for: now))
        XCTAssertEqual(today.count, 1)
        XCTAssertEqual(today.first?.sum, 350)
    }

    func testDaysWithoutDataAreAbsentNotZero() async throws {
        let store = LocalHealthStore()
        try await store.deleteAll()
        let calendar = Calendar.current
        // Yesterday noon: today noon is still in the future before midday.
        let today = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date()))!
            .addingTimeInterval(12 * 3600)
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today)!
        try await store.insert([
            sample(.heartRate, 60, at: today, uid: "h1"),
            sample(.heartRate, 80, at: today.addingTimeInterval(60), uid: "h2"),
            sample(.heartRate, 70, at: threeDaysAgo, uid: "h3"),
        ])
        let start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date()))!
        let stats = await store.dailyStats(.heartRate, from: start)
        XCTAssertEqual(stats.count, 2)
        XCTAssertEqual(stats.last?.average, 70)
        XCTAssertEqual(stats.last?.min, 60)
        XCTAssertEqual(stats.last?.max, 80)
    }

    func testWorkoutRoundTrip() async throws {
        let store = LocalHealthStore()
        try await store.deleteAll()
        let workout = WorkoutSummary(
            uid: "w1", type: "RUNNING", start: 1_000, end: 1_801_000,
            activeEnergyKcal: 300, distanceMeters: 5_000, avgHeartRate: 150, maxHeartRate: 175,
            route: [GeoPoint(lat: 40.4, lon: -3.7, alt: nil, t: 1_000, hAcc: nil)]
        )
        try await store.insert(workout: workout)
        let all = await store.workouts()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.route?.count, 1)
        XCTAssertEqual(all.first?.distanceMeters, 5_000)
    }

    func testRestingEstimateUsesTheLowestTenth() {
        let values = (0..<100).map { Double(60 + $0) }
        XCTAssertEqual(HealthMath.restingEstimate(fiveMinuteAverages: values)!, 64.5, accuracy: 0.01)
        XCTAssertNil(HealthMath.restingEstimate(fiveMinuteAverages: [60, 61, 62]))
    }

    func testZonesFollowAge() {
        let zones = HealthMath.zones(age: 40)
        XCTAssertEqual(zones.count, 5)
        XCTAssertEqual(HealthMath.maximumHeartRate(age: 40), 180, accuracy: 0.01)
        XCTAssertEqual(zones[2].lower, 126, accuracy: 0.01)
    }
}
