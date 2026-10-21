#if !os(watchOS)
import XCTest
import SwiftUI
@testable import StrandDesign

/// The Deep Timeline / Today HR line breaks over a stretch with no heart rate instead of drawing
/// one straight line (and its area) across it (2026-10-21).
final class OverviewHRChartGapTests: XCTestCase {

    /// 5-minute buckets from 00:00 to 09:00, nothing for 11 hours, then 20:00 to 23:55.
    private func dayWithGap() -> [TrendPoint] {
        let morning = stride(from: 0.0, to: 9 * 3600, by: 300)
        let evening = stride(from: 20.0 * 3600, to: 24 * 3600, by: 300)
        return (Array(morning) + Array(evening)).map { TrendPoint(date: Date(timeIntervalSince1970: 100_000 + $0), value: 60) }
    }

    func testElevenHourGapSplitsTheLine() {
        let chart = OverviewHRChart(points: dayWithGap())
        let runs = Set(chart.drawn.map(\.run))
        XCTAssertEqual(runs.count, 2, "Morning and evening are separate runs")
        let lastMorning = chart.drawn.last { $0.point.date.timeIntervalSince1970 < 100_000 + 9 * 3600 }
        let firstEvening = chart.drawn.first { $0.point.date.timeIntervalSince1970 >= 100_000 + 20 * 3600 }
        XCTAssertNotEqual(lastMorning?.run, firstEvening?.run)
    }

    func testDeepTimelineFullResolutionAlsoSplits() {
        // The Deep Timeline passes zoom bounds and keeps every point.
        let pts = dayWithGap()
        let bounds = pts.first!.date...pts.last!.date
        let chart = OverviewHRChart(points: pts, zoomDomain: .constant(nil), zoomBounds: bounds)
        XCTAssertEqual(Set(chart.drawn.map(\.run)).count, 2)
        XCTAssertEqual(chart.drawn.count, pts.count)
    }

    func testContinuousDayIsOneRun() {
        let pts = stride(from: 0.0, to: 24 * 3600, by: 300).map {
            TrendPoint(date: Date(timeIntervalSince1970: 100_000 + $0), value: 60)
        }
        XCTAssertEqual(Set(OverviewHRChart(points: pts).drawn.map(\.run)).count, 1)
    }
}
#endif
