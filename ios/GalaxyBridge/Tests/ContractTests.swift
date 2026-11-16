import XCTest

/// Mirrors ContractTest.kt: the same JSON strings, decoded here. If either app
/// changes a field, one of the two suites fails before a build ships.
final class ContractTests: XCTestCase {

    private let workoutNew = #"{"uid":"w1","type":"strength_training","start":1000,"end":61000,"activeEnergyKcal":42.5,"distanceMeters":0.0,"avgHeartRate":120.0,"maxHeartRate":150.0,"route":[{"lat":40.4,"lon":-3.7,"alt":650.0,"t":1000}],"activeDurationMs":55000,"heartRateTrace":[110,130]}"#
    private let workoutOld = #"{"uid":"w0","type":"running","start":1000,"end":61000,"activeEnergyKcal":10.0,"distanceMeters":100.0,"route":[]}"#
    private let live = #"{"kind":"STRENGTH","activeMs":65000,"heartRate":128,"energyKcal":80.0,"distanceMeters":0.0,"paused":false}"#

    func testMessageCodesMatchTheWatch() {
        XCTAssertEqual(MessageType.workoutAck.rawValue, 0x15)
        XCTAssertEqual(MessageType.workoutControl.rawValue, 0x16)
        XCTAssertEqual(MessageType.workoutLive.rawValue, 0x17)
        XCTAssertEqual(MessageType.workout.rawValue, 0x11)
        XCTAssertEqual(MessageType.healthBatch.rawValue, 0x10)
        XCTAssertEqual(MessageType.healthConfig.rawValue, 0x13)
    }

    func testWorkoutFromTheWatchDecodes() throws {
        let summary = try XCTUnwrap(BridgeCoder.decode(WorkoutSummary.self, from: Data(workoutNew.utf8)))
        XCTAssertEqual(summary.activeDurationMs, 55_000)
        XCTAssertEqual(summary.heartRateTrace, [110, 130])
        XCTAssertEqual(summary.route?.first?.alt, 650)
    }

    func testWorkoutFromAnOlderWatchDecodes() throws {
        let summary = try XCTUnwrap(BridgeCoder.decode(WorkoutSummary.self, from: Data(workoutOld.utf8)))
        XCTAssertNil(summary.activeDurationMs)
        XCTAssertNil(summary.heartRateTrace)
    }

    func testLiveWorkoutDecodes() throws {
        let value = try XCTUnwrap(BridgeCoder.decode(WorkoutLive.self, from: Data(live.utf8)))
        XCTAssertEqual(value.heartRate, 128)
        XCTAssertFalse(value.paused)
    }

    /// What the iPhone sends must be what ContractTest.kt decodes.
    func testSettingsEncodeAsTheWatchExpects() throws {
        let config = HealthConfig(
            enabled: [.steps, .heartRate, .restingHeartRate],
            flushInterval: 300,
            continuousHeartRate: false,
            profile: WatchBodyProfile(heightCm: 175, weightKg: 70.5, sex: "male", age: 40),
            sleepStages: true
        )
        let object = try JSONSerialization.jsonObject(with: BridgeCoder.encode(config))
        let json = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(json["enabled"] as? [String], ["STEPS", "HEART_RATE", "RESTING_HR"])
        XCTAssertEqual(json["flushInterval"] as? Int, 300)
        XCTAssertEqual((json["profile"] as? [String: Any])?["age"] as? Int, 40)
    }

    func testCalendarEncodesAsTheWatchExpects() throws {
        let event = CalendarEventDTO(
            id: "e1", title: "Gym", location: nil, start: 1, end: 2, allDay: false, calendarName: nil
        )
        let page = CalendarPage(page: 0, totalPages: 1, events: [event], revision: 1)
        let object = try JSONSerialization.jsonObject(with: BridgeCoder.encode(page))
        let json = try XCTUnwrap(object as? [String: Any])
        let first = try XCTUnwrap((json["events"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["title"] as? String, "Gym")
        XCTAssertEqual(first["allDay"] as? Bool, false)
    }

    /// The iPhone sends one ATT packet per frame (see BridgeClient.send).
    func testFramesFitOneAttPacket() {
        let payload = Data(repeating: 7, count: 2_000)
        let mtu = 185
        let frames = Frame.fragment(
            type: .contacts, seq: 1, payload: payload,
            maxPayload: mtu - 3 - Frame.headerSize, encrypted: true
        )
        XCTAssertTrue(frames.allSatisfy { $0.count <= mtu - 3 })
    }
}
