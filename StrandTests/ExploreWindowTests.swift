import XCTest
@testable import Strand

/// Explore's "Δ vs prev" and "vs your normal" count calendar days, not readings (2026-10-21).
final class ExploreWindowTests: XCTestCase {

    private func rows(_ month: Int, _ days: ClosedRange<Int>, value: Double = 50) -> [(day: String, value: Double)] {
        days.map { (day: String(format: "2026-%02d-%02d", month, $0), value: value) }
    }

    func testPreviousWeekIsTheSevenDaysBeforeNotTheSevenReadingsBefore() {
        // A week of readings in May, then the active week 24–30 Jun. The week before (17–23 Jun) is
        // empty; stepping back seven readings compared June with May.
        let series = rows(5, 1...7, value: 40) + rows(6, 24...30, value: 60)
        let prev = MetricDetailView.previousWindow(series: series, days: 7)
        XCTAssertTrue(prev.isEmpty, "Got \(prev.map(\.day))")
    }

    func testPreviousWeekByDate() {
        let series = rows(6, 10...30)
        let prev = MetricDetailView.previousWindow(series: series, days: 7)
        XCTAssertEqual(prev.map(\.day), (17...23).map { String(format: "2026-06-%02d", $0) })
    }

    func testAllHistoryHasNoPreviousWindow() {
        XCTAssertTrue(MetricDetailView.previousWindow(series: rows(6, 1...30), days: nil).isEmpty)
    }

    func testRecentMeanNeedsReadingsInTheLastSevenDays() {
        // Seven August readings are not "recent" on 21 Oct.
        XCTAssertNil(MetricDetailView.recentMean(rows(8, 1...7), today: "2026-10-21"))
    }

    func testRecentMeanUsesTheLastSevenCalendarDays() {
        let series = rows(10, 10...14, value: 10) + rows(10, 15...21, value: 70)
        XCTAssertEqual(MetricDetailView.recentMean(series, today: "2026-10-21") ?? 0, 70, accuracy: 1e-9)
    }

    func testRecentMeanNeedsThreeReadings() {
        XCTAssertNil(MetricDetailView.recentMean(rows(10, 20...21), today: "2026-10-21"))
    }
}
