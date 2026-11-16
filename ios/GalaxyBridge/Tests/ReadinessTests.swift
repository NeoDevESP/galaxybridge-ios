import XCTest

final class ReadinessTests: XCTestCase {

    func testAGoodNightScoresFull() {
        let hours: TimeInterval = 8 * 3600
        let score = SleepScore(asleep: hours, deep: hours * 0.2, rem: hours * 0.22, awakenings: 0)
        XCTAssertEqual(score.total, 100)
    }

    func testShortBrokenNightScoresLow() {
        let hours: TimeInterval = 4.5 * 3600
        let score = SleepScore(asleep: hours, deep: hours * 0.05, rem: hours * 0.05, awakenings: 4)
        XCTAssertLessThan(score.total, 50)
    }

    func testReadinessFallsWithLowHrvAndHighRestingRate() {
        let sleep = SleepScore(asleep: 7.5 * 3600, deep: 3600, rem: 5400, awakenings: 1)
        let rested = Readiness.compute(
            sleep: sleep, hrvToday: 60, hrvBaseline: 55, restingToday: 52, restingBaseline: 54,
            stepsYesterday: 9000, stepGoal: 10_000
        )
        let strained = Readiness.compute(
            sleep: sleep, hrvToday: 35, hrvBaseline: 55, restingToday: 62, restingBaseline: 54,
            stepsYesterday: 9000, stepGoal: 10_000
        )
        XCTAssertNotNil(rested)
        XCTAssertNotNil(strained)
        XCTAssertGreaterThan(rested!.score, strained!.score + 15)
    }

    func testNoSleepAndNoHrvMeansNoScore() {
        XCTAssertNil(Readiness.compute(
            sleep: nil, hrvToday: nil, hrvBaseline: nil, restingToday: 55, restingBaseline: 55,
            stepsYesterday: 5000, stepGoal: 10_000
        ))
    }

    func testStressRisesAsHrvFallsBelowBaseline() {
        let calm = StressLevel.score(hrv: 70, baseline: 60) ?? 0
        let tense = StressLevel.score(hrv: 30, baseline: 60) ?? 0
        XCTAssertLessThan(calm, tense)
    }
}
