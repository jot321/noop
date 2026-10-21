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

    // MARK: Small-multiple change chip

    func testChangeChipSplitsAtTheMidpointDate() {
        // Twelve July readings at 50, then two in October at 80, all inside a 6-month window.
        // By count the "recent" half held five July readings too (+8.6); by date it is October (+30).
        let july = (17...28).map { String(format: "2026-07-%02d", $0) }
        let days = july + ["2026-10-20", "2026-10-21"]
        let values = Array(repeating: 50.0, count: july.count) + [80, 80]
        let change = TrendsView.periodChange(days: days, values: values)
        XCTAssertEqual(change ?? 0, 30, accuracy: 1e-9)
    }

    func testChangeChipNeedsTwoReadingsEachSide() {
        // One October reading can't stand for a "recent half".
        let days = (17...28).map { String(format: "2026-07-%02d", $0) } + ["2026-10-21"]
        let values = Array(repeating: 50.0, count: 12) + [80]
        XCTAssertNil(TrendsView.periodChange(days: days, values: values))
    }

    func testChangeChipNeedsFourReadings() {
        XCTAssertNil(TrendsView.periodChange(days: ["2026-10-19", "2026-10-20", "2026-10-21"],
                                             values: [40, 50, 60]))
    }
}
