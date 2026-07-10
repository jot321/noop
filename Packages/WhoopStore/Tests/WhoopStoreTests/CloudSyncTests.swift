import XCTest
@testable import WhoopStore
import WhoopProtocol

final class CloudSyncTests: XCTestCase {

    private func makeStore() async throws -> WhoopStore { try await WhoopStore.inMemory() }

    /// Insert `count` hr samples for a device on a given UTC day (seconds from day start).
    private func seedHR(_ store: WhoopStore, deviceId: String, day: String, count: Int) async throws {
        let start = CloudStreams.dayStartTs(day)!
        var streams = Streams()
        streams.hr = (0..<count).map { HRSample(ts: start + $0, bpm: 60 + ($0 % 10)) }
        _ = try await store.insert(streams, deviceId: deviceId)
    }

    func testMigrationCreatesCloudTables() async throws {
        let store = try await makeStore()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("cloudObject"))
        XCTAssertTrue(tables.contains("minuteAgg"))
    }

    func testDayMath() {
        // 2021-01-01 00:00:00 UTC == 1609459200.
        XCTAssertEqual(CloudStreams.dayStartTs("2021-01-01"), 1609459200)
        XCTAssertEqual(CloudStreams.day(forTs: 1609459200), "2021-01-01")
        XCTAssertEqual(CloudStreams.day(forTs: 1609459200 + 86399), "2021-01-01")
        XCTAssertEqual(CloudStreams.day(forTs: 1609459200 + 86400), "2021-01-02")
        XCTAssertEqual(CloudStreams.nextDay("2021-01-01"), "2021-01-02")
    }

    func testExportPayloadRoundTrips() async throws {
        let store = try await makeStore()
        let day = "2021-03-04"
        try await seedHR(store, deviceId: "dev1", day: day, count: 100)
        let payload = try await store.exportCloudDayPayload(deviceId: "dev1", stream: "hrSample", day: day)
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload!.rowCount, 100)
        // Decompress and check the header + row count.
        let csv = try WhoopStore.decompressCloudPayload(payload!.data)
        let text = String(data: csv, encoding: .utf8)!
        let lines = text.split(separator: "\n")
        XCTAssertTrue(lines[0].hasPrefix("noop-cloud,v=1,stream=hrSample"))
        XCTAssertEqual(lines.count, 101) // header + 100 rows
    }

    func testExportEmptyDayIsNil() async throws {
        let store = try await makeStore()
        let payload = try await store.exportCloudDayPayload(deviceId: "dev1", stream: "hrSample", day: "2021-03-04")
        XCTAssertNil(payload)
    }

    func testLedgerUploadVerifyFlow() async throws {
        let store = try await makeStore()
        let day = "2021-03-04"
        try await store.recordCloudObjectUploaded(deviceId: "dev1", day: day, stream: "hrSample",
                                                  objectKey: "dev1/2021-03-04/hrSample.z", sha256: "abc",
                                                  byteSize: 500, rowCount: 100, at: 1000)
        var rec = try await store.cloudObject(deviceId: "dev1", day: day, stream: "hrSample")
        XCTAssertEqual(rec?.state, "uploaded")
        XCTAssertNil(rec?.verifiedAt)

        try await store.markCloudObjectVerified(deviceId: "dev1", day: day, stream: "hrSample", at: 2000)
        rec = try await store.cloudObject(deviceId: "dev1", day: day, stream: "hrSample")
        XCTAssertEqual(rec?.state, "verified")
        XCTAssertEqual(rec?.verifiedAt, 2000)

        let summary = try await store.cloudLedgerSummary(deviceId: "dev1")
        XCTAssertEqual(summary.uploadedObjects, 1)
        XCTAssertEqual(summary.verifiedObjects, 1)
        XCTAssertEqual(summary.uploadedBytes, 500)
    }

    func testPruneRefusesUnverified() async throws {
        let store = try await makeStore()
        let day = "2021-03-04"
        try await seedHR(store, deviceId: "dev1", day: day, count: 120)
        try await store.recordCloudObjectUploaded(deviceId: "dev1", day: day, stream: "hrSample",
                                                  objectKey: "k", sha256: "h", byteSize: 1, rowCount: 120, at: 1)
        // Not verified -> refuse.
        let outcome = try await store.downsampleAndPruneCloudDay(deviceId: "dev1", stream: "hrSample", day: day, at: 5)
        XCTAssertEqual(outcome, .notVerified)
        // Raw rows still present.
        let n = try await store.cloudDayRowCount(deviceId: "dev1", stream: "hrSample", day: day)
        XCTAssertEqual(n, 120)
        _ = n
    }

    func testPruneRefusesCountMismatch() async throws {
        let store = try await makeStore()
        let day = "2021-03-04"
        try await seedHR(store, deviceId: "dev1", day: day, count: 120)
        // Ledger claims a stale, smaller rowCount (late backfill landed after upload).
        try await store.recordCloudObjectUploaded(deviceId: "dev1", day: day, stream: "hrSample",
                                                  objectKey: "k", sha256: "h", byteSize: 1, rowCount: 100, at: 1)
        try await store.markCloudObjectVerified(deviceId: "dev1", day: day, stream: "hrSample", at: 2)
        let outcome = try await store.downsampleAndPruneCloudDay(deviceId: "dev1", stream: "hrSample", day: day, at: 5)
        XCTAssertEqual(outcome, .countMismatch(localRows: 120, uploadedRows: 100))
        // Nothing deleted.
        let remaining = try await store.cloudDayRowCount(deviceId: "dev1", stream: "hrSample", day: day)
        XCTAssertEqual(remaining, 120)
    }

    func testVerifiedPruneDownsamplesAndDeletes() async throws {
        let store = try await makeStore()
        let day = "2021-03-04"
        try await seedHR(store, deviceId: "dev1", day: day, count: 180) // 3 minutes of 1 Hz
        try await store.recordCloudObjectUploaded(deviceId: "dev1", day: day, stream: "hrSample",
                                                  objectKey: "k", sha256: "h", byteSize: 1, rowCount: 180, at: 1)
        try await store.markCloudObjectVerified(deviceId: "dev1", day: day, stream: "hrSample", at: 2)
        let outcome = try await store.downsampleAndPruneCloudDay(deviceId: "dev1", stream: "hrSample", day: day, at: 5)
        XCTAssertEqual(outcome, .pruned(rowsDeleted: 180))
        // Raw gone.
        let rawLeft = try await store.cloudDayRowCount(deviceId: "dev1", stream: "hrSample", day: day)
        XCTAssertEqual(rawLeft, 0)
        // minuteAgg has 3 one-minute rows.
        let start = CloudStreams.dayStartTs(day)!
        let agg = try await store.minuteAggSeries(deviceId: "dev1", stream: "hrSample", from: start, to: start + 86400)
        XCTAssertEqual(agg.count, 3)
        XCTAssertEqual(agg.map(\.count).reduce(0, +), 180)
        // Second prune is a no-op.
        let again = try await store.downsampleAndPruneCloudDay(deviceId: "dev1", stream: "hrSample", day: day, at: 6)
        XCTAssertEqual(again, .alreadyPruned)
    }

    func testPruneCandidatesRespectRetentionBoundary() async throws {
        let store = try await makeStore()
        for day in ["2021-03-01", "2021-03-02", "2021-03-10"] {
            try await store.recordCloudObjectUploaded(deviceId: "dev1", day: day, stream: "hrSample",
                                                      objectKey: "k", sha256: "h", byteSize: 1, rowCount: 1, at: 1)
            try await store.markCloudObjectVerified(deviceId: "dev1", day: day, stream: "hrSample", at: 2)
        }
        // Retain everything on/after 2021-03-05.
        let cands = try await store.cloudPruneCandidates(deviceId: "dev1", beforeDay: "2021-03-05")
        XCTAssertEqual(cands.map(\.day).sorted(), ["2021-03-01", "2021-03-02"])
    }

    func testFillDailySpo2OnlyWhenNil() async throws {
        let store = try await makeStore()
        let day = "2021-03-04"
        // Seed a daily row with nil spo2Pct.
        let dm = DailyMetric(day: day, totalSleepMin: 400, efficiency: 0.9, deepMin: 60, remMin: 90,
                             lightMin: 250, disturbances: 3, restingHr: 55, avgHrv: 60, recovery: 70,
                             strain: 10, exerciseCount: 0, spo2Pct: nil)
        _ = try await store.upsertDailyMetrics([dm], deviceId: "dev-noop")
        // Fill it.
        let changed = try await store.fillDailySpo2IfNil(deviceId: "dev-noop", day: day, spo2Pct: 96.5)
        XCTAssertEqual(changed, 1)
        var rows = try await store.dailyMetrics(deviceId: "dev-noop", from: day, to: day)
        XCTAssertEqual(rows.first?.spo2Pct, 96.5)
        // Second fill is a no-op (already non-nil).
        let changed2 = try await store.fillDailySpo2IfNil(deviceId: "dev-noop", day: day, spo2Pct: 90.0)
        XCTAssertEqual(changed2, 0)
        rows = try await store.dailyMetrics(deviceId: "dev-noop", from: day, to: day)
        XCTAssertEqual(rows.first?.spo2Pct, 96.5)
    }
}
