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
    func testNewPushInvalidatesUnstartedEndToken() {
        var state = LiveActivityReconciliationState()
        let plan = state.planEnd(targetIDs: ["old"])

        state.recordPush(at: Date(timeIntervalSince1970: 1_001))

        XCTAssertFalse(state.shouldBeginEnd(plan))
    }

    func testEndPlanCapturesOnlyTargetsPresentWhenPlanned() {
        var state = LiveActivityReconciliationState()
        var targetIDs = ["old-a", "old-b"]

        let plan = state.planEnd(targetIDs: targetIDs)
        targetIDs.append("new")

        XCTAssertEqual(plan.targetIDs, ["old-a", "old-b"])
    }

    func testCurrentEndTokenBeginsAndCompletes() {
        var state = LiveActivityReconciliationState()
        let plan = state.planEnd(targetIDs: ["old"])

        XCTAssertTrue(state.shouldBeginEnd(plan))
        XCTAssertTrue(state.completeEnd(plan))
        XCTAssertFalse(state.shouldBeginEnd(plan))
    }

    func testStaleCompletionCannotClearNewerPushState() {
        let pushedAt = Date(timeIntervalSince1970: 1_002)
        var state = LiveActivityReconciliationState()
        let stalePlan = state.planEnd(targetIDs: ["old"])
        state.recordPush(at: pushedAt)

        XCTAssertFalse(state.completeEnd(stalePlan))
        XCTAssertEqual(state.lastPush, pushedAt)
    }
}
