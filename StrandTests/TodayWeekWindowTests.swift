import XCTest
import WhoopStore
@testable import Strand

/// The Today tiles' 7-day window is 7 calendar days, not the last 7 rows: with the strap off for
/// months, the last 7 rows reached back to August naps and "vs 7 days" read -69 ms.
final class TodayWeekWindowTests: XCTestCase {

    private func daily(_ day: String, hrv: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil,
                    remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil,
                    avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil,
                    spo2Pct: nil, skinTempDevC: nil, respRateBpm: nil, steps: nil)
    }

    func testOldRowsBeyondAGapAreLeftOut() {
        let days = [daily("2026-07-28", hrv: nil), daily("2026-08-02", hrv: 117.6),
                    daily("2026-08-03", hrv: 113.6), daily("2026-10-20", hrv: nil),
                    daily("2026-10-21", hrv: 46.7)]
        let week = LiquidTodayView.calendarWeek(days, endingOn: "2026-10-21")
        XCTAssertEqual(week.map(\.day), ["2026-10-20", "2026-10-21"])
    }

    func testWindowIsSevenDaysInclusiveAndSorted() {
        let days = ["2026-10-21", "2026-10-14", "2026-10-15", "2026-10-18", "2026-10-22"]
            .map { daily($0, hrv: 50) }
        let week = LiquidTodayView.calendarWeek(days, endingOn: "2026-10-21")
        XCTAssertEqual(week.map(\.day), ["2026-10-15", "2026-10-18", "2026-10-21"],
                       "15 Oct is day 1 of 7; 14 Oct and the future 22 Oct are outside")
    }
}
