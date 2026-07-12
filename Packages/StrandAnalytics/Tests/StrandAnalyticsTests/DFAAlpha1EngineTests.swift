import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class DFAAlpha1EngineTests: XCTestCase {

    /// Deterministic LCG so the "random" series are fixed across runs.
    private struct LCG {
        var state: UInt64
        mutating func next01() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            // Box–Muller from two uniforms.
            let u1 = Swift.max(next01(), 1e-12), u2 = next01()
            return (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
        }
    }

    // MARK: DFA sanity — canonical scaling exponents

    func testWhiteNoiseAlphaNearHalf() {
        // Uncorrelated noise around a mean RR of 800 ms → DFA α ≈ 0.5.
        var rng = LCG(state: 42)
        let rr = (0..<600).map { _ in 800.0 + 8.0 * rng.gaussian() }   // tiny 1% jitter, all plausible
        let r = DFAAlpha1Engine.analyze(rrMs: rr)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.alpha1, 0.5, accuracy: 0.2)   // white noise sits near 0.5
        XCTAssertEqual(r!.zone, .aerobic)               // 0.5 ≤ α < 0.75
    }

    func testBrownianAlphaNearOnePointFive() {
        // Cumulative sum of white noise (a random walk) → strongly correlated → α ≈ 1.5.
        var rng = LCG(state: 7)
        var walk = 800.0
        var rr = [Double]()
        for _ in 0..<600 {
            walk += 3.0 * rng.gaussian()
            rr.append(Swift.min(1900, Swift.max(300, walk)))   // keep in plausible bounds
        }
        let r = DFAAlpha1Engine.analyze(rrMs: rr)
        XCTAssertNotNil(r)
        XCTAssertGreaterThan(r!.alpha1, 1.0)   // clearly higher than white noise
        XCTAssertEqual(r!.zone, .belowAerobic)
    }

    // MARK: artifact gate

    func testHeavyArtifactsReturnNil() {
        // A clean base with >5% of beats replaced by wild spikes → over the gate → nil (self-hides).
        var rng = LCG(state: 99)
        var rr = (0..<600).map { _ in 800.0 + 8.0 * rng.gaussian() }
        // Corrupt every 15th beat (~6.7% > 5% gate) with an implausible value.
        for i in stride(from: 0, to: rr.count, by: 15) { rr[i] = 2500 }
        XCTAssertNil(DFAAlpha1Engine.analyze(rrMs: rr))
    }

    func testFewArtifactsAreCorrectedAndPass() {
        // ~2% artifacts (under the 5% gate) → corrected, Result returned, artifactFraction reported.
        var rng = LCG(state: 123)
        var rr = (0..<600).map { _ in 800.0 + 8.0 * rng.gaussian() }
        for i in stride(from: 0, to: rr.count, by: 50) { rr[i] = 2400 }   // ~2% corrupted
        let r = DFAAlpha1Engine.analyze(rrMs: rr)
        XCTAssertNotNil(r)
        XCTAssertLessThanOrEqual(r!.artifactFraction, DFAAlpha1Engine.maxArtifactFraction)
        XCTAssertGreaterThan(r!.artifactFraction, 0)
    }

    // MARK: gates

    func testTooFewBeatsReturnsNil() {
        let rr = [Double](repeating: 800, count: DFAAlpha1Engine.minBeats - 1)
        XCTAssertNil(DFAAlpha1Engine.analyze(rrMs: rr))
    }

    func testConstantSeriesReturnsNil() {
        // No fluctuation at all → every box F(n) is 0 → no scaling to fit → nil.
        let rr = [Double](repeating: 800, count: 600)
        XCTAssertNil(DFAAlpha1Engine.analyze(rrMs: rr))
    }

    // MARK: zone cut-points

    func testZoneClassification() {
        XCTAssertEqual(DFAAlpha1Engine.Zone.classify(0.9), .belowAerobic)
        XCTAssertEqual(DFAAlpha1Engine.Zone.classify(0.75), .belowAerobic)
        XCTAssertEqual(DFAAlpha1Engine.Zone.classify(0.6), .aerobic)
        XCTAssertEqual(DFAAlpha1Engine.Zone.classify(0.5), .aerobic)
        XCTAssertEqual(DFAAlpha1Engine.Zone.classify(0.4), .aboveAnaerobic)
    }

    // MARK: RRInterval convenience

    func testRRIntervalOverload() {
        var rng = LCG(state: 5)
        let rr = (0..<600).map { i in RRInterval(ts: i, rrMs: Int((800.0 + 8.0 * rng.gaussian()).rounded())) }
        XCTAssertNotNil(DFAAlpha1Engine.analyze(rr: rr))
    }
}
