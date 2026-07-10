import XCTest
@testable import Strand

@MainActor
final class LiveScreenSnapshotTests: XCTestCase {
    func testEquivalentSnapshotsCompareEqual() {
        XCTAssertEqual(makeSnapshot(), makeSnapshot())
    }

    func testRootVisibleChangesCompareUnequal() {
        let baseline = makeSnapshot()

        XCTAssertNotEqual(baseline, makeSnapshot(connected: true))
        XCTAssertNotEqual(baseline, makeSnapshot(bonded: true))
        XCTAssertNotEqual(baseline, makeSnapshot(encryptedBond: true))
        XCTAssertNotEqual(baseline, makeSnapshot(reconnectGuide: "Forget the strap"))
        XCTAssertNotEqual(baseline, makeSnapshot(pairingHint: "Free the strap"))
        XCTAssertNotEqual(baseline, makeSnapshot(standardHRMode: "Standard HR mode"))
        XCTAssertNotEqual(baseline, makeSnapshot(hasActiveWorkout: true))
        XCTAssertNotEqual(baseline, makeSnapshot(lastWorkoutSummary: .init(durationS: 600, avgHr: 140, strain: 32)))
        XCTAssertNotEqual(baseline, makeSnapshot(activeDeviceName: "WHOOP 5"))
        XCTAssertNotEqual(baseline, makeSnapshot(hrMax: 190))
        XCTAssertNotEqual(baseline, makeSnapshot(backfilling: true))
    }

    func testSnapshotExcludesHighFrequencyValues() {
        let labels = Set(Mirror(reflecting: makeSnapshot()).children.compactMap(\.label))

        XCTAssertTrue(labels.isDisjoint(with: ["heartRate", "rr", "rrRecent", "lastFrameType", "lastEvent", "log", "visibleLog", "bpm"]))
    }

    private func makeSnapshot(
        connected: Bool = false,
        bonded: Bool = false,
        encryptedBond: Bool = false,
        reconnectGuide: String? = nil,
        pairingHint: String? = nil,
        standardHRMode: String? = nil,
        hasActiveWorkout: Bool = false,
        lastWorkoutSummary: LiveScreenSnapshot.LastWorkoutSummary? = .init(durationS: 300, avgHr: 120, strain: 20),
        activeDeviceName: String = "WHOOP",
        hrMax: Int = 180,
        backfilling: Bool = false
    ) -> LiveScreenSnapshot {
        LiveScreenSnapshot(
            connected: connected,
            bonded: bonded,
            encryptedBond: encryptedBond,
            reconnectGuide: reconnectGuide,
            pairingHint: pairingHint,
            standardHRMode: standardHRMode,
            hasActiveWorkout: hasActiveWorkout,
            lastWorkoutSummary: lastWorkoutSummary,
            activeDeviceName: activeDeviceName,
            hrMax: hrMax,
            backfilling: backfilling
        )
    }
}
