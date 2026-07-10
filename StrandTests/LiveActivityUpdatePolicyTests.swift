import XCTest
@testable import Strand

final class LiveActivityUpdatePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func decision(
        hasExistingActivity: Bool = false,
        enabled: Bool = true,
        connected: Bool = true,
        bpm: Int? = 72,
        activeRealtimeExperience: Bool = false,
        lastPush: Date? = nil,
        now: Date? = nil
    ) -> LiveActivityUpdatePolicy.Decision {
        LiveActivityUpdatePolicy.evaluate(
            hasExistingActivity: hasExistingActivity,
            enabled: enabled,
            connected: connected,
            bpm: bpm,
            activeRealtimeExperience: activeRealtimeExperience,
            lastPush: lastPush,
            now: now ?? self.now
        )
    }

    func testNoExistingActivityStartsImmediatelyWithValidConnectedHeartRate() {
        XCTAssertEqual(decision(), .start)
    }

    func testActiveExperienceUpdatesAtTwoSecondsButNotBefore() {
        XCTAssertEqual(
            decision(
                hasExistingActivity: true,
                activeRealtimeExperience: true,
                lastPush: now.addingTimeInterval(-1.99)
            ),
            .none
        )
        XCTAssertEqual(
            decision(
                hasExistingActivity: true,
                activeRealtimeExperience: true,
                lastPush: now.addingTimeInterval(-2)
            ),
            .update
        )
    }

    func testPassiveWearUpdatesAtThirtySecondsButNotBefore() {
        XCTAssertEqual(
            decision(
                hasExistingActivity: true,
                activeRealtimeExperience: false,
                lastPush: now.addingTimeInterval(-29.99)
            ),
            .none
        )
        XCTAssertEqual(
            decision(
                hasExistingActivity: true,
                activeRealtimeExperience: false,
                lastPush: now.addingTimeInterval(-30)
            ),
            .update
        )
    }

    func testPassiveToActiveTransitionUsesActiveThreshold() {
        let lastPush = now.addingTimeInterval(-10)

        XCTAssertEqual(
            decision(
                hasExistingActivity: true,
                activeRealtimeExperience: false,
                lastPush: lastPush
            ),
            .none
        )
        XCTAssertEqual(
            decision(
                hasExistingActivity: true,
                activeRealtimeExperience: true,
                lastPush: lastPush
            ),
            .update
        )
    }

    func testDisconnectAndOptOutEndImmediatelyRegardlessOfCadence() {
        XCTAssertEqual(
            decision(
                hasExistingActivity: true,
                connected: false,
                lastPush: now.addingTimeInterval(-0.5)
            ),
            .end
        )
        XCTAssertEqual(
            decision(
                hasExistingActivity: true,
                enabled: false,
                lastPush: now.addingTimeInterval(-0.5)
            ),
            .end
        )
    }

    func testMissingHeartRateDoesNotStartOrUpdate() {
        XCTAssertEqual(decision(bpm: nil), .none)
        XCTAssertEqual(
            decision(
                hasExistingActivity: true,
                bpm: nil,
                activeRealtimeExperience: true,
                lastPush: now.addingTimeInterval(-30)
            ),
            .none
        )
    }
}

final class LiveActivityReconciliationStateTests: XCTestCase {
    func testPendingEndCanceledBeforeBeginPermitsOldTargetAdoption() throws {
        var state = LiveActivityReconciliationState()
        let plan = try XCTUnwrap(state.planEnd(targetIDs: ["old"]))

        XCTAssertFalse(state.isAdoptable(activityID: "old"))
        state.cancelPendingEndForValidUpdate()

        XCTAssertTrue(state.isAdoptable(activityID: "old"))
        XCTAssertFalse(state.beginEnd(plan))
    }

    func testBegunEndKeepsOldTargetNonAdoptableDuringNewerPush() throws {
        var state = LiveActivityReconciliationState()
        let plan = try XCTUnwrap(state.planEnd(targetIDs: ["old"]))

        XCTAssertTrue(state.beginEnd(plan))
        state.cancelPendingEndForValidUpdate()

        XCTAssertFalse(state.isAdoptable(activityID: "old"))
    }

    func testNewTargetRemainsAdoptableWhileOldTargetEnds() throws {
        var state = LiveActivityReconciliationState()
        let plan = try XCTUnwrap(state.planEnd(targetIDs: ["old"]))

        XCTAssertTrue(state.beginEnd(plan))
        XCTAssertTrue(state.isAdoptable(activityID: "new"))
    }

    func testCompletedEndTargetRemainsNonAdoptableWhileActivityListLags() throws {
        var state = LiveActivityReconciliationState()
        let plan = try XCTUnwrap(state.planEnd(targetIDs: ["old"]))

        XCTAssertTrue(state.beginEnd(plan))
        XCTAssertTrue(state.completeEnd(plan))
        XCTAssertFalse(state.isAdoptable(activityID: "old"))
    }

    func testOverlappingPlansIsolateTargetIDSets() throws {
        var state = LiveActivityReconciliationState()
        let firstPlan = try XCTUnwrap(state.planEnd(targetIDs: ["old"]))
        let secondPlan = try XCTUnwrap(state.planEnd(targetIDs: ["old", "new"]))

        XCTAssertEqual(firstPlan.targetIDs, ["old"])
        XCTAssertEqual(secondPlan.targetIDs, ["new"])
        XCTAssertTrue(state.beginEnd(firstPlan))
        XCTAssertTrue(state.beginEnd(secondPlan))

        XCTAssertTrue(state.completeEnd(firstPlan))
        XCTAssertFalse(state.isAdoptable(activityID: "old"))
        XCTAssertFalse(state.isAdoptable(activityID: "new"))
        XCTAssertTrue(state.completeEnd(secondPlan))
    }

    func testEndPlanCapturesOnlyTargetsPresentWhenPlanned() throws {
        var state = LiveActivityReconciliationState()
        var targetIDs = ["old-a", "old-b"]

        let plan = try XCTUnwrap(state.planEnd(targetIDs: targetIDs))
        targetIDs.append("new")

        XCTAssertEqual(plan.targetIDs, ["old-a", "old-b"])
    }

    func testCompletionDoesNotClearNewerPushState() throws {
        let pushedAt = Date(timeIntervalSince1970: 1_002)
        var state = LiveActivityReconciliationState()
        let plan = try XCTUnwrap(state.planEnd(targetIDs: ["old"]))
        XCTAssertTrue(state.beginEnd(plan))
        state.recordPush(at: pushedAt)

        XCTAssertTrue(state.completeEnd(plan))
        XCTAssertEqual(state.lastPush, pushedAt)
    }

    func testEmptyAndUnavailableTargetsDoNotCreateNoOpEndPlans() throws {
        var state = LiveActivityReconciliationState()

        XCTAssertNil(state.planEnd(targetIDs: []))
        let plan = try XCTUnwrap(state.planEnd(targetIDs: ["old"]))
        XCTAssertNil(state.planEnd(targetIDs: ["old", "old"]))
        XCTAssertTrue(state.beginEnd(plan))
        XCTAssertNil(state.planEnd(targetIDs: ["old"]))
    }

    func testTerminalHydrationRetriesAreBoundedAndDuplicateSuppressed() throws {
        var state = LiveActivityReconciliationState(maxTerminalHydrationRetries: 2)

        let first = try XCTUnwrap(state.planTerminalHydrationRetry())
        XCTAssertEqual(first.attempt, 1)
        XCTAssertNil(state.planTerminalHydrationRetry())
        XCTAssertTrue(state.beginTerminalHydrationRetry(first))

        let second = try XCTUnwrap(state.planTerminalHydrationRetry())
        XCTAssertEqual(second.attempt, 2)
        XCTAssertTrue(state.beginTerminalHydrationRetry(second))
        XCTAssertNil(state.planTerminalHydrationRetry())
    }

    func testValidStateCancelsUnstartedTerminalHydrationRetry() throws {
        var state = LiveActivityReconciliationState(maxTerminalHydrationRetries: 2)
        let canceled = try XCTUnwrap(state.planTerminalHydrationRetry())

        state.cancelPendingEndForValidUpdate()

        XCTAssertFalse(state.beginTerminalHydrationRetry(canceled))
        XCTAssertEqual(try XCTUnwrap(state.planTerminalHydrationRetry()).attempt, 1)
    }

    func testFindingTerminalTargetsCancelsRetryAndSuppressesLaterAttempts() throws {
        var state = LiveActivityReconciliationState(maxTerminalHydrationRetries: 2)
        let canceled = try XCTUnwrap(state.planTerminalHydrationRetry())

        state.markTerminalTargetsFound()

        XCTAssertFalse(state.beginTerminalHydrationRetry(canceled))
        XCTAssertNil(state.planTerminalHydrationRetry())
    }
}

final class LiveActivityEndCandidateSetTests: XCTestCase {
    private struct Candidate: Equatable {
        let id: String
        let source: String
    }

    func testCachedHandleIsUnionedWithListedActivitiesAndWinsDuplicateID() {
        let cached = Candidate(id: "cached", source: "handle")
        let listed = [
            Candidate(id: "cached", source: "enumeration"),
            Candidate(id: "listed", source: "enumeration")
        ]

        XCTAssertEqual(
            LiveActivityEndCandidateSet.deduplicated(
                cached: cached,
                listed: listed,
                id: \.id
            ),
            [cached, listed[1]]
        )
    }
}
