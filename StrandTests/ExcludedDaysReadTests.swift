import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Excluded ("not me") days stay out of what the dashboard reads and out of the bedtime learner, while
/// their rows stay in the store so "Bring back" restores them. (Audit I9, 2026-10-21.) Synthetic numbers.
@MainActor
final class ExcludedDaysReadTests: XCTestCase {

    /// `refresh()` reads the excluded list from the host app's defaults. Snapshot the whole domain and put
    /// it back so a test run never leaves anything behind.
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

    private func daily(_ day: String, hrv: Double, rhr: Int) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 450, efficiency: 0.9, deepMin: 90, remMin: 100, lightMin: 260,
                    disturbances: 3, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: 40, exerciseCount: 0,
                    respRateBpm: 15)
    }

    /// An imported row and a hand-edited session on an excluded day stay in the store but must not reach
    /// `repo.days` / `repo.sleeps`, which feed the Stress and illness baselines, Health, Today and Insights.
    func testRefreshLeavesExcludedDaysOutOfDaysAndSleeps() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")
        let repo = Repository(deviceId: "my-whoop")
        repo.setStoreForTesting(store)
        let tz = TimeZone.current.secondsFromGMT()
        let todayMidnight = IntelligenceEngine.midnightLocal(Int(Date().timeIntervalSince1970), offsetSec: tz)
        let midA = todayMidnight - 10 * 86_400, midB = todayMidnight - 9 * 86_400
        let dayA = AnalyticsEngine.dayString(midA, offsetSec: tz)
        let dayB = AnalyticsEngine.dayString(midB, offsetSec: tz)
        try await store.upsertDailyMetrics([daily(dayA, hrv: 120, rhr: 48), daily(dayB, hrv: 60, rhr: 55)],
                                           deviceId: "my-whoop")
        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: midA + 13 * 3_600, endTs: midA + 16 * 3_600, efficiency: 0.9,
                               restingHr: 48, avgHrv: 120, stagesJSON: "[]", userEdited: true),
            CachedSleepSession(startTs: midB - 3_600, endTs: midB + 7 * 3_600, efficiency: 0.9,
                               restingHr: 55, avgHrv: 60, stagesJSON: "[]"),
        ], deviceId: "my-whoop-noop")
        ExcludedDays.save([dayA])

        await repo.refresh()

        XCTAssertEqual(repo.days.map(\.day), [dayB])
        XCTAssertEqual(repo.sleeps.map { AnalyticsEngine.dayString($0.endTs, offsetSec: tz) }, [dayB])
        let kept = try await store.dailyMetrics(deviceId: "my-whoop", from: dayA, to: dayA)
        XCTAssertEqual(kept.count, 1, "the imported row stays in the store, so Bring back restores it")
    }

    /// A hand-edited afternoon "sleep" on an excluded day is not a learner block.
    func testBedtimeLearnerSkipsSessionsWakingOnExcludedDays() {
        let ist = 5 * 3_600 + 30 * 60
        let mid = Baselines.dayIndex("2026-03-14")! * 86_400 - ist
        let sessions = [
            CachedSleepSession(startTs: mid + 13 * 3_600, endTs: mid + 16 * 3_600, efficiency: 0.9,
                               restingHr: nil, avgHrv: nil, stagesJSON: "[]", userEdited: true),
            CachedSleepSession(startTs: mid + 86_400 - 3_600, endTs: mid + 86_400 + 7 * 3_600, efficiency: 0.9,
                               restingHr: nil, avgHrv: nil, stagesJSON: "[]"),
        ]
        let blocks = IntelligenceEngine.habitualHistoryBlocks(sessions, excluded: ["2026-03-14"], offsetSec: ist)
        XCTAssertEqual(blocks.map(\.start), [mid + 86_400 - 3_600])
        XCTAssertEqual(IntelligenceEngine.habitualHistoryBlocks(sessions, excluded: [], offsetSec: ist).count, 2)
    }
}
