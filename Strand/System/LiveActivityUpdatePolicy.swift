import Foundation

/// Shared cadence policy for the iOS Live Activity. Kept pure so the macOS test target can verify
/// active/passive decisions with explicit timestamps and no ActivityKit dependency.
enum LiveActivityUpdatePolicy {
    static let activeMinimumInterval: TimeInterval = 2
    static let passiveMinimumInterval: TimeInterval = 30

    enum Decision: Equatable {
        case none
        case start
        case update
        case end
    }

    static func evaluate(
        hasExistingActivity: Bool,
        enabled: Bool,
        connected: Bool,
        bpm: Int?,
        activeRealtimeExperience: Bool,
        lastPush: Date?,
        now: Date
    ) -> Decision {
        guard enabled, connected else { return .end }
        guard bpm != nil else { return .none }
        guard hasExistingActivity else { return .start }

        let minimumInterval = activeRealtimeExperience ? activeMinimumInterval : passiveMinimumInterval
        guard let lastPush else { return .update }
        return now.timeIntervalSince(lastPush) >= minimumInterval ? .update : .none
    }
}
