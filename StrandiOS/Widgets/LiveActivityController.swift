#if os(iOS)
import Foundation
import ActivityKit

/// Starts, updates, and ends the live-HR Live Activity. The activity appears on the Lock Screen and
/// in the Dynamic Island while the strap is bonded and streaming heart rate.
@MainActor
final class LiveActivityController {
    private var activity: Activity<NOOPActivityAttributes>?
    private var reconciliation = LiveActivityReconciliationState()
    /// Cached `ActivityAuthorizationInfo` — `update` runs at ~1 Hz off the live HR stream, and
    /// instantiating this system bridge per tick is needless allocation. ActivityKit's auth status
    /// only changes via Settings, so caching for the controller's lifetime is safe.
    private let authInfo = ActivityAuthorizationInfo()
    /// Synchronous gate against concurrent `Activity.request` calls. The `else` branch below is
    /// re-entered while the first request is still in flight (it hasn't assigned `self.activity`
    /// yet), so without this guard two close-together HR samples could both fire `Activity.request`
    /// and create duplicate Live Activities.
    private var isStarting = false
    /// How long after the last push iOS may keep showing the activity as fresh. The activity is
    /// refreshed every ~2 s while streaming, so this never bites a live session; it auto-greys a
    /// frozen activity if the app is suspended/killed without an explicit end (a missed-tick safety net
    /// on top of the connected-driven end below).
    private static let staleAfter: TimeInterval = 120

    /// Drive the activity from the latest live values. Starts immediately on a valid connected HR
    /// sample, updates at the shared active/passive cadence, and ends immediately on opt-out or
    /// disconnect. Score work is lazy so throttled packets and end paths do not scan repository days.
    func update(
        bpm: Int?,
        connected: Bool,
        enabled: Bool,
        activeRealtimeExperience: Bool,
        scoreProvider: () -> (recovery: Int?, effort: Int?)
    ) {
        let canPush = enabled && connected && bpm != nil && authInfo.areActivitiesEnabled
        if canPush {
            // A valid push can cancel an end that has not begun. Begun or completed targets stay
            // excluded even if ActivityKit keeps returning them while an end is suspended or settling.
            reconciliation.cancelPendingEndForValidUpdate()
            if let activity, !reconciliation.isAdoptable(activityID: activity.id) {
                self.activity = nil
            }
            if activity == nil {
                activity = Activity<NOOPActivityAttributes>.activities.first {
                    reconciliation.isAdoptable(activityID: $0.id)
                }
            }
        }

        let now = Date()
        let decision = LiveActivityUpdatePolicy.evaluate(
            hasExistingActivity: activity != nil,
            enabled: enabled,
            connected: connected,
            bpm: bpm,
            activeRealtimeExperience: activeRealtimeExperience,
            lastPush: reconciliation.lastPush,
            now: now
        )

        switch decision {
        case .none:
            return
        case .end:
            scheduleEnd()
            return
        case .start, .update:
            break
        }

        guard canPush else { return }

        let score = scoreProvider()
        let state = NOOPActivityAttributes.ContentState(
            bpm: bpm,
            recovery: score.recovery,
            bonded: connected,
            effort: score.effort
        )
        let staleDate = now.addingTimeInterval(Self.staleAfter)

        if let activity {
            reconciliation.recordPush(at: now)
            Task { await activity.update(ActivityContent(state: state, staleDate: staleDate)) }
        } else {
            // Set the start gate SYNCHRONOUSLY before any await so a second `update` arriving on the
            // main actor while `Activity.request` is still in flight bails here instead of issuing a
            // second request. Cadence is handled by the shared policy above.
            guard !isStarting else { return }
            isStarting = true
            do {
                activity = try Activity.request(
                    attributes: NOOPActivityAttributes(title: String(localized: "Live HR")),
                    content: ActivityContent(state: state, staleDate: staleDate),
                    pushType: nil
                )
                reconciliation.recordPush(at: now)
            } catch {
                activity = nil
            }
            isStarting = false
        }
    }

    private func scheduleEnd() {
        // Snapshot current candidates before scheduling work. Reconciliation excludes targets already
        // assigned to another pending, active, or completed plan.
        let candidates = Activity<NOOPActivityAttributes>.activities
        activity = nil
        let plan = reconciliation.planEnd(targetIDs: candidates.map(\.id))
        let targetIDs = Set(plan.targetIDs)
        let targets = candidates.filter { targetIDs.contains($0.id) }

        guard !targets.isEmpty else {
            if reconciliation.beginEnd(plan) {
                reconciliation.completeEnd(plan)
            }
            return
        }

        Task {
            guard reconciliation.beginEnd(plan) else { return }
            for target in targets {
                await target.end(nil, dismissalPolicy: .immediate)
            }
            // Completion only retires this token. Handle and push state were detached before the task,
            // so actor re-entry during an await cannot clear a newer activity or cadence timestamp.
            reconciliation.completeEnd(plan)
        }
    }
}
#endif
