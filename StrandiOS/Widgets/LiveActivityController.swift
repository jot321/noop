#if os(iOS)
import Foundation
import ActivityKit

/// Starts, updates, and ends the live-HR Live Activity. The activity appears on the Lock Screen and
/// in the Dynamic Island while the strap is bonded and streaming heart rate.
@MainActor
final class LiveActivityController {
    private var activity: Activity<NOOPActivityAttributes>?
    private var lastPush: Date?
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
        activeRealtimeExperience: Bool,
        scoreProvider: () -> (recovery: Int?, effort: Int?)
    ) {
        // Re-adopt an activity that outlived a previous app session. ActivityKit keeps Live Activities
        // alive across launches/relaunches, but a fresh controller starts with `activity == nil`, so
        // without recovering the handle here we can neither update nor END an already-showing activity
        // — which made the #336 opt-out a no-op (#341: toggle off, heart stays) and risked spawning a
        // duplicate on the start path below. Done on the HR tick rather than in `init` because
        // `Activity.activities` isn't reliably hydrated at the instant of process launch.
        if activity == nil { activity = Activity<NOOPActivityAttributes>.activities.first }

        let now = Date()
        let decision = LiveActivityUpdatePolicy.evaluate(
            hasExistingActivity: activity != nil,
            enabled: UnitPrefs.liveActivityEnabled(),
            connected: connected,
            bpm: bpm,
            activeRealtimeExperience: activeRealtimeExperience,
            lastPush: lastPush,
            now: now
        )

        switch decision {
        case .none:
            return
        case .end:
            Task { await end() }
            return
        case .start, .update:
            break
        }

        guard authInfo.areActivitiesEnabled else { return }

        let score = scoreProvider()
        let state = NOOPActivityAttributes.ContentState(
            bpm: bpm,
            recovery: score.recovery,
            bonded: connected,
            effort: score.effort
        )
        let staleDate = now.addingTimeInterval(Self.staleAfter)

        if let activity {
            lastPush = now
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
                lastPush = now
            } catch {
                activity = nil
            }
            isStarting = false
        }
    }

    func end() async {
        // End every NOOP Live Activity, not just our cached handle — covers a straggler from a prior
        // session we never re-adopted (#341) and any rare duplicate. Iterating the live list is the
        // only way to reach activities this controller instance never started.
        for act in Activity<NOOPActivityAttributes>.activities {
            await act.end(nil, dismissalPolicy: .immediate)
        }
        self.activity = nil
        lastPush = nil
    }
}
#endif
