import XCTest
@testable import StrandAnalytics

final class ACWREngineTests: XCTestCase {

    // MARK: fromDaily

    func testSteadyLoadRatioIsOne() {
        // 28 days of identical Effort → acute mean == chronic mean → ratio 1.0, balanced.
        let daily = [Double?](repeating: 50, count: 28)
        let r = ACWREngine.ratio(fromDaily: daily)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.ratio, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r!.band, .balanced)
        XCTAssertEqual(r!.chronicCount, 28)
    }

    func testSpikeRampsRatioAboveThreshold() {
        // 21 calm days then a 7-day hard block → acute >> chronic base → ramping.
        var daily = [Double?](repeating: 20, count: 21)
        daily += [Double?](repeating: 80, count: 7)
        let r = ACWREngine.ratio(fromDaily: daily)!
        // acute = 80; chronic = (21*20 + 7*80)/28 = (420+560)/28 = 35 → ratio ≈ 2.29
        XCTAssertEqual(r.acute, 80, accuracy: 1e-9)
        XCTAssertEqual(r.chronic, 35, accuracy: 1e-9)
        XCTAssertEqual(r.ratio, 80.0 / 35.0, accuracy: 1e-9)
        XCTAssertEqual(r.band, .ramping)
    }

    func testDropReadsAsDetraining() {
        // 21 hard days then a 7-day near-rest taper → acute well below chronic base → detraining.
        var daily = [Double?](repeating: 60, count: 21)
        daily += [Double?](repeating: 5, count: 7)
        let r = ACWREngine.ratio(fromDaily: daily)!
        // acute = 5; chronic = (21*60 + 7*5)/28 = (1260+35)/28 = 46.25 → ratio ≈ 0.108
        XCTAssertLessThan(r.ratio, 0.8)
        XCTAssertEqual(r.band, .detraining)
    }

    func testRestDaysCountAsZeroLoad() {
        // nil entries (no-data / rest) must pull the mean DOWN (count toward window length), not be
        // silently dropped: 7 acute days of [40, nil×6] → acute mean = 40/7, not 40.
        var daily = [Double?](repeating: 30, count: 21)
        daily += [40] + [Double?](repeating: nil, count: 6)
        let r = ACWREngine.ratio(fromDaily: daily)!
        XCTAssertEqual(r.acute, 40.0 / 7.0, accuracy: 1e-9)
    }

    func testTooLittleChronicHistoryReturnsNil() {
        // Only 10 days of data — below minChronicDays (14) → nil (chronic base too thin).
        let daily = [Double?](repeating: 50, count: 10)
        XCTAssertNil(ACWREngine.ratio(fromDaily: daily))
    }

    func testZeroChronicLoadReturnsNil() {
        // A fully-rested chronic window has no base to divide by → nil, never a divide-by-zero.
        let daily = [Double?](repeating: 0, count: 28)
        XCTAssertNil(ACWREngine.ratio(fromDaily: daily))
    }

    // MARK: band cut-points

    func testBandClassification() {
        XCTAssertEqual(ACWREngine.Band.classify(0.5), .detraining)
        XCTAssertEqual(ACWREngine.Band.classify(0.8), .balanced)
        XCTAssertEqual(ACWREngine.Band.classify(1.29), .balanced)
        XCTAssertEqual(ACWREngine.Band.classify(1.3), .building)
        XCTAssertEqual(ACWREngine.Band.classify(1.49), .building)
        XCTAssertEqual(ACWREngine.Band.classify(1.5), .ramping)
        XCTAssertEqual(ACWREngine.Band.classify(2.0), .ramping)
    }

    // MARK: points convenience (day-indexed, zero-filled)

    func testPointsConvenienceZeroFillsGaps() {
        // A simple integer day index: parse "D<n>" → n. Provide 20 logged days ending at D40, all 50,
        // with 8 gap days that zero-fill. present = 20 ≥ minChronicDays.
        let dayIndex: (String) -> Int? = { s in Int(s.dropFirst()) }
        var points: [(day: String, value: Double)] = []
        // Days D13…D40 is the 28-day window (chronicDays). Log D21…D40 (20 days), leave D13…D20 as gaps.
        for n in 21...40 { points.append((day: "D\(n)", value: 50)) }
        let r = ACWREngine.ratio(points: points, endDay: "D40", dayIndex: dayIndex)
        XCTAssertNotNil(r)
        // chronic mean = (20 days × 50) / 28 = 1000/28 ≈ 35.71; acute (D34…D40 all 50) = 50.
        XCTAssertEqual(r!.acute, 50, accuracy: 1e-9)
        XCTAssertEqual(r!.chronic, 1000.0 / 28.0, accuracy: 1e-9)
        XCTAssertEqual(r!.chronicCount, 28)   // dense window is fully non-nil after zero-fill
    }

    func testPointsConvenienceTooFewLoggedDaysReturnsNil() {
        let dayIndex: (String) -> Int? = { s in Int(s.dropFirst()) }
        // Only 10 logged days in-window → present < minChronicDays → nil.
        var points: [(day: String, value: Double)] = []
        for n in 31...40 { points.append((day: "D\(n)", value: 50)) }
        XCTAssertNil(ACWREngine.ratio(points: points, endDay: "D40", dayIndex: dayIndex))
    }
}
