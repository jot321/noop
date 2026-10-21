import XCTest
import WhoopStore
import StrandDesign
@testable import Strand

/// A night bridged from two blocks (a short wake split it) must draw on ONE timeline from the night's
/// onset. Each fragment used to be decoded against its OWN start, so the second block's bands began at
/// 0 and overlapped the first, the time axis ended early, and the movement strip drifted. The wake gap
/// between the blocks also vanished from "in bed" and efficiency, while the engine counts it as awake
/// (#777). Synthetic times only.
final class SleepNightMergeTests: XCTestCase {

    private let t0 = 1_800_000_000   // the night's onset (synthetic)

    /// A computed-format segment array: [{start,end,stage}] in absolute unix seconds.
    private func segments(_ parts: [(String, Int)], from start: Int) -> String {
        var t = start
        var out: [String] = []
        for (stage, minutes) in parts {
            out.append("{\"start\":\(t),\"end\":\(t + minutes * 60),\"stage\":\"\(stage)\"}")
            t += minutes * 60
        }
        return "[" + out.joined(separator: ",") + "]"
    }

    private func block(_ start: Int, _ parts: [(String, Int)]) -> CachedSleepSession {
        let minutes = parts.reduce(0) { $0 + $1.1 }
        return CachedSleepSession(startTs: start, endTs: start + minutes * 60, efficiency: nil,
                                  restingHr: nil, avgHrv: nil,
                                  stagesJSON: segments(parts, from: start))
    }

    /// Block A 0:00-2:00, a 20-minute wake gap, block B 2:20-6:00.
    private var night: [CachedSleepSession] {
        [block(t0, [("light", 60), ("deep", 30), ("rem", 30)]),
         block(t0 + 140 * 60, [("light", 120), ("rem", 60), ("wake", 40)])]
    }

    func testSecondBlockDrawsAtItsOwnClockTime() {
        let merged = SleepView.mergeGroup(night, onset: t0, motionByStart: [:])
        let starts = merged.intervals.map(\.start)
        XCTAssertTrue(starts.contains(140 * 60), "block B's first band starts 2h 20m after onset")
        XCTAssertEqual(merged.intervals.map(\.end).max(), 6 * 3_600,
                       "the timeline ends at the wake time, so the axis labels are right")
        let sorted = merged.intervals.sorted { $0.start < $1.start }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(a.end, b.start, "bands never overlap")
        }
    }

    func testWakeGapCountsAsAwake() {
        let merged = SleepView.mergeGroup(night, onset: t0, motionByStart: [:])
        XCTAssertEqual(merged.asleep, 300, accuracy: 0.001)
        XCTAssertEqual(merged.awake, 60, accuracy: 0.001, "40 min staged awake + the 20 min gap")
        XCTAssertEqual(merged.asleep + merged.awake, 360, accuracy: 0.001, "in bed = onset to wake")
        XCTAssertTrue(merged.intervals.contains { $0.stage == .awake && $0.start == 120 * 60 && $0.end == 140 * 60 },
                      "the gap draws as awake on the hypnogram")
    }

    func testMotionStripStaysOnTheSameTimeline() {
        let a = night[0], b = night[1]
        let motion = [a.startTs: Array(repeating: 1.0, count: 240),    // 2 h of 30 s epochs
                      b.startTs: Array(repeating: 2.0, count: 440)]    // 3 h 40 m
        let merged = SleepView.mergeGroup(night, onset: t0, motionByStart: motion)
        XCTAssertEqual(merged.motion.count, 720, "one epoch per 30 s from onset to wake")
        XCTAssertEqual(Array(merged.motion[240..<280]), Array(repeating: 0.0, count: 40),
                       "the wake gap holds no movement")
        XCTAssertEqual(merged.motion[280], 2.0, "block B's movement starts at 2h 20m")
    }

    func testSingleBlockNightIsUnchanged() {
        let one = [night[0]]
        let merged = SleepView.mergeGroup(one, onset: t0, motionByStart: [one[0].startTs: [1, 2, 3]])
        XCTAssertEqual(merged.awake, 0, accuracy: 0.001)
        XCTAssertEqual(merged.asleep, 120, accuracy: 0.001)
        XCTAssertEqual(merged.intervals.map(\.start), [0, 3_600, 5_400])
        XCTAssertEqual(merged.motion, [1, 2, 3])
    }
}
