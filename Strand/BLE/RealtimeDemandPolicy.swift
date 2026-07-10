import Foundation
import WhoopProtocol

enum RealtimeDemandOwner: CaseIterable, Hashable {
    case liveScreen
    case workout
    case liveSession
    case manualControl
}

enum RealtimeDemandReconcileTrigger: Equatable {
    case inputChange
    case postBond
    case disconnectReset
}

struct RealtimeDemandOutput: Equatable {
    var toggleWanted: Bool
    var heavyWhoop4Wanted: Bool
}

struct RealtimeDemandPolicy {
    static func evaluate(deviceFamily: DeviceFamily,
                         owners: Set<RealtimeDemandOwner>,
                         appForeground: Bool,
                         passiveCaptureWanted: Bool,
                         marginalRadioFallback: Bool,
                         trigger: RealtimeDemandReconcileTrigger = .inputChange)
        -> RealtimeDemandOutput {
        _ = trigger
        var activeOwners = owners
        if !appForeground {
            activeOwners.remove(.liveScreen)
        }

        let explicitDemand = !activeOwners.isEmpty
        let toggleWanted = explicitDemand || passiveCaptureWanted
        let heavyWhoop4Wanted = deviceFamily == .whoop4
            && explicitDemand
            && !marginalRadioFallback

        return RealtimeDemandOutput(
            toggleWanted: toggleWanted,
            heavyWhoop4Wanted: heavyWhoop4Wanted
        )
    }
}
