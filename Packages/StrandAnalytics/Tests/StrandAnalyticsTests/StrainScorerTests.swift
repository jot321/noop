import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class StrainScorerTests: XCTestCase {

    /// Build n consecutive 1 Hz HR samples at a constant bpm.
    private func hr(_ bpm: Int, _ n: Int, start: Int = 0) -> [HRSample] {
        (0..<n).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testTanakaAndDefaultMax() {
        XCTAssertEqual(StrainScorer.tanakaHRmax(age: 30), 187.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.defaultMaxHR(age: 30), 190)
    }

    func testTrimpToStrainCeilingMapsTo100() {
        // Edwards 24 h ceiling TRIMP = 7200 → Effort exactly 100.0 with D = 7201
        // (rescaled from the old 21.0; the curve/saturation point is unchanged).
        XCTAssertEqual(StrainScorer.trimpToStrain(7200), 100.0, accuracy: 1e-9)
    }

    func testTrimpToStrainKnownValues() {
        XCTAssertEqual(StrainScorer.trimpToStrain(0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.trimpToStrain(-5), 0.0, accuracy: 1e-9)
        // 10.91 × 100/21 on the rescaled axis.
        XCTAssertEqual(StrainScorer.trimpToStrain(100), 51.96, accuracy: 1e-2)
    }

    func testStrainGoldenEdwardsZone5() {
        // 600 z5 samples at 1 Hz, resting 60, max 190. TRIMP = 600*5*(1/60)=50.
        // Effort = 100*ln(51)/ln(7201) = 44.27 (was 9.3 on the 0–21 axis).
        let s = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60)
        XCTAssertEqual(s!, 44.27, accuracy: 1e-2)
    }

    func testStrainReturnsNilTooFewReadings() {
        XCTAssertNil(StrainScorer.strain(hr(150, 599), maxHR: 190, restingHR: 60))
    }

    func testStrainReturnsNilInvalidHRR() {
        XCTAssertNil(StrainScorer.strain(hr(150, 600), maxHR: 60, restingHR: 60))
        XCTAssertNil(StrainScorer.strain(hr(150, 600), maxHR: 50, restingHR: 60))
    }

    func testStrainMonotonicInZoneTime() {
        // More time at high intensity → higher strain. Compare 600 vs 1200 z5 samples.
        let short = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60)!
        let long = StrainScorer.strain(hr(185, 1200), maxHR: 190, restingHR: 60)!
        XCTAssertGreaterThan(long, short)
    }

    func testStrainMonotonicInIntensity() {
        // Same duration, higher zone → higher strain.
        let z3 = StrainScorer.strain(hr(155, 600), maxHR: 190, restingHR: 60)!  // ~73% HRR → w3
        let z5 = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60)!  // ~96% HRR → w5
        XCTAssertGreaterThan(z5, z3)
    }

    func testStrainBanisterAlsoBounded() {
        let s = StrainScorer.strain(hr(185, 600), maxHR: 190, restingHR: 60, method: .banister)!
        XCTAssertGreaterThan(s, 0)
        XCTAssertLessThanOrEqual(s, 100.0)
    }

    // MARK: - #482/#480 sparse-strap acceptance + honest-zero (regression guards)

    /// Build n samples at a fixed cadence (default 30 s — the WHOOP 5/MG live-HR rate).
    private func hrEvery(_ bpm: Int, _ n: Int, stepS: Int = 30, start: Int = 0) -> [HRSample] {
        (0..<n).map { HRSample(ts: start + $0 * stepS, bpm: bpm) }
    }

    func testSparseStreamScoresOnceItSpansEnoughTime() {
        // The 5/MG case: only ~30 live samples at 30 s cadence — far under minReadings (600), but
        // they SPAN ~15 min, so the score should compute rather than return nil (which made the live
        // gauge fall back to a stale prior-day value). HR 185 is z5, so it produces a real number.
        let sparse = hrEvery(185, 30)                                // 30 × 30 s = 870 s span
        XCTAssertGreaterThanOrEqual(sparse.last!.ts - sparse.first!.ts, StrainScorer.minSpanSeconds)
        XCTAssertNotNil(StrainScorer.strain(sparse, maxHR: 190, restingHR: 60))
    }

    func testSparseStreamStillNilUnderSampleFloor() {
        // A handful of readings (under minSparseReadings) is too little to trust even if spread out.
        let tooFew = hrEvery(185, 5, stepS: 200)                     // 5 samples, wide span, < floor
        XCTAssertNil(StrainScorer.strain(tooFew, maxHR: 190, restingHR: 60))
    }

    func testLightDayHonestlyScoresZeroNotFabricated() {
        // #482: HR that never crosses ~50% HRR earns ZERO Effort, by design. With max 184 / rest 60,
        // zone 1 starts at 122 bpm; a day spent at 82–110 stays below it. The fix must NOT invent
        // load to make the gauge "look alive" — both a dense (4.0) and a sparse (5/MG) light day = 0.
        let denseLight = hr(105, 1200, start: 0)                     // 4.0-style, 20 min at 1 Hz
        let sparseLight = hrEvery(105, 40)                           // 5/MG-style, 40 × 30 s
        XCTAssertEqual(StrainScorer.strain(denseLight, maxHR: 184, restingHR: 60), 0.0)
        XCTAssertEqual(StrainScorer.strain(sparseLight, maxHR: 184, restingHR: 60), 0.0)
    }

    func testSparseStreamScoresRealWorkout() {
        // The same sparse cadence, but a genuine workout (z5) — Effort must be clearly > 0, proving the
        // zero above is about intensity, not about the sparse path swallowing real load.
        let sparseHard = hrEvery(175, 40)                            // 175 bpm ≈ 93% HRR → z5
        let s = StrainScorer.strain(sparseHard, maxHR: 184, restingHR: 60)
        XCTAssertNotNil(s)
        XCTAssertGreaterThan(s!, 0)
    }

    /// The mixed-cadence day a WHOOP 5/MG produces all the time: a 1 Hz backfilled resting morning
    /// followed by a real workout captured only as sparse ~30 s live samples. The old scorer stamped
    /// EVERY sample with the first two samples' 1 s gap, so the run's 90 sparse samples integrated as
    /// ~1.5 zone-minutes instead of ~45 — a genuine workout day collapsed to Effort ≈ 1. Time-weighted
    /// integration must score the mixed day close to the same run represented densely at 1 Hz.
    func testMixedCadenceDayDoesNotCollapseWorkoutLoad() {
        // 2 h of 1 Hz rest (below zone 1 — contributes nothing) then a 45-min z5 run at 30 s cadence.
        let restingMorning = hr(70, 7200, start: 0)
        let sparseRun = hrEvery(175, 90, start: 7200)
        let mixed = restingMorning + sparseRun
        // The reference: the same 45-min run at 1 Hz (what a synced backfill would contain).
        let denseRun = hr(175, 45 * 60, start: 7200)
        let reference = StrainScorer.strain(restingMorning + denseRun, maxHR: 184, restingHR: 60)!

        let mixedStrain = StrainScorer.strain(mixed, maxHR: 184, restingHR: 60)!
        XCTAssertEqual(mixedStrain, reference, accuracy: 2.0,
                       "a sparse-captured run must carry (almost) its full load")
        // And the failure mode itself stays dead: nowhere near the collapsed ~1.
        XCTAssertGreaterThan(mixedStrain, reference * 0.9)
    }

    /// The mirror image: a sparse 30 s opening must not inflate a later dense 1 Hz stretch 30×.
    func testMixedCadenceDayDoesNotInflateDenseLoad() {
        let sparseRest = hrEvery(70, 40, start: 0)                    // 20 min sparse rest (0 load)
        let denseRun = hr(175, 45 * 60, start: 1200)                  // 45-min z5 run at 1 Hz
        let mixed = sparseRest + denseRun
        let reference = StrainScorer.strain(denseRun, maxHR: 184, restingHR: 60)!
        let mixedStrain = StrainScorer.strain(mixed, maxHR: 184, restingHR: 60)!
        XCTAssertEqual(mixedStrain, reference, accuracy: 2.0,
                       "a dense run after a sparse stretch must not count each second as 30 s")
    }

    /// Off-wrist holes never accrue load: a high-HR sample right before a 3 h gap covers at most
    /// `maxSampleGapS`, so strain barely moves versus the same stream without the gap.
    func testOffWristGapDoesNotAccrueLoad() {
        var samples = hrEvery(175, 40, start: 0)                      // 20 min sparse z5
        samples.append(HRSample(ts: 3 * 3600, bpm: 175))              // one sample 3 h later
        let withoutGap = StrainScorer.strain(hrEvery(175, 40, start: 0), maxHR: 184, restingHR: 60)!
        let withGap = StrainScorer.strain(samples, maxHR: 184, restingHR: 60)!
        XCTAssertEqual(withGap, withoutGap, accuracy: 3.0,
                       "the 3 h hole must contribute at most maxSampleGapS of load")
    }

    /// Per-sample durations: own gap to next (clamped), last reuses previous, duplicates count 0.
    func testSampleDurationsMinutes() {
        let s = [HRSample(ts: 0, bpm: 100), HRSample(ts: 1, bpm: 100),
                 HRSample(ts: 31, bpm: 100), HRSample(ts: 31, bpm: 100),
                 HRSample(ts: 10_000, bpm: 100)]
        let d = StrainScorer.sampleDurationsMinutes(s)
        XCTAssertEqual(d[0], 1.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(d[1], 30.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(d[2], 0, accuracy: 1e-9)                       // duplicate ts
        XCTAssertEqual(d[3], StrainScorer.maxSampleGapS / 60, accuracy: 1e-9) // capped long gap
        XCTAssertEqual(d[4], d[3], accuracy: 1e-9)                    // last reuses previous
    }

    func testEstimateHRmaxObservedVsTanaka() {
        // Thin history but known age → tanaka.
        let (v1, src1) = StrainScorer.estimateHRmax([150, 160, 170], age: 30)
        XCTAssertEqual(v1, 187.0, accuracy: 1e-9)
        XCTAssertEqual(src1, "tanaka")

        // No age, no history → unknown.
        let (v2, src2) = StrainScorer.estimateHRmax([150], age: nil)
        XCTAssertEqual(v2, 0.0)
        XCTAssertEqual(src2, "unknown")

        // Dense history with a sustained high tail above tanaka → observed.
        // The 99.5th percentile must exceed 187, so the top ~0.5% must be high:
        // 700 samples, top 10 (>0.5%) at 195 → p99.5 lands in the high tail.
        var hist = Array(repeating: 120.0, count: 690)
        hist.append(contentsOf: Array(repeating: 195.0, count: 10))
        let (v3, src3) = StrainScorer.estimateHRmax(hist, age: 30)
        XCTAssertEqual(src3, "observed")
        XCTAssertGreaterThan(v3, 187.0)
    }

    func testPercentileLinearInterp() {
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 50), 25.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 0), 10.0, accuracy: 1e-9)
        XCTAssertEqual(StrainScorer.percentile([10, 20, 30, 40], 100), 40.0, accuracy: 1e-9)
    }

    func testFitStrainDenominator() throws {
        // Pairs generated from a known D should recover that D. Pairs use the rescaled
        // 0–100 axis (maxStrain = 100), matching fitStrainDenominator's maxStrain term.
        let knownD = 5000.0
        func strainFor(_ t: Double) -> Double { 100 * log(t + 1) / log(knownD) }
        let pairs = [(100.0, strainFor(100)), (1000.0, strainFor(1000)), (50.0, strainFor(50))]
        let fitted = try StrainScorer.fitStrainDenominator(pairs)
        XCTAssertEqual(fitted, knownD, accuracy: 1.0)
    }

    func testFitStrainDenominatorThrowsTooFew() {
        XCTAssertThrowsError(try StrainScorer.fitStrainDenominator([(100, 10)]))
    }
}
