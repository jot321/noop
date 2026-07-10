import SwiftUI
import StrandDesign

/// Surfaces the advanced overnight analytics (docs/ADVANCED_ANALYTICS_PLAN.md) that
/// `IntelligenceEngine` now derives and persists to `metricSeries`: nocturnal SpO₂ + apnea screening,
/// stage-resolved / autonomic HRV, thermoregulation curve shape, and sleep posture / actigraphy.
///
/// APPROXIMATE / non-clinical, matching the rest of the pipeline. Rows self-hide when their key has no
/// value for the latest day — so a WHOOP 5/MG (no raw SpO₂ stream) simply won't show the SpO₂/apnea
/// rows, and the whole card disappears on a night with no derived metrics at all.
struct SleepAnalyticsCard: View {
    @EnvironmentObject var repo: Repository

    @State private var values: [String: Double] = [:]
    @State private var apneaBand: String?
    @State private var loaded = false

    private let source = "my-whoop"

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2 + 2) {
                header
                if visibleRows.isEmpty {
                    Text(loaded
                         ? "No overnight analytics yet. These populate after NOOP decodes a night of sleep (SpO₂ + apnea need a WHOOP 4.0 or Oura; HRV-by-stage, temperature-curve and posture need decoded sleep stages)."
                         : "Loading…")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(visibleRows, id: \.label) { row in
                        metricRow(row.label, row.value, unit: row.unit, hint: row.hint)
                    }
                    Text("Approximate, non-clinical. Derived on-device from your raw sensor streams.")
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
        }
    }

    // MARK: - Rows

    private struct Row { let label: String; let value: String; let unit: String; let hint: String }

    private var visibleRows: [Row] {
        var rows: [Row] = []
        func add(_ key: String, _ label: String, unit: String, hint: String, fmt: (Double) -> String) {
            if let v = values[key] { rows.append(Row(label: label, value: fmt(v), unit: unit, hint: hint)) }
        }
        // SpO2 + apnea (WHOOP 4.0 / Oura only)
        add("spo2_min", "Lowest SpO₂", unit: "%", hint: "Nightly minimum oxygen saturation") { String(format: "%.0f", $0) }
        add("odi", "Desaturation index", unit: "/hr", hint: "Drops ≥3% per hour (ODI)") { String(format: "%.1f", $0) }
        if let ahi = values["ahi_est"] {
            let band = apneaBand ?? ApneaBand.classify(ahi)
            rows.append(Row(label: "Apnea screen", value: "\(band) (~\(String(format: "%.0f", ahi)))",
                            unit: "AHI", hint: "Screening estimate — not a diagnosis"))
        }
        // Autonomic HRV
        add("hrv_lfhf", "Autonomic balance", unit: "LF/HF", hint: ">1 sympathetic-leaning, <1 parasympathetic") { String(format: "%.2f", $0) }
        add("hrv_rmssd_deep", "HRV in deep sleep", unit: "ms", hint: "RMSSD during deep-sleep epochs") { String(format: "%.0f", $0) }
        add("hrv_rmssd_rem", "HRV in REM", unit: "ms", hint: "RMSSD during REM epochs") { String(format: "%.0f", $0) }
        // Thermoregulation
        add("temp_amplitude", "Skin-temp swing", unit: "°C", hint: "Peak-to-trough of the nightly curve") { String(format: "%.2f", $0) }
        add("temp_nadir_frac", "Temp nadir", unit: "of night", hint: "When skin temp bottomed out (0=onset, 1=wake)") { String(format: "%.0f%%", $0 * 100) }
        // Posture / actigraphy
        add("supine_frac", "Time supine", unit: "of night", hint: "Back-sleeping fraction (supine worsens apnea)") { String(format: "%.0f%%", $0 * 100) }
        add("restless_frac", "Restlessness", unit: "of night", hint: "Fraction of epochs with movement") { String(format: "%.0f%%", $0 * 100) }
        add("position_changes", "Position changes", unit: "", hint: "Distinct posture shifts (tossing/turning)") { String(format: "%.0f", $0) }
        return rows
    }

    private func metricRow(_ label: String, _ value: String, unit: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(value).font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                if !unit.isEmpty {
                    Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Text(hint).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    // MARK: - Load

    private func load() async {
        guard !loaded else { return }
        loaded = true
        let keys = ["spo2_min", "odi", "ahi_est", "hrv_lfhf", "hrv_rmssd_deep", "hrv_rmssd_rem",
                    "temp_amplitude", "temp_nadir_frac", "supine_frac", "restless_frac", "position_changes"]
        var latest: [String: Double] = [:]
        for key in keys {
            let series = await repo.series(key: key, source: source, days: 3)
            if let last = series.max(by: { $0.day < $1.day }) { latest[key] = last.value }
        }
        values = latest
        if let ahi = latest["ahi_est"] { apneaBand = ApneaBand.classify(ahi) }
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
