import XCTest
import WhoopStore
@testable import Strand

/// Trends windows are calendar days anchored on today, not counts of rows (2026-10-21).
final class TrendsWindowTests: XCTestCase {

    private func daily(_ day: String, recovery: Double? = 50) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                    avgHrv: nil, recovery: recovery, strain: nil, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil, steps: nil)
    }

    // MARK: Heat strip

    func testPastYearStripIsTheLast365CalendarDays() {
        // Three rows: one from more than a year ago. suffix(365) counted rows, so it kept all three.
        let days = [daily("2025-06-01"), daily("2026-07-14"), daily("2026-10-21")]
        let strip = TrendsView.yearStripRows(days, range: .quarter, today: "2026-10-21")
        XCTAssertEqual(strip.rows.map(\.day), ["2026-07-14", "2026-10-21"])
        XCTAssertFalse(strip.allHistory)
    }

    func testAllRangeReachesBackAndSaysSo() {
        let days = [daily("2025-06-01"), daily("2026-07-14"), daily("2026-10-21")]
        let strip = TrendsView.yearStripRows(days, range: .all, today: "2026-10-21")
        XCTAssertEqual(strip.rows.count, 3)
        XCTAssertTrue(strip.allHistory, "Data older than a year is shown, so the title must say all history")
    }

    func testAllRangeWithinAYearIsStillThePastYear() {
        let days = [daily("2026-07-14"), daily("2026-10-21")]
        XCTAssertFalse(TrendsView.yearStripRows(days, range: .all, today: "2026-10-21").allHistory)
    }
}
