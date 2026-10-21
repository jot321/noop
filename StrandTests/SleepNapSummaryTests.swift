import XCTest
import WhoopStore
@testable import Strand

/// The naps card's Main / Nap(s) / Total split showed TIME IN BED for the main sleep (awake minutes
/// included) beside asleep-looking labels, and claimed the total drives Rest. Rest scores the main
/// night's asleep minutes only (#525), so the split now shows asleep minutes. Synthetic values only.
final class SleepNapSummaryTests: XCTestCase {

    private func nap(start: Int, minutes: Int, stagesJSON: String?) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: start + minutes * 60, efficiency: nil,
                           restingHr: nil, avgHrv: nil, stagesJSON: stagesJSON)
    }

    func testMainSleepIsAsleepMinutesNotTimeInBed() {
        let split = SleepView.napSummaryMinutes(mainAwakeMin: 45, mainAsleepMin: 400, naps: [])
        XCTAssertEqual(split.main, 400, accuracy: 0.001)
    }

    func testNapCountsItsAsleepMinutes() {
        let t = 1_800_000_000
        // A 40-minute nap with 10 minutes awake at the start.
        let staged = "[{\"start\":\(t),\"end\":\(t + 600),\"stage\":\"wake\"},"
            + "{\"start\":\(t + 600),\"end\":\(t + 2_400),\"stage\":\"light\"}]"
        let split = SleepView.napSummaryMinutes(mainAwakeMin: 30, mainAsleepMin: 420,
                                                naps: [nap(start: t, minutes: 40, stagesJSON: staged)])
        XCTAssertEqual(split.naps, 30, accuracy: 0.001)
    }

    func testUnstagedNapFallsBackToItsWindow() {
        let split = SleepView.napSummaryMinutes(mainAwakeMin: 0, mainAsleepMin: 420,
                                                naps: [nap(start: 1_800_000_000, minutes: 25, stagesJSON: nil)])
        XCTAssertEqual(split.naps, 25, accuracy: 0.001)
    }
}
