import XCTest
@testable import Strand

/// Breathe's live HRV read raw successive differences, so one missed or extra beat (a common wrist
/// artefact) blew RMSSD up and the gauge read "Deep calm". The buffer now goes through the shared
/// HRV cleaner first. Synthetic intervals only.
final class BreatheLiveRmssdTests: XCTestCase {

    /// 30 beats at about 60 bpm with a steady 20 ms beat-to-beat swing.
    private var steady: [Int] { (0..<30).map { 1_000 + ($0 % 2 == 0 ? 10 : -10) } }

    func testCleanBufferReadsItsTrueVariability() throws {
        XCTAssertEqual(try XCTUnwrap(BreathingView.liveRMSSD(steady)), 20, accuracy: 0.5)
    }

    func testMissedAndExtraBeatsDoNotInflateRMSSD() throws {
        var rr = steady
        rr[10] = 2_000   // a missed beat: two intervals read as one
        rr[20] = 480     // an extra beat split one interval
        let r = try XCTUnwrap(BreathingView.liveRMSSD(rr))
        XCTAssertLessThan(r, 30, "two artefacts must not turn a steady 20 ms into deep calm")
    }

    func testTooFewBeatsGivesNoReading() {
        XCTAssertNil(BreathingView.liveRMSSD([1_000]))
    }
}
