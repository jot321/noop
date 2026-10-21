import XCTest
@testable import StrandDesign

/// The trend line breaks over gaps in the data instead of bridging them (2026-10-21).
final class TrendChartGapTests: XCTestCase {

    private func points(_ offsets: [Double], step: TimeInterval) -> [TrendPoint] {
        offsets.map { TrendPoint(date: Date(timeIntervalSince1970: $0 * step), value: 50) }
    }

    func testDailySeriesBreaksOverAMonthsLongHole() {
        // 12 July days, then 20–21 Oct: one break, placed inside the hole.
        let days: [Double] = (0..<12).map(Double.init) + [97.0, 98.0]
        let breaks = TrendChart.gapBreaks(points(days, step: 86_400))
        XCTAssertEqual(breaks.count, 1)
        XCTAssertEqual(breaks[0].timeIntervalSince1970, (11.0 + 97.0) / 2 * 86_400, accuracy: 1)
    }

    func testOneMissingDayDoesNotBreakTheLine() {
        let days: [Double] = [0, 1, 2, 4, 5, 6, 7]   // one missing day: spacing 2 < 3× median
        XCTAssertTrue(TrendChart.gapBreaks(points(days, step: 86_400)).isEmpty)
    }

    func testFiveMinuteSeriesBreaksOverAnHourOff() {
        let buckets: [Double] = (0..<30).map(Double.init) + (46..<60).map(Double.init)
        XCTAssertEqual(TrendChart.gapBreaks(points(buckets, step: 300)).count, 1)
    }

    func testTooFewPointsNeverBreak() {
        XCTAssertTrue(TrendChart.gapBreaks(points([0, 50], step: 86_400)).isEmpty)
    }
}
