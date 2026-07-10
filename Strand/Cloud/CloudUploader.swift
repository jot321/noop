import Foundation
import WhoopStore

/// Orchestrates the tiered offload + verified prune (docs/CLOUD_SYNC_PLAN.md §4–5) against a
/// user-supplied S3 bucket. All persistence goes through `WhoopStore`'s cloud API (export / ledger /
/// downsample-prune, in Packages/WhoopStore/CloudSync.swift); all networking goes through `S3Client`.
///
/// Flow, per run:
///   1. SEAL: every UTC day strictly older than a small lag (so the current/just-past day still
///      collects) that has rows for a stream and no verified object yet.
///   2. UPLOAD: export → zlib payload → PUT (idempotent, content-hash keyed) → record `uploaded`.
///   3. VERIFY: re-download the object, sha256 it, and mark `verified` only on a hash match.
///   4. PRUNE: for verified days older than the retention window, downsample 1 Hz → 1-min and delete
///      the raw rows — never touching an unverified or count-mismatched day.
public actor CloudUploader {
    private let store: WhoopStore
    private let client: S3Client
    private let deviceId: String
    /// UTC "now" seconds, injected so the flow is testable and clock-deterministic.
    private let now: () -> Int
    /// Don't seal a day younger than this many days (let the current + previous day keep collecting).
    private let sealLagDays: Int
    /// Prune only days older than this many days (the on-device retention window).
    private let retentionDays: Int

    public struct RunReport: Sendable, Equatable {
        public var uploaded: Int = 0
        public var verified: Int = 0
        public var prunedDays: Int = 0
        public var rowsFreed: Int = 0
        public var failures: Int = 0
    }

    public init(store: WhoopStore, client: S3Client, deviceId: String,
                retentionDays: Int, sealLagDays: Int = 2, now: @escaping () -> Int = { Int(Date().timeIntervalSince1970) }) {
        self.store = store
        self.client = client
        self.deviceId = deviceId
        self.retentionDays = retentionDays
        self.sealLagDays = sealLagDays
        self.now = now
    }

    /// One full offload + prune pass. Safe to call repeatedly (idempotent). Returns a report.
    @discardableResult
    public func runOnce() async -> RunReport {
        var report = RunReport()
        let today = CloudStreams.day(forTs: now())
        // The newest day we're willing to seal (strictly older than the lag).
        let sealCeilingDay = CloudStreams.day(forTs: now() - sealLagDays * 86_400)
        // The newest day we're willing to prune (older than retention).
        let pruneCeilingDay = CloudStreams.day(forTs: now() - retentionDays * 86_400)

        guard let oldest = (try? await store.cloudOldestSampleDay(deviceId: deviceId)) ?? nil else {
            return report
        }

        // ── Seal + upload + verify each day/stream from oldest up to the seal ceiling ──
        // Cancellation-cooperative: a background-task expiration cancels the wrapping Task, and the
        // pass stops at the next day boundary (every completed upload/verify/prune is already durable).
        var day = oldest
        while day <= sealCeilingDay && day <= today {
            if Task.isCancelled { return report }
            for spec in CloudStreams.all {
                await uploadAndVerify(day: day, stream: spec.table, report: &report)
            }
            guard let next = CloudStreams.nextDay(day) else { break }
            day = next
        }

        // ── Prune verified days older than retention ──
        if let candidates = try? await store.cloudPruneCandidates(deviceId: deviceId, beforeDay: pruneCeilingDay) {
            for c in candidates {
                if Task.isCancelled { return report }
                let outcome = (try? await store.downsampleAndPruneCloudDay(
                    deviceId: deviceId, stream: c.stream, day: c.day, at: now())) ?? .notVerified
                switch outcome {
                case .pruned(let rows):
                    report.prunedDays += 1
                    report.rowsFreed += rows
                case .countMismatch:
                    // Late backfill after upload — re-seal this day/stream so a fresh object is uploaded.
                    await uploadAndVerify(day: c.day, stream: c.stream, report: &report, force: true)
                case .notVerified, .alreadyPruned:
                    break
                }
            }
        }
        return report
    }

    /// Export, upload, and verify one (day, stream). Skips when already verified unless `force`.
    private func uploadAndVerify(day: String, stream: String, report: inout RunReport, force: Bool = false) async {
        do {
            let existing = try await store.cloudObject(deviceId: deviceId, day: day, stream: stream)
            // Already durably verified and current — nothing to do. (A count check catches late backfill.)
            if !force, let existing, existing.state == "verified" {
                let liveRows = try await store.cloudDayRowCount(deviceId: deviceId, stream: stream, day: day)
                if liveRows == existing.rowCount { return }
            }
            guard let payload = try await store.exportCloudDayPayload(deviceId: deviceId, stream: stream, day: day) else {
                return // empty day/stream
            }
            let key = client.objectKey(deviceId: deviceId, day: day, stream: stream)
            let sha = try await client.putObject(key: key, data: payload.data)
            try await store.recordCloudObjectUploaded(deviceId: deviceId, day: day, stream: stream,
                                                      objectKey: key, sha256: sha,
                                                      byteSize: payload.data.count, rowCount: payload.rowCount,
                                                      at: now())
            report.uploaded += 1
            // Verify: re-download and hash-match before the day becomes prunable.
            let downloaded = try await client.getObject(key: key)
            guard S3Client.sha256Hex(downloaded) == sha else {
                report.failures += 1
                return
            }
            try await store.markCloudObjectVerified(deviceId: deviceId, day: day, stream: stream, at: now())
            report.verified += 1
        } catch {
            report.failures += 1
        }
    }

    /// Purge every uploaded object for this device from the bucket (opt-out "delete remote"). Leaves
    /// the local ledger rows so a subsequent re-enable can re-upload; callers that also want the ledger
    /// cleared can follow with a store reset.
    public func purgeRemote() async -> Int {
        var deleted = 0
        guard let objects = try? await store.cloudObjects(deviceId: deviceId) else { return 0 }
        for obj in objects {
            if (try? await client.deleteObject(key: obj.objectKey)) != nil { deleted += 1 }
        }
        return deleted
    }
}
