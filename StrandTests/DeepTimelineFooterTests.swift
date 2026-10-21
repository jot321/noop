import XCTest
import StrandDesign
import WhoopStore
@testable import Strand

/// The Deep Timeline footer's Min / Max at day scale are the real samples, not the 5-minute means
/// the line is drawn from (2026-10-21).
final class DeepTimelineFooterTests: XCTestCase {

    private let buckets = [62.0, 71.5, 66.0].enumerated().map {
        TrendPoint(date: Date(timeIntervalSince1970: 1_780_000_000 + Double($0.offset) * 300), value: $0.element)
    }

    func testExactExtremesWinOverBucketMeans() {
        let exact = HRWindowStats(min: 48, max: 152, mean: 66.2, count: 900)
        let s = FullDayChartView.footerStats(points: buckets, exact: exact)
        XCTAssertEqual(s.max, 152)
        XCTAssertEqual(s.min, 48)
        XCTAssertEqual(s.avg, 66.2, accuracy: 1e-9)
    }

    func testWithoutExactStatsTheFooterReadsThePlottedPoints() {
        let s = FullDayChartView.footerStats(points: buckets, exact: nil)
        XCTAssertEqual(s.max, 71.5)
        XCTAssertEqual(s.min, 62)
    }
}
