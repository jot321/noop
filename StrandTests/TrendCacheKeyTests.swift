import XCTest
@testable import Strand

/// Caches must not outlive the data they were built from (2026-10-21). Compare keyed its
/// correlation and overlay caches on row count and first/last day, so a re-scored day in the
/// middle of the window kept the old result; Explore keyed its "What correlates" cache on the
/// metric and range only, so a refresh never rebuilt it.
final class TrendCacheKeyTests: XCTestCase {

    func testCompareKeyChangesWhenAMiddleValueChanges() {
        let before: [(day: String, value: Double)] = [("2026-10-19", 50), ("2026-10-20", 60), ("2026-10-21", 70)]
        var after = before
        after[1].value = 65
        XCTAssertNotEqual(CompareView.seriesKey(id: "my-whoop:hrv", rows: before),
                          CompareView.seriesKey(id: "my-whoop:hrv", rows: after))
    }

    func testCompareKeyIsStableForTheSameRows() {
        let rows: [(day: String, value: Double)] = [("2026-10-20", 60), ("2026-10-21", 70)]
        XCTAssertEqual(CompareView.seriesKey(id: "a", rows: rows), CompareView.seriesKey(id: "a", rows: rows))
    }

    func testExploreCorrelationKeyChangesWithFreshData() {
        XCTAssertNotEqual(
            MetricDetailView.correlationCacheKey(metricID: "my-whoop:hrv", range: .month, dataGeneration: 1),
            MetricDetailView.correlationCacheKey(metricID: "my-whoop:hrv", range: .month, dataGeneration: 2))
    }
}
