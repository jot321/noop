import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class HRRecoveryEngineTests: XCTestCase {

    /// 1 Hz HR: steady `endBpm` until `workoutEnd`, then an exponential settle toward `restBpm` with
    /// time constant `tauSec` — the textbook post-exercise recovery shape.
    private func syntheticRecovery(end: Int, endBpm: Double, restBpm: Double, tauSec: Double,
                                   preSeconds: Int = 120, postSeconds: Int = 180) -> [HRSample] {
        var out: [HRSample] = []
        for t in (end - preSeconds)...(end + postSeconds) {
            let bpm: Double
            if t <= end {
                bpm = endBpm
            } else {
                let dt = Double(t - end)
                bpm = restBpm + (endBpm - restBpm) * exp(-dt / tauSec)
            }
            out.append(HRSample(ts: t, bpm: Int(bpm.rounded())))
        }
        return out
    }

    /// The golden case: 165 → exponential settle (τ=60 s) means ~63% of the excess is gone at +60 s
    /// and ~86% at +120 s. Both drops land near the analytic values.
    func testExponentialSettleYieldsExpectedDrops() {
        let end = 1_000_000
        let hr = syntheticRecovery(end: end, endBpm: 165, restBpm: 70, tauSec: 60)
        let r = HRRecoveryEngine.analyze(hr: hr, workoutEnd: end)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.endBpm, 165, accuracy: 2)
        // Analytic: at +60s bpm ≈ 70 + 95·e⁻¹ ≈ 104.9 → drop ≈ 60. Median window ±10 s widens tolerance.
        XCTAssertEqual(r!.drop60, 60, accuracy: 8)
        XCTAssertNotNil(r!.drop120)
        // At +120s bpm ≈ 70 + 95·e⁻² ≈ 82.9 → drop ≈ 82.
        XCTAssertEqual(r!.drop120!, 82, accuracy: 8)
        XCTAssertGreaterThan(r!.drop120!, r!.drop60, "recovery keeps accruing into the second minute")
    }

    /// A finish that was never elevated (an easy stretch ending at ~85 bpm) has no recovery to
    /// measure — nil, not a small meaningless number.
    func testLowEndHRIsRefused() {
        let end = 1_000_000
        let hr = syntheticRecovery(end: end, endBpm: 85, restBpm: 65, tauSec: 60)
        XCTAssertNil(HRRecoveryEngine.analyze(hr: hr, workoutEnd: end))
    }

    /// The strap stopped streaming right at the workout end (no post-end coverage) → nil.
    func testMissingRecoveryWindowIsRefused() {
        let end = 1_000_000
        let hr = syntheticRecovery(end: end, endBpm: 160, restBpm: 70, tauSec: 60, postSeconds: 30)
        XCTAssertNil(HRRecoveryEngine.analyze(hr: hr, workoutEnd: end))
    }

    /// Coverage through +60 s but not +120 s → drop60 present, drop120 honestly nil.
    func testDrop120OptionalWhenCoverageEndsEarly() {
        let end = 1_000_000
        let hr = syntheticRecovery(end: end, endBpm: 160, restBpm: 70, tauSec: 60, postSeconds: 80)
        let r = HRRecoveryEngine.analyze(hr: hr, workoutEnd: end)
        XCTAssertNotNil(r)
        XCTAssertNil(r!.drop120)
        XCTAssertGreaterThan(r!.drop60, 0)
    }

    /// Implausible spikes (optical artifact at 250 bpm) are excluded from the medians.
    func testImplausibleSamplesAreIgnored() {
        let end = 1_000_000
        var hr = syntheticRecovery(end: end, endBpm: 160, restBpm: 70, tauSec: 60)
        // Poison the +60s window with artifact spikes; the median of the surviving plausible samples holds.
        hr.append(HRSample(ts: end + 60, bpm: 250))
        hr.append(HRSample(ts: end + 61, bpm: 240))
        let r = HRRecoveryEngine.analyze(hr: hr, workoutEnd: end)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.drop60, 60, accuracy: 8)
    }

    /// Band cut points: ≥25 excellent, ≥18 good, ≥12 fair, else low.
    func testBandClassification() {
        XCTAssertEqual(HRRecoveryEngine.Band.classify(drop60: 31), .excellent)
        XCTAssertEqual(HRRecoveryEngine.Band.classify(drop60: 25), .excellent)
        XCTAssertEqual(HRRecoveryEngine.Band.classify(drop60: 20), .good)
        XCTAssertEqual(HRRecoveryEngine.Band.classify(drop60: 14), .fair)
        XCTAssertEqual(HRRecoveryEngine.Band.classify(drop60: 8), .low)
    }

    /// The day's headline is the LARGEST drop60 (the hard run, not the easy walk).
    func testBestOfDayPicksLargestDrop() {
        let a = HRRecoveryEngine.Result(endBpm: 120, bpmAt60: 108, bpmAt120: nil,
                                        drop60: 12, drop120: nil, sampleCount: 40)
        let b = HRRecoveryEngine.Result(endBpm: 170, bpmAt60: 141, bpmAt120: 128,
                                        drop60: 29, drop120: 42, sampleCount: 60)
        XCTAssertEqual(HRRecoveryEngine.bestOfDay([a, b]), b)
        XCTAssertNil(HRRecoveryEngine.bestOfDay([]))
    }

    func testMedianEvenAndOdd() {
        XCTAssertEqual(HRRecoveryEngine.median([3, 1, 2]), 2)
        XCTAssertEqual(HRRecoveryEngine.median([4, 1, 3, 2]), 2.5)
    }
}
