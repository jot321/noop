import SwiftUI
import StrandDesign

/// Surfaces the advanced overnight analytics (docs/ADVANCED_ANALYTICS_PLAN.md) that
/// `IntelligenceEngine` derives and persists to `metricSeries`: nocturnal SpO₂ + apnea screening,
/// stage-resolved / autonomic HRV, thermoregulation curve shape, overnight HR curve, and sleep
/// posture / actigraphy.
///
/// This is the RICH version: instead of a single latest-night readout, each metric is a tappable row
/// carrying its own history sparkline, and the selected metric drives a full trend chart with a
/// W/M/3M/6M/1Y/ALL range control — so a pattern across nights is visible the same way the other
/// dashboard metrics show one. Rows self-hide when a key has no history at all (so a WHOOP 5/MG with
/// no raw SpO₂ stream simply won't show the SpO₂/apnea rows, and the card disappears on a profile with
/// no derived overnight metrics yet).
///
/// APPROXIMATE / non-clinical, matching the rest of the pipeline.
struct SleepAnalyticsCard: View {
    @EnvironmentObject var repo: Repository

    /// Full per-key history (oldest→newest), loaded once. Empty keys are dropped.
    @State private var history: [String: [(day: String, value: Double)]] = [:]
    @State private var apneaBand: String?
    @State private var selectedKey: String?
    @State private var range: ExploreRange = .month
    @State private var loaded = false

    /// The COMPUTED source: IntelligenceEngine writes these keys under "my-whoop-noop", which
    /// `exploreSeries` reaches via its computed layer (plain `series(source:"my-whoop")` never does).
    private let source = "my-whoop"

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2 + 2) {
                header
                if visibleMetrics.isEmpty {
                    Text(loaded
                         ? "No overnight analytics yet. These populate after NOOP decodes a night of sleep (SpO₂ + apnea need a WHOOP 4.0 or Oura; HRV-by-stage, temperature-curve and posture need decoded sleep stages)."
                         : "Loading…")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    metricList
                    if let key = selectedKey ?? visibleMetrics.first?.key {
                        trendSection(for: key)
                    }
                    Text("Approximate, non-clinical. Derived on-device from your raw sensor streams. Tap a row to chart its trend.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: "waveform.path.ecg").foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
            Text("Overnight analytics").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            if let n = history.values.map(\.count).max(), n > 1 {
                Text("\(n) nights").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    // MARK: - Metric catalogue

    /// A derived overnight metric: its `metricSeries` key, display label/unit/hint, and how to format
    /// a value. `higherIsBetter` tints the trend (nil = neutral). Order here is the display order.
    private struct Metric {
        let key: String
        let label: String
        let unit: String
        let hint: String
        let fmt: (Double) -> String
        var scale: Double = 1     // multiply stored value for display (e.g. fraction → %)
    }

    private static let catalogue: [Metric] = [
        Metric(key: "spo2_min", label: "Lowest SpO₂", unit: "%",
               hint: "Nightly minimum oxygen saturation", fmt: { String(format: "%.0f", $0) }),
        Metric(key: "odi", label: "Desaturation index", unit: "/hr",
               hint: "Drops ≥3% per hour (ODI)", fmt: { String(format: "%.1f", $0) }),
        Metric(key: "ahi_est", label: "Apnea screen (AHI)", unit: "AHI",
               hint: "Screening estimate — not a diagnosis", fmt: { String(format: "%.0f", $0) }),
        Metric(key: "sleep_hr_trough", label: "Sleep HR trough", unit: "bpm",
               hint: "Lowest point of the nightly heart-rate curve", fmt: { String(format: "%.0f", $0) }),
        Metric(key: "sleep_hr_trough_frac", label: "Trough timing", unit: "of night",
               hint: "Earlier is better — recovery finished sooner", fmt: { String(format: "%.0f%%", $0) }, scale: 100),
        Metric(key: "nocturnal_dip", label: "Overnight HR dip", unit: "vs day",
               hint: "Sleeping HR below daytime; ~10%+ is the healthy pattern", fmt: { String(format: "%.0f%%", $0) }, scale: 100),
        Metric(key: "hrv_lfhf", label: "Autonomic balance", unit: "LF/HF",
               hint: ">1 sympathetic-leaning, <1 parasympathetic", fmt: { String(format: "%.2f", $0) }),
        Metric(key: "hrv_rmssd_deep", label: "HRV in deep sleep", unit: "ms",
               hint: "RMSSD during deep-sleep epochs", fmt: { String(format: "%.0f", $0) }),
        Metric(key: "hrv_rmssd_rem", label: "HRV in REM", unit: "ms",
               hint: "RMSSD during REM epochs", fmt: { String(format: "%.0f", $0) }),
        Metric(key: "temp_amplitude", label: "Skin-temp swing", unit: "°C",
               hint: "Peak-to-trough of the nightly curve", fmt: { String(format: "%.2f", $0) }),
        Metric(key: "temp_nadir_frac", label: "Temp nadir", unit: "of night",
               hint: "When skin temp bottomed out (0=onset, 1=wake)", fmt: { String(format: "%.0f%%", $0) }, scale: 100),
        Metric(key: "supine_frac", label: "Time supine", unit: "of night",
               hint: "Back-sleeping fraction (supine worsens apnea)", fmt: { String(format: "%.0f%%", $0) }, scale: 100),
        Metric(key: "restless_frac", label: "Restlessness", unit: "of night",
               hint: "Fraction of epochs with movement", fmt: { String(format: "%.0f%%", $0) }, scale: 100),
        Metric(key: "position_changes", label: "Position changes", unit: "",
               hint: "Distinct posture shifts (tossing/turning)", fmt: { String(format: "%.0f", $0) }),
    ]

    /// The catalogue entries that actually have history for this profile, in catalogue order.
    private var visibleMetrics: [Metric] {
        Self.catalogue.filter { !(history[$0.key] ?? []).isEmpty }
    }

    // MARK: - Metric list (each row = latest value + inline history sparkline)

    private var metricList: some View {
        VStack(spacing: 0) {
            ForEach(visibleMetrics, id: \.key) { m in
                let isSelected = (selectedKey ?? visibleMetrics.first?.key) == m.key
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedKey = m.key }
                } label: {
                    metricRow(m, selected: isSelected)
                }
                .buttonStyle(.plain)
                if m.key != visibleMetrics.last?.key {
                    Divider().overlay(StrandPalette.hairline)
                }
            }
        }
    }

    private func metricRow(_ m: Metric, selected: Bool) -> some View {
        let series = history[m.key] ?? []
        let latest = series.last.map { m.fmt($0.value * m.scale) } ?? "—"
        let sparkVals = series.suffix(24).map { $0.value * m.scale }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Text(m.label)
                    .font(StrandFont.subhead.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                if m.key == "ahi_est", let band = apneaBand {
                    Text(band).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: NoopMetrics.space2)
                if sparkVals.count > 1 {
                    Sparkline(values: Array(sparkVals),
                              gradient: StrandPalette.restGradient,
                              lineWidth: 1.5, showsArea: false, showsHead: false, showsHover: false)
                        .frame(width: 56, height: 18)
                        .opacity(selected ? 1 : 0.6)
                }
                Text(latest).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                if !m.unit.isEmpty {
                    Text(m.unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            if selected {
                Text(m.hint).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, NoopMetrics.space2)
        .contentShape(Rectangle())
    }

    // MARK: - Trend section (selected metric across the chosen window)

    @ViewBuilder
    private func trendSection(for key: String) -> some View {
        let m = Self.catalogue.first { $0.key == key }
        let pts = windowedPoints(key: key)
        if let m {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader(LocalizedStringKey(m.label), overline: "Trend", trailing: range.label)
                if pts.count >= 2 {
                    let vals = pts.map(\.value)
                    let avg = vals.reduce(0, +) / Double(vals.count)
                    ChartCard(
                        title: LocalizedStringKey(m.label),
                        subtitle: m.unit.isEmpty ? String(localized: "Per night") : String(localized: "Per night · \(m.unit)"),
                        trailing: String(localized: "avg \(m.fmt(avg))"),
                        height: NoopMetrics.chartHeight,
                        tint: StrandPalette.restColor,
                        chart: {
                            TrendChart(points: pts,
                                       gradient: StrandPalette.restGradient,
                                       valueRange: chartRange(vals),
                                       showsArea: true,
                                       height: NoopMetrics.chartHeight,
                                       valueFormat: { m.fmt($0) },
                                       accessibilityLabel: String(localized: "\(m.label) trend"))
                        },
                        footer: {
                            ChartFooter([
                                ("Avg", m.fmt(avg)),
                                ("Min", m.fmt(vals.min() ?? 0)),
                                ("Max", m.fmt(vals.max() ?? 0)),
                                ("Nights", "\(pts.count)"),
                            ])
                        }
                    )
                    HStack {
                        Spacer()
                        SegmentedPillControl(ExploreRange.allCases, selection: $range) { $0.label }
                    }
                } else {
                    NoopCard(tint: StrandPalette.restColor) {
                        Text("Just one night so far. Keep wearing your strap and a trend will build here.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, minHeight: 88, alignment: .center)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }

    /// History for `key` as TrendPoints, sliced to the selected trailing window. Falls back to ALL
    /// when the trailing slice holds < 2 points (so a short history still charts).
    private func windowedPoints(key: String) -> [TrendPoint] {
        let m = Self.catalogue.first { $0.key == key }
        let scale = m?.scale ?? 1
        let all: [TrendPoint] = (history[key] ?? []).compactMap {
            guard let d = Self.dayParser.date(from: $0.day) else { return nil }
            return TrendPoint(date: d, value: $0.value * scale)
        }
        guard let days = range.days, let last = all.last?.date else { return all }
        let cutoff = last.addingTimeInterval(-Double(days - 1) * 86_400)
        let slice = all.filter { $0.date >= cutoff }
        return slice.count >= 2 ? slice : all
    }

    /// A padded value range for the gradient mapping (never a zero-height domain).
    private func chartRange(_ vals: [Double]) -> ClosedRange<Double> {
        guard let lo = vals.min(), let hi = vals.max() else { return 0...1 }
        if lo == hi { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.1
        return (lo - pad)...(hi + pad)
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // MARK: - Load

    private func load() async {
        guard !loaded else { return }
        loaded = true
        var loadedHistory: [String: [(day: String, value: Double)]] = [:]
        for m in Self.catalogue {
            // fullHistory so the trend can span every recorded night (the range control then windows it).
            let series = await repo.exploreSeries(key: m.key, source: source, fullHistory: true)
            if !series.isEmpty {
                loadedHistory[m.key] = series.sorted { $0.day < $1.day }
            }
        }
        history = loadedHistory
        if let ahi = loadedHistory["ahi_est"]?.last?.value { apneaBand = ApneaBand.classify(ahi) }
        selectedKey = visibleMetrics.first?.key
    }
}

/// Local AHI-band labels for the UI (mirrors ApneaScreener.Band cut points without importing the engine
/// here — keeps this view dependency-light).
private enum ApneaBand {
    static func classify(_ ahi: Double) -> String {
        switch ahi {
        case ..<5: return "Normal"
        case ..<15: return "Mild"
        case ..<30: return "Moderate"
        default: return "Severe"
        }
    }
}
