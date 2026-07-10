import Foundation
import GRDB

// Cloud offload + prune (docs/CLOUD_SYNC_PLAN.md, schema v23). This file is the STORE side only:
// sealing a UTC day's decoded rows into a compact payload, the per-(deviceId, day, stream) upload
// ledger, and the verified downsample-then-delete prune. All networking (S3, SigV4) stays in the
// app layer — the shared packages carry no networking code (docs/PRIVACY_SECURITY.md §1.1).

/// One offloadable 1 Hz decoded stream: the SQL table, its value columns (after `ts`), and the
/// scalar channels kept locally at 1-minute grain after prune. Multi-channel streams split into
/// `"gravitySample.x"`-style `minuteAgg` keys so the aggregate table stays single-valued.
public struct CloudStreamSpec: Sendable {
    public let table: String
    public let valueColumns: [String]
    /// (minuteAgg stream-key suffix, SQL expression) pairs; empty suffix means the bare table name.
    public let channels: [(suffix: String, expression: String)]
}

public enum CloudStreams {
    /// Every unbounded decoded stream the offloader seals, in a stable order. `event`/`battery`
    /// are low-rate and stay local forever, like the derived tables.
    public static let all: [CloudStreamSpec] = [
        CloudStreamSpec(table: "hrSample", valueColumns: ["bpm"], channels: [("", "bpm")]),
        CloudStreamSpec(table: "rrInterval", valueColumns: ["rrMs"], channels: [("", "rrMs")]),
        CloudStreamSpec(table: "ppgHrSample", valueColumns: ["bpm", "conf"], channels: [("", "bpm")]),
        CloudStreamSpec(table: "spo2Sample", valueColumns: ["red", "ir"], channels: [(".red", "red"), (".ir", "ir")]),
        CloudStreamSpec(table: "skinTempSample", valueColumns: ["raw"], channels: [("", "raw")]),
        CloudStreamSpec(table: "respSample", valueColumns: ["raw"], channels: [("", "raw")]),
        CloudStreamSpec(table: "gravitySample", valueColumns: ["x", "y", "z"], channels: [(".x", "x"), (".y", "y"), (".z", "z")]),
        CloudStreamSpec(table: "stepSample", valueColumns: ["counter", "activityClass"], channels: [("", "counter")]),
        CloudStreamSpec(table: "sleepStateSample", valueColumns: ["state"], channels: [("", "state")]),
    ]

    public static func spec(for table: String) -> CloudStreamSpec? {
        all.first { $0.table == table }
    }

    /// UTC day math shared by store + engine. Days are sealed on UTC boundaries so the object
    /// layout is timezone-stable no matter where the user travels.
    public static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    public static func day(forTs ts: Int) -> String {
        dayFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// Start-of-day unix seconds for a `YYYY-MM-DD` UTC day, or nil for a malformed string.
    public static func dayStartTs(_ day: String) -> Int? {
        dayFormatter.date(from: day).map { Int($0.timeIntervalSince1970) }
    }

    public static func nextDay(_ day: String) -> String? {
        dayStartTs(day).map { CloudStreams.day(forTs: $0 + 86_400) }
    }
}

/// A sealed day's export: header + CSV rows, zlib-compressed with the outbox's length-prefixed
/// framing so the app can round-trip it with the same helpers.
public struct CloudDayPayload: Sendable {
    public let deviceId: String
    public let stream: String
    public let day: String
    public let rowCount: Int
    /// zlib-with-length-prefix compressed CSV (see `WhoopStore.zlibCompressWithLength`).
    public let data: Data
    public let uncompressedBytes: Int
}

/// One row of the upload ledger.
public struct CloudObjectRecord: Sendable {
    public let deviceId: String
    public let day: String
    public let stream: String
    public let objectKey: String
    public let sha256: String
    public let byteSize: Int
    public let rowCount: Int
    public let state: String // "uploaded" | "verified"
    public let uploadedAt: Int
    public let verifiedAt: Int?
    public let prunedAt: Int?
}

public enum CloudPruneOutcome: Sendable, Equatable {
    /// Raw rows were downsampled into `minuteAgg` and deleted.
    case pruned(rowsDeleted: Int)
    /// The ledger row isn't `verified` (or doesn't exist) — never prune.
    case notVerified
    /// Rows were added to this day AFTER upload (late strap backfill); the object is stale, so the
    /// engine must re-export + re-upload before this day can be pruned.
    case countMismatch(localRows: Int, uploadedRows: Int)
    /// Already pruned earlier — nothing to do.
    case alreadyPruned
}

public struct CloudLedgerSummary: Sendable {
    public let uploadedObjects: Int
    public let verifiedObjects: Int
    public let prunedObjects: Int
    public let uploadedBytes: Int
}

extension WhoopStore {

    // MARK: - Payload compression (public wrappers over the outbox helpers)

    public static func compressCloudPayload(_ data: Data) throws -> Data {
        try zlibCompressWithLength(data)
    }

    public static func decompressCloudPayload(_ data: Data) throws -> Data {
        try zlibDecompressWithLength(data)
    }

    // MARK: - Day discovery

    /// UTC day of the oldest decoded sample across all offloadable streams — where backfill starts.
    public func cloudOldestSampleDay(deviceId: String) async throws -> String? {
        let minTs: Int? = try syncRead { db in
            var best: Int?
            for spec in CloudStreams.all {
                let t = try Int.fetchOne(db,
                    sql: "SELECT MIN(ts) FROM \(spec.table) WHERE deviceId = ?",
                    arguments: [deviceId])
                if let t { best = min(best ?? t, t) }
            }
            return best
        }
        return minTs.map(CloudStreams.day(forTs:))
    }

    /// Row count for one (stream, UTC day) — used to skip empty days and to detect late backfill.
    public func cloudDayRowCount(deviceId: String, stream: String, day: String) async throws -> Int {
        guard CloudStreams.spec(for: stream) != nil, let start = CloudStreams.dayStartTs(day) else { return 0 }
        return try syncRead { db in
            try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM \(stream) WHERE deviceId = ? AND ts >= ? AND ts < ?",
                arguments: [deviceId, start, start + 86_400]) ?? 0
        }
    }

    // MARK: - Export

    /// Seal one (stream, UTC day) into a compressed CSV payload. Returns nil when the day has no
    /// rows for that stream (an empty day needs no object). Format, line 1 header then rows:
    ///
    ///     noop-cloud,v=1,stream=<table>,device=<id>,day=<YYYY-MM-DD>,cols=ts,<col>...
    ///     <ts>,<v1>[,<v2>...]
    ///
    /// NULLs (e.g. stepSample.activityClass) serialize as an empty field so absent stays absent.
    public func exportCloudDayPayload(deviceId: String, stream: String, day: String) async throws -> CloudDayPayload? {
        guard let spec = CloudStreams.spec(for: stream), let start = CloudStreams.dayStartTs(day) else { return nil }
        let (csv, rows): (Data, Int) = try syncRead { db in
            var out = "noop-cloud,v=1,stream=\(spec.table),device=\(deviceId),day=\(day),cols=ts,\(spec.valueColumns.joined(separator: ","))\n"
            var rowCount = 0
            let cols = (["ts"] + spec.valueColumns).joined(separator: ", ")
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT \(cols) FROM \(spec.table)
                WHERE deviceId = ? AND ts >= ? AND ts < ?
                ORDER BY ts\(spec.table == "rrInterval" ? ", rrMs" : "")
                """, arguments: [deviceId, start, start + 86_400])
            while let row = try cursor.next() {
                var fields: [String] = []
                fields.reserveCapacity(1 + spec.valueColumns.count)
                for i in 0 ..< (1 + spec.valueColumns.count) {
                    switch row[i]?.databaseValue.storage {
                    case .int64(let v): fields.append(String(v))
                    case .double(let v): fields.append(String(v))
                    case .string(let v): fields.append(v)
                    default: fields.append("")
                    }
                }
                out += fields.joined(separator: ",")
                out += "\n"
                rowCount += 1
            }
            return (Data(out.utf8), rowCount)
        }
        guard rows > 0 else { return nil }
        let compressed = try WhoopStore.zlibCompressWithLength(csv)
        return CloudDayPayload(deviceId: deviceId, stream: stream, day: day,
                               rowCount: rows, data: compressed, uncompressedBytes: csv.count)
    }

    // MARK: - Upload ledger

    /// Record a successful PUT. Upsert: a re-upload of a stale day (late backfill) overwrites the
    /// old ledger row and resets it to `uploaded` awaiting a fresh verify.
    public func recordCloudObjectUploaded(deviceId: String, day: String, stream: String,
                                          objectKey: String, sha256: String,
                                          byteSize: Int, rowCount: Int, at now: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO cloudObject
                    (deviceId, day, stream, objectKey, sha256, byteSize, rowCount, state, uploadedAt, verifiedAt, prunedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, 'uploaded', ?, NULL, NULL)
                ON CONFLICT(deviceId, day, stream) DO UPDATE SET
                    objectKey = excluded.objectKey, sha256 = excluded.sha256,
                    byteSize = excluded.byteSize, rowCount = excluded.rowCount,
                    state = 'uploaded', uploadedAt = excluded.uploadedAt,
                    verifiedAt = NULL, prunedAt = NULL
                """, arguments: [deviceId, day, stream, objectKey, sha256, byteSize, rowCount, now])
        }
    }

    /// Promote to `verified` after the engine re-downloaded the object and hash-matched it.
    public func markCloudObjectVerified(deviceId: String, day: String, stream: String, at now: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE cloudObject SET state = 'verified', verifiedAt = ?
                WHERE deviceId = ? AND day = ? AND stream = ?
                """, arguments: [now, deviceId, day, stream])
        }
    }

    public func cloudObject(deviceId: String, day: String, stream: String) async throws -> CloudObjectRecord? {
        try syncRead { db in
            try Row.fetchOne(db, sql: """
                SELECT * FROM cloudObject WHERE deviceId = ? AND day = ? AND stream = ?
                """, arguments: [deviceId, day, stream]).map(Self.cloudObjectRecord(from:))
        }
    }

    public func cloudObjects(deviceId: String) async throws -> [CloudObjectRecord] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM cloudObject WHERE deviceId = ? ORDER BY day, stream
                """, arguments: [deviceId]).map(Self.cloudObjectRecord(from:))
        }
    }

    public func cloudLedgerSummary(deviceId: String) async throws -> CloudLedgerSummary {
        try syncRead { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS total,
                       SUM(CASE WHEN state = 'verified' THEN 1 ELSE 0 END) AS verified,
                       SUM(CASE WHEN prunedAt IS NOT NULL THEN 1 ELSE 0 END) AS pruned,
                       COALESCE(SUM(byteSize), 0) AS bytes
                FROM cloudObject WHERE deviceId = ?
                """, arguments: [deviceId])
            return CloudLedgerSummary(uploadedObjects: row?["total"] ?? 0,
                                      verifiedObjects: row?["verified"] ?? 0,
                                      prunedObjects: row?["pruned"] ?? 0,
                                      uploadedBytes: row?["bytes"] ?? 0)
        }
    }

    private static func cloudObjectRecord(from row: Row) -> CloudObjectRecord {
        CloudObjectRecord(deviceId: row["deviceId"], day: row["day"], stream: row["stream"],
                          objectKey: row["objectKey"], sha256: row["sha256"],
                          byteSize: row["byteSize"], rowCount: row["rowCount"],
                          state: row["state"], uploadedAt: row["uploadedAt"],
                          verifiedAt: row["verifiedAt"], prunedAt: row["prunedAt"])
    }

    // MARK: - Verified prune (downsample 1 Hz → 1 min, then delete raw)

    /// Days eligible for prune: `verified`, not yet pruned, strictly older than `beforeDay`.
    public func cloudPruneCandidates(deviceId: String, beforeDay: String) async throws -> [(day: String, stream: String)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT day, stream FROM cloudObject
                WHERE deviceId = ? AND state = 'verified' AND prunedAt IS NULL AND day < ?
                ORDER BY day, stream
                """, arguments: [deviceId, beforeDay]).map { ($0["day"], $0["stream"]) }
        }
    }

    /// Downsample one verified (stream, day) into `minuteAgg` (per-minute min/mean/max/count per
    /// scalar channel) and delete the 1 Hz raw rows — all in ONE transaction, and only when the
    /// ledger row is `verified` and its `rowCount` still matches the live table (a mismatch means
    /// late backfill landed after upload; the object is stale and must be re-uploaded first).
    public func downsampleAndPruneCloudDay(deviceId: String, stream: String, day: String, at now: Int) async throws -> CloudPruneOutcome {
        guard let spec = CloudStreams.spec(for: stream), let start = CloudStreams.dayStartTs(day) else {
            return .notVerified
        }
        let end = start + 86_400
        return try syncWrite { db in
            let ledger = try Row.fetchOne(db, sql: """
                SELECT state, rowCount, prunedAt FROM cloudObject
                WHERE deviceId = ? AND day = ? AND stream = ?
                """, arguments: [deviceId, day, stream])
            guard let ledger, (ledger["state"] as String) == "verified" else { return .notVerified }
            if (ledger["prunedAt"] as Int?) != nil { return .alreadyPruned }
            let localRows = try Int.fetchOne(db,
                sql: "SELECT COUNT(*) FROM \(spec.table) WHERE deviceId = ? AND ts >= ? AND ts < ?",
                arguments: [deviceId, start, end]) ?? 0
            let uploadedRows: Int = ledger["rowCount"]
            guard localRows == uploadedRows else {
                return .countMismatch(localRows: localRows, uploadedRows: uploadedRows)
            }
            for channel in spec.channels {
                try db.execute(sql: """
                    INSERT INTO minuteAgg (deviceId, stream, ts, minV, meanV, maxV, count)
                    SELECT deviceId, ?, (ts / 60) * 60,
                           MIN(\(channel.expression)), AVG(\(channel.expression)), MAX(\(channel.expression)), COUNT(*)
                    FROM \(spec.table)
                    WHERE deviceId = ? AND ts >= ? AND ts < ? AND \(channel.expression) IS NOT NULL
                    GROUP BY (ts / 60) * 60
                    ON CONFLICT(deviceId, stream, ts) DO UPDATE SET
                        minV = excluded.minV, meanV = excluded.meanV,
                        maxV = excluded.maxV, count = excluded.count
                    """, arguments: [spec.table + channel.suffix, deviceId, start, end])
            }
            try db.execute(sql: "DELETE FROM \(spec.table) WHERE deviceId = ? AND ts >= ? AND ts < ?",
                           arguments: [deviceId, start, end])
            let deleted = db.changesCount
            try db.execute(sql: """
                UPDATE cloudObject SET prunedAt = ? WHERE deviceId = ? AND day = ? AND stream = ?
                """, arguments: [now, deviceId, day, stream])
            return .pruned(rowsDeleted: deleted)
        }
    }

    /// 1-minute aggregate series for a pruned channel (e.g. `"hrSample"`, `"gravitySample.x"`) —
    /// the local echo charts fall back to for days whose 1 Hz raw was reclaimed.
    public func minuteAggSeries(deviceId: String, stream: String, from: Int, to: Int) async throws
        -> [(ts: Int, minV: Double, meanV: Double, maxV: Double, count: Int)] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT ts, minV, meanV, maxV, count FROM minuteAgg
                WHERE deviceId = ? AND stream = ? AND ts >= ? AND ts < ?
                ORDER BY ts
                """, arguments: [deviceId, stream, from, to])
                .map { ($0["ts"], $0["minV"], $0["meanV"], $0["maxV"], $0["count"]) }
        }
    }
}
