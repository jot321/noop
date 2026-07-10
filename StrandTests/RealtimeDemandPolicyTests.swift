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
                        marginalFallback: Bool = false)
        -> RealtimeDemandOutput {
        RealtimeDemandPolicy.evaluate(
            deviceFamily: family,
            owners: owners,
            appForeground: foreground,
            passiveCaptureWanted: passiveCaptureWanted,
            marginalRadioFallback: marginalFallback)
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

    func testDroppedToggleSendDoesNotAdvanceSentState() {
        var sentState = RealtimeCommandSentState()

        sentState.recordToggle(wanted: true, queued: false)

        XCTAssertFalse(sentState.toggleArmed)
        XCTAssertTrue(sentState.shouldSendToggle(wanted: true))
    }

    func testDroppedHeavySendDoesNotAdvanceSentStateOrArmTimestamp() {
        var sentState = RealtimeCommandSentState()

        sentState.recordHeavy(wanted: true, queued: false,
                              at: Date(timeIntervalSince1970: 123))

        XCTAssertFalse(sentState.heavyWhoop4Armed)
        XCTAssertNil(sentState.heavyWhoop4ArmedAt)
        XCTAssertTrue(sentState.shouldSendHeavy(wanted: true))
    }

    func testPostBondCanArmAfterPreBondToggleAttemptWasDropped() {
        var sentState = RealtimeCommandSentState()

        sentState.recordToggle(wanted: true, queued: false)
        XCTAssertTrue(sentState.shouldSendToggle(wanted: true))

        sentState.recordToggle(wanted: true, queued: true)
        XCTAssertTrue(sentState.toggleArmed)
        XCTAssertFalse(sentState.shouldSendToggle(wanted: true))
    }

    func testDisconnectClearsSentStateButPreservesOwnerIntentForRearm() {
        var owners = RealtimeOwnerCoordinator()
        _ = owners.acquire(.liveSession)
        var sentState = RealtimeCommandSentState()
        sentState.recordToggle(wanted: true, queued: true)
        sentState.recordHeavy(wanted: true, queued: true,
                              at: Date(timeIntervalSince1970: 123))

        sentState.resetForDisconnect()

        XCTAssertFalse(sentState.toggleArmed)
        XCTAssertFalse(sentState.heavyWhoop4Armed)
        XCTAssertNil(sentState.heavyWhoop4ArmedAt)
        XCTAssertEqual(owners.ownersForRearm, Set([.liveSession]))
        XCTAssertTrue(sentState.shouldSendToggle(wanted: true))
        XCTAssertTrue(sentState.shouldSendHeavy(wanted: true))
    }

    func testOfflineLiveAppearanceRecordsOwnerForLaterRearm() {
        var owners = RealtimeOwnerCoordinator()

        let change = owners.acquire(.liveScreen)

        XCTAssertTrue(change.changed)
        XCTAssertTrue(change.becameActive)
        XCTAssertEqual(owners.ownersForRearm, Set([.liveScreen]))
    }

    func testOnlyFirstExplicitOwnerAcquisitionClearsFallback() {
        var owners = RealtimeOwnerCoordinator()
        var standardHRFallback = true

        let first = owners.acquire(.liveScreen)
        if first.becameActive { standardHRFallback = false }
        XCTAssertFalse(standardHRFallback)

        standardHRFallback = true
        let second = owners.acquire(.workout)
        if second.becameActive { standardHRFallback = false }

        XCTAssertTrue(second.changed)
        XCTAssertFalse(second.becameActive)
        XCTAssertTrue(standardHRFallback)
    }
}
