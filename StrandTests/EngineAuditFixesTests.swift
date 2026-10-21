import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// `analyzeRecent` fixes from the 2026-10-21 audit, run against a real `IntelligenceEngine` on an
/// in-memory store: the computing lock (I3), the re-arm width and the excluded-day purge (I2), and the
/// detected-workout reconcile bounds (I1). All numbers are synthetic.
@MainActor
final class EngineAuditFixesTests: XCTestCase {

    /// `analyzeRecent` writes its watermark and the step-calibration fields to the host app's defaults.
    /// Snapshot the whole domain and put it back so a test run never leaves anything behind.
    private var savedDomain: [String: Any]?
    private let domain = Bundle.main.bundleIdentifier ?? "com.noopapp.noop"

    override func setUp() {
        super.setUp()
        savedDomain = UserDefaults.standard.persistentDomain(forName: domain)
    }

    override func tearDown() {
        if let savedDomain { UserDefaults.standard.setPersistentDomain(savedDomain, forName: domain) }
        else { UserDefaults.standard.removePersistentDomain(forName: domain) }
        super.tearDown()
    }

    private func makeEngine() async throws -> (IntelligenceEngine, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        return (IntelligenceEngine(repo: repo, profile: ProfileStore(), deviceId: "my-whoop"), store)
    }

    /// Wait for any re-armed pass (launched on its own Task) to finish.
    private func settle(_ engine: IntelligenceEngine, passes: Int) async {
        for _ in 0..<400 {
            if engine.passWidths.count >= passes && !engine.computing { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func detected(_ start: Int) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 1_800, sport: "detected", source: "my-whoop-noop",
                   durationS: 1_800, energyKcal: 200, avgHr: 130, maxHr: 160, strain: 40,
                   distanceM: nil, zonesJSON: nil, notes: nil)
    }

    // MARK: - I3: the computing lock

    /// Two calls landing together must not both run the body. The lock used to be taken only after two
    /// awaits, so both passed the guard and interleaved their deletes and upserts.
    func testTwoConcurrentPassesNeverOverlap() async throws {
        let (engine, _) = try await makeEngine()
        async let a: Void = engine.analyzeRecent(maxDays: 3)
        async let b: Void = engine.analyzeRecent(maxDays: 3)
        _ = await (a, b)
        await settle(engine, passes: 2)
        XCTAssertEqual(engine.peakConcurrentPasses, 1, "a second call ran its body while the first was mid-pass")
        XCTAssertFalse(engine.computing)
    }

    /// An early return (the idle-tick watermark short-circuit) must release the lock.
    func testEarlyReturnReleasesTheLock() async throws {
        let (engine, _) = try await makeEngine()
        await engine.analyzeRecent(maxDays: 2)              // records the watermark
        await engine.analyzeRecent(maxDays: 2, force: false) // same fingerprint: returns early
        XCTAssertFalse(engine.computing)
        await engine.analyzeRecent(maxDays: 2)
        XCTAssertEqual(engine.passWidths, [2, 2], "the forced pass after the early return still runs")
    }

    // MARK: - I2: re-arm width

    /// A forced rescore dropped while a narrow pass holds the lock re-runs at ITS width, so "Bring back"
    /// on a day 400 days ago is not rescored at the in-flight pass's 3 days and missed.
    func testDroppedForcedRescoreRerunsAtTheWiderRequestedWidth() async throws {
        let (engine, _) = try await makeEngine()
        // Start the narrow pass first and wait until it holds the lock, so the wide request is the one
        // dropped (two `async let`s start in either order).
        let narrow = Task { await engine.analyzeRecent(maxDays: 3) }
        while !engine.computing { await Task.yield() }
        await engine.analyzeRecent(maxDays: 400)            // dropped and re-armed
        await narrow.value
        await settle(engine, passes: 2)
        XCTAssertEqual(engine.passWidths.first, 3)
        XCTAssertEqual(engine.passWidths.last, 400)
        XCTAssertEqual(engine.passWidths.count, 2)
    }

    // MARK: - I1: detected-workout reconcile bounds

    /// The pass re-detects workouts only on the calendar days it scans (oldest day … today), so it must
    /// only delete detected workouts inside that span. A bout the day before the oldest scanned day used
    /// to be deleted and never recreated, so detected workouts vanished at about the window's age.
    func testPassNeverDeletesADetectedWorkoutItDoesNotRescan() async throws {
        let (engine, store) = try await makeEngine()
        let tz = TimeZone.current.secondsFromGMT()
        let now = Int(Date().timeIntervalSince1970)
        let maxDays = 3
        let todayMidnight = IntelligenceEngine.midnightLocal(now, offsetSec: tz)
        let oldestMidnight = todayMidnight - (maxDays - 1) * 86_400
        let outside = oldestMidnight - 2 * 3_600            // 22:00 the evening before the oldest day
        let inside = oldestMidnight + 3_600                 // 01:00 on the oldest day, no strap data
        try await store.upsertWorkouts([detected(outside), detected(inside)], deviceId: "my-whoop-noop")

        await engine.analyzeRecent(maxDays: maxDays)

        let left = try await store.workouts(deviceId: "my-whoop-noop", from: 0, to: now, limit: 100)
        XCTAssertEqual(left.map(\.startTs), [outside],
                       "the bout before the scan is kept; the stale one inside it is reconciled away")
        let span = IntelligenceEngine.detectedWorkoutReconcileStart(nowLocalMidnight: todayMidnight,
                                                                    maxDays: maxDays)
        XCTAssertEqual(span, oldestMidnight)
    }

    // MARK: - I2: purge removes detected workouts on excluded days

    func testPurgeRemovesDetectedWorkoutsOnExcludedDaysOnly() async throws {
        let store = try await WhoopStore.inMemory()
        let ist = 5 * 3_600 + 30 * 60
        let excludedMidnight = IntelligenceEngine.epochDayIndex("2026-03-14")! * 86_400 - ist
        let onDay = excludedMidnight + 10 * 3_600
        let dayAfter = excludedMidnight + 86_400 + 600
        var manual = detected(onDay + 4 * 3_600)
        manual = WorkoutRow(startTs: manual.startTs, endTs: manual.endTs, sport: "running", source: "manual",
                            durationS: 1_800, energyKcal: 250, avgHr: 140, maxHr: 170, strain: 50,
                            distanceM: nil, zonesJSON: nil, notes: nil)
        try await store.upsertWorkouts([detected(onDay), detected(dayAfter), manual], deviceId: "my-whoop-noop")

        await IntelligenceEngine.purgeExcludedDays(["2026-03-14"], store: store, computedId: "my-whoop-noop",
                                                   offsetSec: ist)

        let left = try await store.workouts(deviceId: "my-whoop-noop", from: 0, to: 2_000_000_000, limit: 100)
        XCTAssertEqual(Set(left.map(\.startTs)), [dayAfter, manual.startTs],
                       "only the detected bout on the excluded day goes")
    }
}
