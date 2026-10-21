import XCTest
import WhoopProtocol
@testable import WhoopStore

/// Exact HR extremes for the Deep Timeline footer (2026-10-21). At day scale the chart is 5-minute
/// means, and the footer's Min / Max came from those means, so a short spike vanished.
final class HRWindowStatsTests: XCTestCase {

    func testExtremesAreTheRealSamplesNotTheBucketMeans() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        let base = 1_780_000_200   // bucket-aligned for 300 s
        // Ten minutes at 60 bpm with a 30-second burst at 150 and a dip to 45.
        var hr: [HRSample] = []
        for t in 0..<600 {
            let bpm = (100..<130).contains(t) ? 150 : (t == 400 ? 45 : 60)
            hr.append(HRSample(ts: base + t, bpm: bpm))
        }
        try await store.insert(Streams(hr: hr), deviceId: dev)

        let buckets = try await store.hrBuckets(deviceId: dev, from: base, to: base + 599, bucketSeconds: 300)
        let bucketMax = buckets.map(\.bpm).max() ?? 0
        XCTAssertLessThan(bucketMax, 70, "The 5-minute mean flattens the burst (the bug)")

        let stats = try await store.hrWindowStats(deviceId: dev, from: base, to: base + 599)
        XCTAssertEqual(stats?.max, 150)
        XCTAssertEqual(stats?.min, 45)
        XCTAssertEqual(stats?.count, 600)
        // 569 seconds at 60, one at 45, thirty at 150.
        let expectedSum: Double = 569 * 60 + 45 + 30 * 150
        XCTAssertEqual(stats?.mean ?? 0, expectedSum / 600, accuracy: 1e-9)
    }

    func testPpgFillsSecondsWithoutMeasuredHr() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        let base = 1_780_000_000
        try await store.insert(Streams(hr: [HRSample(ts: base, bpm: 90)]), deviceId: dev)
        try await store.insert(Streams(ppgHr: [
            PpgHrSample(ts: base, bpm: 200, conf: 0.9),     // shadowed by the measured 90
            PpgHrSample(ts: base + 1, bpm: 70, conf: 0.9),  // fills the gap
        ]), deviceId: dev)
        let stats = try await store.hrWindowStats(deviceId: dev, from: base, to: base + 10)
        XCTAssertEqual(stats?.max, 90)
        XCTAssertEqual(stats?.min, 70)
        XCTAssertEqual(stats?.count, 2)
    }

    func testEmptyWindowIsNil() async throws {
        let store = try await WhoopStore.inMemory()
        let stats = try await store.hrWindowStats(deviceId: "my-whoop", from: 0, to: 10)
        XCTAssertNil(stats)
    }

    func testCombinedWeightsTheMean() {
        let a = HRWindowStats(min: 50, max: 100, mean: 60, count: 3)
        let b = HRWindowStats(min: 40, max: 90, mean: 80, count: 1)
        let c = HRWindowStats.combined([a, b])
        XCTAssertEqual(c, HRWindowStats(min: 40, max: 100, mean: 65, count: 4))
        XCTAssertNil(HRWindowStats.combined([]))
    }
}
