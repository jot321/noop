import Foundation

/// Chooses which source persists a WHOOP 5.0/MG's live HR and R-R.
///
/// The standard 0x2A37 Heart Rate profile wins while it is delivering. Once it has been silent for
/// `standardHRSilenceSeconds`, the puffin REALTIME_DATA stream (type 40: HR, R-R and a real unix
/// timestamp) is persisted instead. Some 5/MG straps never notify 0x2A37 even with realtime armed and
/// the characteristic subscribed (seen on one strap in Jul and Oct 2026), which left live HR on the
/// Live screen but nothing stored, and made Continuous HRV capture a no-op. Only one source persists at
/// a time, so a heartbeat is never stored twice at neighbouring seconds (strap-unix vs receive time).
enum Whoop5LiveHRPersistence {
    static let standardHRSilenceSeconds: TimeInterval = 10

    /// 5/MG puffin frames carry the packet type at byte 8; 40 is REALTIME_DATA.
    static let realtimeDataType: UInt8 = 40
    static let typeIndex = 8

    static func isRealtimeDataFrame(_ frame: [UInt8]) -> Bool {
        frame.count > typeIndex && frame[typeIndex] == realtimeDataType
    }

    /// True when a live REALTIME_DATA frame should go to the Collector: 0x2A37 has never delivered a
    /// plausible reading this process, or not for longer than the silence window.
    static func persistRealtimeFrames(lastStandardHRAt: Date?, now: Date) -> Bool {
        guard let last = lastStandardHRAt else { return true }
        return now.timeIntervalSince(last) > standardHRSilenceSeconds
    }
}
