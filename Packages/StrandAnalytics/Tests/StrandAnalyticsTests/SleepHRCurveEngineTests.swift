import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepHRCurveEngineTests: XCTestCase {

    /// Synthesize a night whose HR follows a parabola with its minimum at `troughF` of the night,
    /// swinging `amplitude` bpm around `troughBpm`. Sampled every 30 s (960 samples over 8 h).
    private func syntheticNight(start: Int, hours: Int = 8, troughBpm: Double = 52,
                                amplitude: Double = 14, troughF: Double) -> [HRSample] {
        let end = start + hours * 3600
        let span = Double(end - start)
        var out: [HRSample] = []
        var ts = start
        while ts < end {
            let f = Double(ts - start) / span
            let bpm = troughBpm + amplitude * (f - troughF) * (f - troughF) / max(troughF, 1 - troughF)
            out.append(HRSample(ts: ts, bpm: Int(bpm.rounded())))
            ts += 30
        }
        return out
    }

    /// The hammock: trough mid-night, HR rising into wake. Features land where the synthesis put them.
    func testHammockNightFeatures() {
        let start = 1_000_000
        let hr = syntheticNight(start: start, troughF: 0.5)
        let f = SleepHRCurveEngine.analyze(hr: hr, sleepStart: start, sleepEnd: start + 8 * 3600)
        XCTAssertNotNil(f)
        XCTAssertEqual(f!.curveBpm.count, SleepHRCurveEngine.binCount)
        // Integer-bpm rounding flattens the parabola's floor into a run of tied bins and the first
        // tied bin wins, so the detected trough sits slightly early of the analytic 0.5 — allow it.
        XCTAssertEqual(f!.troughFraction, 0.5, accuracy: 0.15)
        XCTAssertEqual(f!.troughTiming, .mid)
        XCTAssertEqual(f!.troughBpm, 52, accuracy: 2)
        XCTAssertGreaterThan(f!.amplitudeBpm, 5)
        XCTAssertLessThan(f!.declineSlopeBpmPerHour, 0, "first half descends toward the trough")
        XCTAssertGreaterThan(f!.preWakeRiseBpmPerHour, 0, "last third rises into wake")
        // Trough timestamp sits mid-window.
        XCTAssertEqual(Double(f!.troughTs), Double(start + 4 * 3600), accuracy: 3600)
    }

    /// The bad night: trough only just before wake — classified late, with a falling (not rising)
    /// pre-wake slope.
    func testLateTroughNightClassifiesLate() {
        let start = 1_000_000
        let hr = syntheticNight(start: start, troughF: 0.9)
        let f = SleepHRCurveEngine.analyze(hr: hr, sleepStart: start, sleepEnd: start + 8 * 3600)
        XCTAssertNotNil(f)
        XCTAssertGreaterThan(f!.troughFraction, 2.0 / 3.0)
        XCTAssertEqual(f!.troughTiming, .late)
        XCTAssertLessThan(f!.preWakeRiseBpmPerHour, 0, "still descending at wake")
    }

    func testEarlyTroughClassifiesEarly() {
        let start = 1_000_000
        let hr = syntheticNight(start: start, troughF: 0.15)
        let f = SleepHRCurveEngine.analyze(hr: hr, sleepStart: start, sleepEnd: start + 8 * 3600)
        XCTAssertNotNil(f)
        XCTAssertEqual(f!.troughTiming, .early)
    }

    /// Too few samples (a mostly-unworn night) → nil, never a fabricated curve.
    func testTooFewSamplesIsNil() {
        let start = 1_000_000
        let hr = (0..<100).map { HRSample(ts: start + $0 * 30, bpm: 55) }
        XCTAssertNil(SleepHRCurveEngine.analyze(hr: hr, sleepStart: start, sleepEnd: start + 8 * 3600))
    }

    /// Implausible samples (doffed-strap zeros, artifact spikes) are gated out before binning.
    func testImplausibleSamplesGatedOut() {
        let start = 1_000_000
        var hr = syntheticNight(start: start, troughF: 0.5)
        for i in 0..<50 {
            hr.append(HRSample(ts: start + i * 60, bpm: 5))     // doffed
            hr.append(HRSample(ts: start + i * 60 + 7, bpm: 220)) // spike
        }
        let f = SleepHRCurveEngine.analyze(hr: hr, sleepStart: start, sleepEnd: start + 8 * 3600)
        XCTAssertNotNil(f)
        XCTAssertEqual(f!.troughBpm, 52, accuracy: 3)
        XCTAssertLessThan(f!.curveBpm.max()!, 80, "spikes must not bend the curve")
    }

    /// Nocturnal dip math + gating: 72 day / 58 sleep ≈ 19.4%; missing or implausible inputs → nil.
    func testNocturnalDip() {
        XCTAssertEqual(SleepHRCurveEngine.nocturnalDip(daytimeMeanBpm: 72, sleepMeanBpm: 58)!,
                       0.194, accuracy: 0.001)
        XCTAssertNil(SleepHRCurveEngine.nocturnalDip(daytimeMeanBpm: nil, sleepMeanBpm: 58))
        XCTAssertNil(SleepHRCurveEngine.nocturnalDip(daytimeMeanBpm: 72, sleepMeanBpm: nil))
        XCTAssertNil(SleepHRCurveEngine.nocturnalDip(daytimeMeanBpm: 5, sleepMeanBpm: 58))
        // A negative dip (sleeping HIGHER than daytime — illness/alcohol) is still reported honestly.
        XCTAssertEqual(SleepHRCurveEngine.nocturnalDip(daytimeMeanBpm: 60, sleepMeanBpm: 66)!,
                       -0.1, accuracy: 0.001)
    }

    /// Trough-timing thirds are exact at the boundaries.
    func testTroughTimingBoundaries() {
        XCTAssertEqual(SleepHRCurveEngine.TroughTiming.classify(troughFraction: 0.0), .early)
        XCTAssertEqual(SleepHRCurveEngine.TroughTiming.classify(troughFraction: 0.34), .mid)
        XCTAssertEqual(SleepHRCurveEngine.TroughTiming.classify(troughFraction: 0.67), .late)
    }
}
