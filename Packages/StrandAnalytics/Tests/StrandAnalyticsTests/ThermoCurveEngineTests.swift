import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class ThermoCurveEngineTests: XCTestCase {

    /// Synthesize a night: skin temp rises then falls (a shallow V flipped — nadir near the start),
    /// here modeled as a clear parabola with its minimum a third of the way through.
    func testCurveFeaturesFromSyntheticNight() {
        let start = 1_000_000
        let end = start + 8 * 3600
        let span = Double(end - start)
        var samples: [SkinTempSample] = []
        // 8 hours at ~1 Hz would be huge; sample every 30 s (960 samples) — well above minSamples.
        var ts = start
        while ts < end {
            let f = Double(ts - start) / span            // 0..1 through the night
            // Temp dips to a nadir near f=0.15 then rises to a plateau: c = 34 + 3*(f-0.15)^2 (centidegrees)
            let c = 34.0 + 3.0 * (f - 0.15) * (f - 0.15)
            samples.append(.init(ts: ts, raw: Int((c * 100).rounded())))  // whoop5: raw/100
            ts += 30
        }
        let feat = ThermoCurveEngine.analyze(skinTemp: samples, family: .whoop5,
                                             sleepStart: start, sleepEnd: end)
        XCTAssertNotNil(feat)
        // Nadir should be early in the night (~f=0.15).
        XCTAssertLessThan(feat!.nadirFraction, 0.35)
        XCTAssertGreaterThan(feat!.nadirFraction, 0.02)
        // Amplitude positive; curve length == binCount.
        XCTAssertEqual(feat!.curveC.count, ThermoCurveEngine.binCount)
        XCTAssertGreaterThan(feat!.amplitudeC, 0.5)
        // Late-night slope is a rise here (positive) since temp climbs after the early nadir.
        XCTAssertGreaterThan(feat!.preWakeSlopeCPerHour, 0)
    }

    func testRejectsTooFewSamples() {
        let start = 0, end = 8 * 3600
        let samples = (0..<10).map { SkinTempSample(ts: $0 * 60, raw: 3400) }
        XCTAssertNil(ThermoCurveEngine.analyze(skinTemp: samples, family: .whoop5,
                                               sleepStart: start, sleepEnd: end))
    }

    func testGapInterpolation() {
        let input = [1.0, Double.nan, Double.nan, 4.0]
        let out = ThermoCurveEngine.interpolateGaps(input)
        XCTAssertEqual(out, [1.0, 2.0, 3.0, 4.0])
    }

    func testSlopePerStep() {
        // y = 2x + 1 -> slope per index step = 2.
        XCTAssertEqual(ThermoCurveEngine.slopePerStep([1, 3, 5, 7]), 2.0, accuracy: 1e-9)
    }

    func testFiltersImplausibleWornValues() {
        // All samples below the 28C worn floor -> rejected -> nil.
        let start = 0, end = 8 * 3600
        var samples: [SkinTempSample] = []
        var ts = 0
        while ts < end { samples.append(.init(ts: ts, raw: 2000)); ts += 30 } // 20C, below floor
        XCTAssertNil(ThermoCurveEngine.analyze(skinTemp: samples, family: .whoop5,
                                               sleepStart: start, sleepEnd: end))
    }
}
