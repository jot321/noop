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

    func testEffectiveExplicitOwnersFollowSceneStateAndRestoreOnForeground() {
        let allOwners = Set(RealtimeDemandOwner.allCases)

        XCTAssertEqual(
            RealtimeDemandPolicy.effectiveExplicitOwners(allOwners, appForeground: true),
            allOwners
        )
        XCTAssertEqual(
            RealtimeDemandPolicy.effectiveExplicitOwners([.liveScreen], appForeground: false),
            []
        )
        XCTAssertEqual(
            RealtimeDemandPolicy.effectiveExplicitOwners(allOwners, appForeground: false),
            [.workout, .liveSession, .manualControl]
        )
        XCTAssertEqual(
            RealtimeDemandPolicy.effectiveExplicitOwners([.liveScreen], appForeground: true),
            [.liveScreen]
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

        XCTAssertNil(sentState.heavyWhoop4Armed)
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

    func testWithoutResponseBackpressureBlocksStartWithoutAdvancingSentState() {
        let sentState = RealtimeCommandSentState()
        let demand = RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: true)

        let plan = RealtimeCommandWritePlanner.plan(
            deviceFamily: .whoop4,
            demand: demand,
            sentState: sentState,
            connected: true,
            bonded: true,
            canSendWriteWithoutResponse: false
        )

        XCTAssertEqual(plan, .none)
        XCTAssertFalse(sentState.toggleArmed)
        XCTAssertNil(sentState.heavyWhoop4Armed)
        XCTAssertNil(sentState.heavyWhoop4ArmedAt)
    }

    func testWithoutResponseBackpressureBlocksStopWithoutClearingSentState() {
        let armedAt = Date(timeIntervalSince1970: 123)
        var sentState = RealtimeCommandSentState()
        sentState.recordToggle(wanted: true, queued: true)
        sentState.recordHeavy(wanted: true, queued: true, at: armedAt)
        let demand = RealtimeDemandOutput(toggleWanted: false, heavyWhoop4Wanted: false)

        let plan = RealtimeCommandWritePlanner.plan(
            deviceFamily: .whoop4,
            demand: demand,
            sentState: sentState,
            connected: true,
            bonded: true,
            canSendWriteWithoutResponse: false
        )

        XCTAssertEqual(plan, .none)
        XCTAssertTrue(sentState.toggleArmed)
        XCTAssertEqual(sentState.heavyWhoop4Armed, true)
        XCTAssertEqual(sentState.heavyWhoop4ArmedAt, armedAt)
    }

    func testPeripheralReadinessPlansPendingStartRetry() {
        let sentState = RealtimeCommandSentState()
        let demand = RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: true)

        let plan = RealtimeCommandWritePlanner.plan(
            deviceFamily: .whoop4,
            demand: demand,
            sentState: sentState,
            connected: true,
            bonded: true,
            canSendWriteWithoutResponse: true
        )

        XCTAssertEqual(
            plan,
            RealtimeCommandWritePlan(heavyWhoop4Wanted: true, toggleWanted: true)
        )
    }

    func testPeripheralReadinessPlansPendingStopRetry() {
        var sentState = RealtimeCommandSentState()
        sentState.recordToggle(wanted: true, queued: true)
        sentState.recordHeavy(wanted: true, queued: true,
                              at: Date(timeIntervalSince1970: 123))
        let demand = RealtimeDemandOutput(toggleWanted: false, heavyWhoop4Wanted: false)

        let plan = RealtimeCommandWritePlanner.plan(
            deviceFamily: .whoop4,
            demand: demand,
            sentState: sentState,
            connected: true,
            bonded: true,
            canSendWriteWithoutResponse: true
        )

        XCTAssertEqual(
            plan,
            RealtimeCommandWritePlan(heavyWhoop4Wanted: false, toggleWanted: false)
        )
    }

    func testUnknownHeavyStopRemainsRetryableUntilSuccessfullyQueued() {
        var sentState = RealtimeCommandSentState()
        let demand = RealtimeDemandOutput(toggleWanted: false, heavyWhoop4Wanted: false)

        XCTAssertNil(sentState.heavyWhoop4Armed)
        var plan = RealtimeCommandWritePlanner.plan(
            deviceFamily: .whoop4,
            demand: demand,
            sentState: sentState,
            connected: true,
            bonded: true,
            canSendWriteWithoutResponse: true
        )
        XCTAssertEqual(plan.heavyWhoop4Wanted, false)

        sentState.recordHeavy(wanted: false, queued: false, at: Date())
        XCTAssertNil(sentState.heavyWhoop4Armed)
        plan = RealtimeCommandWritePlanner.plan(
            deviceFamily: .whoop4,
            demand: demand,
            sentState: sentState,
            connected: true,
            bonded: true,
            canSendWriteWithoutResponse: true
        )
        XCTAssertEqual(plan.heavyWhoop4Wanted, false)

        sentState.recordHeavy(wanted: false, queued: true, at: Date())
        XCTAssertEqual(sentState.heavyWhoop4Armed, false)
        XCTAssertFalse(sentState.shouldSendHeavy(wanted: false))
    }

    func testUnknownHeavyStartRecordsTrueAfterSuccessfulQueue() {
        var sentState = RealtimeCommandSentState()

        sentState.recordHeavy(
            wanted: true,
            queued: true,
            at: Date(timeIntervalSince1970: 123)
        )

        XCTAssertEqual(sentState.heavyWhoop4Armed, true)
        XCTAssertEqual(sentState.heavyWhoop4ArmedAt, Date(timeIntervalSince1970: 123))
    }

    func testDisconnectAndFamilyTransitionResetHeavyStateToUnknown() {
        var sentState = RealtimeCommandSentState()
        sentState.recordHeavy(wanted: true, queued: true, at: Date())

        sentState.resetForDisconnect()
        XCTAssertNil(sentState.heavyWhoop4Armed)

        sentState.recordHeavy(wanted: false, queued: true, at: Date())
        sentState.resetHeavyForFamilyTransition()
        XCTAssertNil(sentState.heavyWhoop4Armed)
    }

    func testPassiveOnlyPostBondDemandPlansWhoop4StopAndToggleStart() {
        let demand = self.demand(passiveCaptureWanted: true)

        let plan = RealtimeCommandWritePlanner.plan(
            deviceFamily: .whoop4,
            demand: demand,
            sentState: RealtimeCommandSentState(),
            connected: true,
            bonded: true,
            canSendWriteWithoutResponse: true
        )

        XCTAssertEqual(
            plan,
            RealtimeCommandWritePlan(heavyWhoop4Wanted: false, toggleWanted: true)
        )
    }

    func testWhoop5ClearsHeavyStateWithoutPlanningWhoop4Command() {
        var sentState = RealtimeCommandSentState()
        sentState.recordHeavy(wanted: true, queued: true, at: Date())
        sentState.clearHeavyForOtherFamily()

        let plan = RealtimeCommandWritePlanner.plan(
            deviceFamily: .whoop5,
            demand: RealtimeDemandOutput(toggleWanted: true, heavyWhoop4Wanted: false),
            sentState: sentState,
            connected: true,
            bonded: true,
            canSendWriteWithoutResponse: true
        )

        XCTAssertNil(sentState.heavyWhoop4Armed)
        XCTAssertNil(plan.heavyWhoop4Wanted)
        XCTAssertEqual(plan.toggleWanted, true)
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
        XCTAssertNil(sentState.heavyWhoop4Armed)
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

final class ActiveWorkoutRealtimeOwnershipTests: XCTestCase {
    private func apply(
        _ mutation: RealtimeOwnerMutation?,
        to owners: inout RealtimeOwnerCoordinator
    ) {
        switch mutation {
        case let .acquire(owner):
            owners.acquire(owner)
        case let .release(owner):
            owners.release(owner)
        case nil:
            break
        }
    }

    func testStartedWorkoutKeepsOwnerAfterSheetDismissal() {
        var lifecycle = ActiveWorkoutRealtimeOwnership()
        var owners = RealtimeOwnerCoordinator()

        apply(
            lifecycle.workoutActivityChanged(wasActive: false, isActive: true),
            to: &owners
        )
        apply(
            lifecycle.workoutActivityChanged(wasActive: true, isActive: true),
            to: &owners
        )

        XCTAssertEqual(owners.owners, [.workout])
        XCTAssertTrue(lifecycle.ownsRealtime)
    }

    func testRehydratedWorkoutAcquiresOwner() {
        var lifecycle = ActiveWorkoutRealtimeOwnership()
        var owners = RealtimeOwnerCoordinator()

        apply(
            lifecycle.workoutActivityChanged(wasActive: false, isActive: true),
            to: &owners
        )

        XCTAssertEqual(owners.owners, [.workout])
        XCTAssertTrue(lifecycle.ownsRealtime)
    }

    func testEndingWorkoutReleasesOwnerExactlyOnce() {
        var lifecycle = ActiveWorkoutRealtimeOwnership()
        var owners = RealtimeOwnerCoordinator()
        apply(
            lifecycle.workoutActivityChanged(wasActive: false, isActive: true),
            to: &owners
        )

        apply(
            lifecycle.workoutActivityChanged(wasActive: true, isActive: false),
            to: &owners
        )
        let repeatedEnd = lifecycle.workoutActivityChanged(wasActive: false, isActive: false)

        XCTAssertTrue(owners.owners.isEmpty)
        XCTAssertFalse(lifecycle.ownsRealtime)
        XCTAssertNil(repeatedEnd, "Repeated end must not release twice")
    }
}

@MainActor
final class AppModelWorkoutRealtimeIntegrationTests: XCTestCase {
    private func makePersistence() -> ActiveWorkoutPersistenceCoordinator {
        let suite = "test.workoutRealtime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ActiveWorkoutPersistenceCoordinator(
            defaults: defaults,
            snapshotInterval: 0.01,
            queue: DispatchQueue(label: suite)
        )
    }

    func testStartUpdateAndEndDriveProductionOwnerLifecycle() {
        let model = AppModel(
            activeWorkoutPersistence: makePersistence(),
            activeWorkoutLoader: { nil }
        )

        XCTAssertTrue(model.activeRealtimeOwners.isEmpty)
        model.startWorkout(sport: "Other")
        XCTAssertEqual(model.activeRealtimeOwners, [.workout])

        var updated = try! XCTUnwrap(model.activeWorkout)
        updated.avgHr = 120
        model.activeWorkout = updated
        XCTAssertEqual(model.activeRealtimeOwners, [.workout])

        model.endWorkout()
        XCTAssertTrue(model.activeRealtimeOwners.isEmpty)
    }

    func testRehydrationAcquiresProductionWorkoutOwner() {
        let snapshot = ActiveWorkoutPersistence.Snapshot(
            startSec: Int(Date().timeIntervalSince1970) - 60,
            sport: "Other",
            samples: [],
            avgHr: 0,
            peakHr: 0,
            liveStrain: 0
        )
        let model = AppModel(
            activeWorkoutPersistence: makePersistence(),
            activeWorkoutLoader: { snapshot }
        )

        XCTAssertNotNil(model.activeWorkout)
        XCTAssertEqual(model.activeRealtimeOwners, [.workout])
        model.endWorkout()
    }
}
