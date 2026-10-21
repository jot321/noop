import XCTest
@testable import StrandAnalytics

/// The report's trend and half split count calendar days, not readings (2026-10-21). With the
/// strap off for weeks, a per-reading slope squeezed a month into one step and a positional split
/// mixed old and new readings in the "recent" half.
final class RangeReportCalendarDayTests: XCTestCase {

    func testSlopeIsPerCalendarDayNotPerReading() {
        // Two readings at each end of a 30-day range: +10 over 29 days is ~0.34/day, under the
        // 0.5/day recovery threshold. Per reading it looked like +3.6 a step, so "trending up".
        let series: [String: Double] = [
            "2026-06-01": 40, "2026-06-02": 41,
            "2026-06-29": 49, "2026-06-30": 50,
        ]
        let s = RangeReportEngine.build(metrics: [.recovery: series],
                                        start: "2026-06-01", end: "2026-06-30").stat(.recovery)!
        XCTAssertEqual(s.trend, .flat)
    }

    func testHalvesSplitAtTheMidpointDate() {
        // Six early days at 50, then one late reading at 80. By position the late half also held
        // three of the early days; by date the later half is the late reading alone.
        var series: [String: Double] = [:]
        for d in 1...6 { series[String(format: "2026-06-%02d", d)] = 50 }
        series["2026-06-30"] = 80
        let s = RangeReportEngine.build(metrics: [.recovery: series],
                                        start: "2026-06-01", end: "2026-06-30").stat(.recovery)!
        XCTAssertEqual(s.firstHalfMean, 50, accuracy: 1e-9)
        XCTAssertEqual(s.secondHalfMean, 80, accuracy: 1e-9)
    }

    // MARK: - DayWindow

    func testDayNumberIsContinuousAcrossMonthsAndYears() {
        XCTAssertEqual(DayWindow.dayNumber("2026-03-01")! - DayWindow.dayNumber("2026-02-28")!, 1)
        XCTAssertEqual(DayWindow.dayNumber("2027-01-01")! - DayWindow.dayNumber("2026-12-31")!, 1)
        XCTAssertNil(DayWindow.dayNumber("2026-02-30"))
    }

    func testWindowStartAndPreviousWindow() {
        XCTAssertEqual(DayWindow.windowStart(endingOn: "2026-10-21", days: 7), "2026-10-15")
        let prev = DayWindow.previousWindow(start: "2026-10-15", end: "2026-10-21")
        XCTAssertEqual(prev?.start, "2026-10-08")
        XCTAssertEqual(prev?.end, "2026-10-14")
    }

    func testHalfMeansNeedBothHalves() {
        XCTAssertNil(DayWindow.halfMeans(days: ["2026-06-01"], values: [50]))
        let h = DayWindow.halfMeans(days: ["2026-06-01", "2026-06-02", "2026-06-03", "2026-06-04"],
                                    values: [40, 50, 60, 70])
        XCTAssertEqual(h?.earlier ?? 0, 45, accuracy: 1e-9)
        XCTAssertEqual(h?.later ?? 0, 65, accuracy: 1e-9)
    }

    func testSlopePerDayUsesDayGaps() {
        XCTAssertEqual(DayWindow.slopePerDay(days: ["2026-06-01", "2026-06-11"], values: [0, 10]),
                       1, accuracy: 1e-9)
        XCTAssertEqual(DayWindow.slopePerDay(days: ["2026-06-01"], values: [5]), 0)
    }
}
