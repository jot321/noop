import Foundation
import WhoopStore

/// On-demand restore of pruned days from the user's bucket — the read/restore path of
/// docs/CLOUD_SYNC_PLAN.md §6. The inverse of `CloudUploader`: for each pruned (day, stream) ledger
/// row overlapping a viewed window, download the object, hash-verify it against the ledger, and
/// re-import the raw rows. Import clears the ledger's `prunedAt`, so a hydrated day is a TEMPORARY
/// cache — the next offload pass re-prunes it once it ages past retention (see
/// `WhoopStore.importCloudDayPayload`).
///
/// Fetching is the caller's explicit choice (a "Restore" tap), never a silent side effect of
/// scrolling — the app's offline-first posture means network reads stay user-initiated.
actor CloudHydrator {
    static let shared = CloudHydrator()

    struct Report: Sendable, Equatable {
        var restoredStreams = 0
        var rowsRestored = 0
        var failures = 0
    }

    /// (deviceId|day|stream) downloads currently running, so a double-tap or a second screen can't
    /// fetch the same object twice. A key already in flight is skipped, not awaited — the UI reloads
    /// off the first hydration's completion anyway.
    private var inFlight: Set<String> = []

    /// Every UTC day string a `[from, to)` unix-seconds window touches, oldest first. A visible
    /// window spans at most a handful of days, so the list stays tiny.
    nonisolated static func utcDays(from: Int, to: Int) -> [String] {
        guard to > from else { return [] }
        var days: [String] = []
        var day = CloudStreams.day(forTs: from)
        let last = CloudStreams.day(forTs: to - 1)
        while true {
            days.append(day)
            if day == last || days.count > 64 { break }   // 64: sanity cap, never a real window
            guard let next = CloudStreams.nextDay(day) else { break }
            day = next
        }
        return days
    }

    /// Restore every pruned (day, stream) of `deviceIds` overlapping `[from, to)`. Each object is
    /// re-downloaded and REFUSED unless its sha256 matches the ledger row recorded at upload — a
    /// remote object that drifted (or a wrong-key response) never reaches the raw tables.
    func hydrate(from: Int, to: Int, deviceIds: [String], store: WhoopStore, client: S3Client) async -> Report {
        var report = Report()
        let days = Self.utcDays(from: from, to: to)
        for deviceId in deviceIds {
            let pruned = (try? await store.cloudPrunedObjects(deviceId: deviceId, days: days)) ?? []
            for obj in pruned {
                let key = "\(obj.deviceId)|\(obj.day)|\(obj.stream)"
                guard !inFlight.contains(key) else { continue }
                inFlight.insert(key)
                defer { inFlight.remove(key) }
                do {
                    let data = try await client.getObject(key: obj.objectKey)
                    guard S3Client.sha256Hex(data) == obj.sha256 else {
                        report.failures += 1
                        continue
                    }
                    let rows = try await store.importCloudDayPayload(
                        data, deviceId: obj.deviceId, stream: obj.stream, day: obj.day)
                    report.restoredStreams += 1
                    report.rowsRestored += rows
                } catch {
                    report.failures += 1
                }
            }
        }
        return report
    }
}
