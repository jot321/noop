import XCTest
import WhoopProtocol
@testable import Strand

/// Pins the owner-derived realtime demand split: the lightweight toggle is wanted more often than the
/// WHOOP4-only R10/R11 burst, and passive continuous capture never implies the heavy burst.
final class RealtimeDemandPolicyTests: XCTestCase {

    private func demand(family: DeviceFamily = .whoop4,
                        owners: Set<RealtimeDemandOwner> = [],
                        foreground: Bool = true,
                        passiveCaptureWanted: Bool = false,
                        marginalFallback: Bool = false,
                        trigger: RealtimeDemandReconcileTrigger = .inputChange)
        -> RealtimeDemandOutput {
        RealtimeDemandPolicy.evaluate(
            deviceFamily: family,
            owners: owners,
            appForeground: foreground,
            passiveCaptureWanted: passiveCaptureWanted,
            marginalRadioFallback: marginalFallback,
            trigger: trigger)
    }

    func testNoOwnerAndNoPassiveCaptureWantsNothing() {
        XCTAssertEqual(demand(), RealtimeDemandOutput(toggleWanted: false, heavyWhoop4Wanted: false))
        XCTAssertEqual(demand(family: .whoop5), RealtimeDemandOutput(toggleWanted: false, heavyWhoop4Wanted: false))
    }

    func testEveryExplicitOwnerIndependentlyWantsToggleAndWhoop4HeavyInForeground() {
        for owner in RealtimeDemandOwner.allCases {
            XCTAssertEqual(
                demand(owners: [owner]),
                RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: true),
                "\(owner) should independently request full WHOOP4 realtime in foreground"
            )
        }
    }

    func testWhoop5OwnersNeverRequestWhoop4Heavy() {
        for owner in RealtimeDemandOwner.allCases {
            XCTAssertEqual(
                demand(family: .whoop5, owners: [owner]),
                RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: false),
                "\(owner) should keep WHOOP5/MG on the puffin toggle only"
            )
        }
    }

    func testBackgroundSuppressesOnlyLiveScreenOwner() {
        XCTAssertEqual(
            demand(owners: [.liveScreen], foreground: false),
            RealtimeDemandOutput(toggleWanted: false, heavyWhoop4Wanted: false)
        )
        XCTAssertEqual(
            demand(owners: [.workout], foreground: false),
            RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: true)
        )
        XCTAssertEqual(
            demand(owners: [.liveSession], foreground: false),
            RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: true)
        )
        XCTAssertEqual(
            demand(owners: [.manualControl], foreground: false),
            RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: true)
        )
    }

    func testOwnerCombinationsRemainActiveWhenAnyUnsuppressedOwnerWantsRealtime() {
        XCTAssertEqual(
            demand(owners: [.liveScreen, .workout], foreground: false),
            RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: true)
        )
        XCTAssertEqual(
            demand(owners: [.liveScreen, .liveSession, .manualControl], foreground: false),
            RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: true)
        )
    }

    func testPassiveCaptureInsideWindowRequestsToggleOnly() {
        XCTAssertEqual(
            demand(passiveCaptureWanted: true),
            RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: false)
        )
        XCTAssertEqual(
            demand(family: .whoop5, passiveCaptureWanted: true),
            RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: false)
        )
    }

    func testPassiveCaptureOutsideWindowRequestsNothing() {
        XCTAssertEqual(
            demand(passiveCaptureWanted: false),
            RealtimeDemandOutput(toggleWanted: false, heavyWhoop4Wanted: false)
        )
    }

    func testPassiveCaptureCombinesWithExplicitOwnerWithoutAddingHeavyDemandItself() {
        XCTAssertEqual(
            demand(owners: [.liveScreen], foreground: false, passiveCaptureWanted: true),
            RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: false)
        )
        XCTAssertEqual(
            demand(owners: [.workout], foreground: false, passiveCaptureWanted: true),
            RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: true)
        )
    }

    func testMarginalRadioFallbackSuppressesHeavyButNotToggle() {
        XCTAssertEqual(
            demand(owners: [.workout], foreground: false, marginalFallback: true),
            RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: false)
        )
        XCTAssertEqual(
            demand(passiveCaptureWanted: true, marginalFallback: true),
            RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: false)
        )
    }

    func testPostBondAndDisconnectResetTriggersRetainOwnerDemandIntent() {
        for trigger in [RealtimeDemandReconcileTrigger.postBond, .disconnectReset] {
            XCTAssertEqual(
                demand(owners: [.liveSession], foreground: false, trigger: trigger),
                RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: true)
            )
            XCTAssertEqual(
                demand(passiveCaptureWanted: true, trigger: trigger),
                RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: false)
            )
        }
    }
}
