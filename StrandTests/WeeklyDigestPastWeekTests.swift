import XCTest
import WhoopStore
@testable import Strand

/// Browsing back to a past week in Trends must not read "so far" (2026-10-21).
final class WeeklyDigestPastWeekTests: XCTestCase {

    private func daily(_ day: String, recovery: Double) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                    avgHrv: nil, recovery: recovery, strain: nil, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil, steps: nil)
    }

    private var sparseWeek: [DailyMetric] {
        (1...7).map { daily(String(format: "2026-06-%02d", $0), recovery: 70) }
            + [daily("2026-06-08", recovery: 40), daily("2026-06-09", recovery: 40)]
    }

    func testPastWeekSpeaksInPastTense() {
        let d = WeeklyDigestSource.digest(from: sparseWeek, anchorDay: "2026-06-09",
                                          today: "2026-10-21", effortDisplayFactor: 1)
        let line = d.focalPoints.first ?? ""
        XCTAssertFalse(line.contains("so far"), line)
        XCTAssertTrue(line.contains("that week"), line)
    }

    func testCurrentWeekKeepsItsWording() {
        let d = WeeklyDigestSource.digest(from: sparseWeek, anchorDay: "2026-06-09",
                                          today: "2026-06-10", effortDisplayFactor: 1)
        XCTAssertTrue((d.focalPoints.first ?? "").contains("so far"))
    }
}
