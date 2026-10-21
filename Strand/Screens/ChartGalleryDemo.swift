#if DEBUG
import SwiftUI
import StrandDesign

/// DEBUG-only screenshot host for `--demo-screen charts`: the redesigned chart components on
/// deterministic sample data shaped like real use (an overnight HR gap, a two-month hole in daily HRV),
/// with one chart showing the scrub bubble. Stripped from Release.
struct ChartGalleryDemoHost: View {
    private static let day0: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 21
        return Calendar.current.date(from: c)!
    }()

    private var hr: [TrendPoint] {
        (0..<130).compactMap { i -> TrendPoint? in
            guard !(30..<46).contains(i) else { return nil }   // 02:30–03:50 strap off: a gap
            let t = Self.day0.addingTimeInterval(TimeInterval(i * 300))
            let sleep = i < 120
            let base: Double = sleep ? 54 : 78
            let wave: Double = 6 * sin(Double(i) / 7)
            let jitter: Double = Double((i * 13) % 5)
            return TrendPoint(date: t, value: base + wave + jitter)
        }
    }

    private var hrv: [TrendPoint] {
        let july = (0..<12).map { i -> TrendPoint in
            let v: Double = 44 + 5 * sin(Double(i)) + Double(i % 3)
            return TrendPoint(date: Self.day0.addingTimeInterval(TimeInterval((i - 97) * 86_400)), value: v)
        }
        let oct = (0..<2).map { i -> TrendPoint in
            TrendPoint(date: Self.day0.addingTimeInterval(TimeInterval((i - 1) * 86_400)), value: 46.7 + Double(i))
        }
        return july + oct
    }

    /// A year of Charge with a two-month hole, like real use.
    private var heat: [RecoveryDay] {
        (0..<365).compactMap { i -> RecoveryDay? in
            guard !(200..<280).contains(i) else { return nil }
            let v: Double = 55 + 25 * sin(Double(i) / 9)
            return RecoveryDay(date: Self.day0.addingTimeInterval(TimeInterval((i - 364) * 86_400)), score: v)
        }
    }

    private var stress: [TrendPoint] {
        (0..<30).map { i -> TrendPoint in
            let wave: Double = 0.8 * sin(Double(i) / 4)
            let step: Double = Double(i % 4) * 0.1
            let date = Self.day0.addingTimeInterval(TimeInterval((i - 29) * 86_400))
            return TrendPoint(date: date, value: max(0.2, 1.4 + wave + step))
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: NoopMetrics.gap) {
                ChartCard(title: "Heart rate", subtitle: "5-minute average · since midnight",
                          trailing: "78 bpm") {
                    TrendChart(points: hr, valueRange: 40...100, height: 140,
                               valueFormat: { "\(Int($0.rounded())) bpm" }, previewSelectedIndex: 70)
                } footer: {
                    ChartFooter([("Min", "48"), ("Avg", "58"), ("Max", "86")])
                }
                ChartCard(title: "HRV", subtitle: "Nightly · last 100 days", trailing: "47 ms") {
                    TrendChart(points: hrv, valueRange: 30...60, valueFormat: { "\(Int($0.rounded())) ms" })
                } footer: {
                    ChartFooter([("Latest", "47 ms"), ("Average", "45 ms"), ("Nights", "14")])
                }
                NoopCard {
                    YearHeatStrip(days: heat, cellSize: 5, spacing: 1.5)
                }
                ChartCard(title: "Stress", subtitle: "Daily 0–3 proxy", trailing: "avg 1.5") {
                    TrendChart(points: stress, valueRange: 0...3, valueFormat: { String(format: "%.1f", $0) })
                } footer: {
                    ChartFooter([("Today", "1.4"), ("Average", "1.5"), ("Days", "30")])
                }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
    }
}
#endif
