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

    // MARK: - Hydration (import a downloaded payload back into the raw tables)

    /// The full offload → prune → hydrate loop: export a day, prune it, import the payload back, and
    /// the raw rows are restored with the ledger's prunedAt cleared — so the day is re-prunable.
    func testHydrationRoundTripRestoresPrunedDay() async throws {
        let store = try await makeStore()
        let day = "2021-03-04"
        try await seedHR(store, deviceId: "dev1", day: day, count: 180)
        let payload = try await store.exportCloudDayPayload(deviceId: "dev1", stream: "hrSample", day: day)!
        try await store.recordCloudObjectUploaded(deviceId: "dev1", day: day, stream: "hrSample",
                                                  objectKey: "k", sha256: "h", byteSize: payload.data.count,
                                                  rowCount: payload.rowCount, at: 1)
        try await store.markCloudObjectVerified(deviceId: "dev1", day: day, stream: "hrSample", at: 2)
        _ = try await store.downsampleAndPruneCloudDay(deviceId: "dev1", stream: "hrSample", day: day, at: 5)
        var rows = try await store.cloudDayRowCount(deviceId: "dev1", stream: "hrSample", day: day)
        XCTAssertEqual(rows, 0)

        // Hydrate: every raw row comes back, byte-identical on a re-export.
        let inserted = try await store.importCloudDayPayload(payload.data, deviceId: "dev1", stream: "hrSample", day: day)
        XCTAssertEqual(inserted, 180)
        rows = try await store.cloudDayRowCount(deviceId: "dev1", stream: "hrSample", day: day)
        XCTAssertEqual(rows, 180)
        let reExport = try await store.exportCloudDayPayload(deviceId: "dev1", stream: "hrSample", day: day)
        XCTAssertEqual(reExport?.data, payload.data)

        // prunedAt cleared -> the day is a prune candidate again (hydration is a temporary cache).
        let rec = try await store.cloudObject(deviceId: "dev1", day: day, stream: "hrSample")
        XCTAssertNil(rec?.prunedAt)
        XCTAssertEqual(rec?.state, "verified")
        let again = try await store.downsampleAndPruneCloudDay(deviceId: "dev1", stream: "hrSample", day: day, at: 9)
        XCTAssertEqual(again, .pruned(rowsDeleted: 180))
    }

    /// A second import of the same payload inserts nothing (INSERT OR IGNORE on the raw PK).
    func testHydrationIsIdempotent() async throws {
        let store = try await makeStore()
        let day = "2021-03-04"
        try await seedHR(store, deviceId: "dev1", day: day, count: 50)
        let payload = try await store.exportCloudDayPayload(deviceId: "dev1", stream: "hrSample", day: day)!
        let first = try await store.importCloudDayPayload(payload.data, deviceId: "dev1", stream: "hrSample", day: day)
        XCTAssertEqual(first, 0) // rows never left
        let second = try await store.importCloudDayPayload(payload.data, deviceId: "dev1", stream: "hrSample", day: day)
        XCTAssertEqual(second, 0)
        let rows = try await store.cloudDayRowCount(deviceId: "dev1", stream: "hrSample", day: day)
        XCTAssertEqual(rows, 50)
    }

    /// NULLs survive the round trip: a stepSample with no activityClass exports as an empty field and
    /// hydrates back to NULL, not 0.
    func testHydrationPreservesNulls() async throws {
        let store = try await makeStore()
        let day = "2021-03-04"
        let start = CloudStreams.dayStartTs(day)!
        var streams = Streams()
        streams.steps = [StepSample(ts: start, counter: 100, activityClass: nil),
                         StepSample(ts: start + 60, counter: 120, activityClass: 3)]
        _ = try await store.insert(streams, deviceId: "dev1")
        let payload = try await store.exportCloudDayPayload(deviceId: "dev1", stream: "stepSample", day: day)!
        // Wipe and hydrate.
        try await store.recordCloudObjectUploaded(deviceId: "dev1", day: day, stream: "stepSample",
                                                  objectKey: "k", sha256: "h", byteSize: 1, rowCount: 2, at: 1)
        try await store.markCloudObjectVerified(deviceId: "dev1", day: day, stream: "stepSample", at: 2)
        _ = try await store.downsampleAndPruneCloudDay(deviceId: "dev1", stream: "stepSample", day: day, at: 5)
        _ = try await store.importCloudDayPayload(payload.data, deviceId: "dev1", stream: "stepSample", day: day)
        let back = try await store.stepSamples(deviceId: "dev1", from: start, to: start + 86_400, limit: 10)
        XCTAssertEqual(back.map(\.activityClass), [nil, 3])
        XCTAssertEqual(back.map(\.counter), [100, 120])
    }

    /// Wrong (stream, day, device) routing or a tampered header is refused outright.
    func testHydrationRejectsHeaderMismatch() async throws {
        let store = try await makeStore()
        let day = "2021-03-04"
        try await seedHR(store, deviceId: "dev1", day: day, count: 5)
        let payload = try await store.exportCloudDayPayload(deviceId: "dev1", stream: "hrSample", day: day)!
        // Same payload presented as a different day / stream / device — all refused, nothing inserted.
        for (dev, stream, wrongDay) in [("dev1", "hrSample", "2021-03-05"),
                                        ("dev1", "respSample", day),
                                        ("dev2", "hrSample", day)] {
            do {
                _ = try await store.importCloudDayPayload(payload.data, deviceId: dev, stream: stream, day: wrongDay)
                XCTFail("import should refuse a header mismatch")
            } catch let e as CloudImportError {
                XCTAssertEqual(e, .headerMismatch)
            }
        }
        let dev2Rows = try await store.cloudDayRowCount(deviceId: "dev2", stream: "hrSample", day: day)
        XCTAssertEqual(dev2Rows, 0)
    }

    /// A row whose timestamp escapes the day (or with the wrong field count) fails the whole import.
    func testHydrationRejectsMalformedRows() async throws {
        let store = try await makeStore()
        let day = "2021-03-04"
        let start = CloudStreams.dayStartTs(day)!
        let csv = "noop-cloud,v=1,stream=hrSample,device=dev1,day=\(day),cols=ts,bpm\n\(start),60\n\(start + 86_400),61\n"
        let data = try WhoopStore.compressCloudPayload(Data(csv.utf8))
        do {
            _ = try await store.importCloudDayPayload(data, deviceId: "dev1", stream: "hrSample", day: day)
            XCTFail("import should refuse an out-of-day row")
        } catch let e as CloudImportError {
            XCTAssertEqual(e, .malformedRow(line: 3))
        }
        // Atomic: the valid first row was NOT inserted.
        let rows = try await store.cloudDayRowCount(deviceId: "dev1", stream: "hrSample", day: day)
        XCTAssertEqual(rows, 0)
    }

    /// The per-day pruned-object lookup returns only pruned rows for the asked days.
    func testCloudPrunedObjectsFiltersByDayAndState() async throws {
        let store = try await makeStore()
        for (day, pruned) in [("2021-03-01", true), ("2021-03-02", false), ("2021-03-03", true)] {
            try await seedHR(store, deviceId: "dev1", day: day, count: 60)
            try await store.recordCloudObjectUploaded(deviceId: "dev1", day: day, stream: "hrSample",
                                                      objectKey: "k-\(day)", sha256: "h", byteSize: 1, rowCount: 60, at: 1)
            try await store.markCloudObjectVerified(deviceId: "dev1", day: day, stream: "hrSample", at: 2)
            if pruned {
                _ = try await store.downsampleAndPruneCloudDay(deviceId: "dev1", stream: "hrSample", day: day, at: 5)
            }
        }
        let hits = try await store.cloudPrunedObjects(deviceId: "dev1", days: ["2021-03-01", "2021-03-02", "2021-03-04"])
        XCTAssertEqual(hits.map(\.day), ["2021-03-01"])
        XCTAssertEqual(hits.first?.objectKey, "k-2021-03-01")
        let none = try await store.cloudPrunedObjects(deviceId: "dev1", days: [])
        XCTAssertTrue(none.isEmpty)
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
