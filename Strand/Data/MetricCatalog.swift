import Foundation

/// One interrogable metric: how to fetch it (key+source), how to label/format it, and whether
/// higher is better (drives delta tinting). The Metric Explorer + Compare are built from this list.
struct MetricDescriptor: Identifiable, Hashable {
    let key: String
    let title: String
    let category: String
    let unit: String
    let source: String       // "my-whoop" or "apple-health"
    let icon: String
    let decimals: Int
    let higherIsBetter: Bool?
    /// A short, plain-English one-liner for the metric (tile subtitle / catalog blurb). Optional —
    /// only the headline scores and the derived overnight metrics carry one; everything else is nil.
    var description: String? = nil
    /// Display multiplier applied to the STORED value before formatting (e.g. 100 for the
    /// fraction-stored overnight keys like `supine_frac`, so 0.42 renders as 42%). The chart,
    /// stat tiles and tooltips all read the scaled series, so axis and labels agree. Default 1.
    var displayScale: Double = 1
    var id: String { source + ":" + key }

    /// Human label for the metric's source partition (catalog row caption / detail subtitle).
    var sourceLabel: String {
        switch source {
        case "apple-health": return "Apple Health"
        case "xiaomi-band":  return "Mi Band"
        case "nutrition-csv": return String(localized: "Nutrition")
        case "noop-mood":    return String(localized: "Mood")
        default:             return "Whoop"   // "my-whoop" + on-device computed sources
        }
    }

    /// True for the Effort metric (#268). Its stored value is 0–100; the effort-scale toggle converts
    /// the DISPLAYED number + unit onto WHOOP's 0–21 axis. Mirrors the Android `MetricSpec.whoopEffort`
    /// gate (`key == "strain"`) — the only value-converting metric in the catalog.
    private var isEffort: Bool { key == "strain" }

    func format(_ v: Double) -> String {
        let n = decimals == 0 ? String(Int(v.rounded())) : String(format: "%.\(decimals)f", v)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    /// Effort-aware plain format (#268): the Effort metric's stored 0–100 value is shown on the selected
    /// scale (its number + "/100"→"/21" unit); every other metric is scale-agnostic and falls through to
    /// the unit-less `format` above. Callers that don't carry an effort scale get `.hundred` (no change).
    func format(_ v: Double, effortScale: EffortScale) -> String {
        guard isEffort else { return format(v) }
        let n = UnitFormatter.effortDisplay(v, scale: effortScale)
        return "\(n) \(displayUnit(effortScale: effortScale))"
    }

    /// Unit-aware format: for the three SI-stored metrics that have a non-metric counterpart
    /// (weight/lean_mass in kg, skin_temp in °C) convert + relabel via `UnitFormatter`. The Effort
    /// metric follows its own 0–100↔0–21 scale (#268). Every other metric (%, bpm, ms, min, …) is
    /// scale-agnostic and falls through to the plain `format` above, so each toggle only ever touches
    /// the values that actually have a converted form.
    func format(_ v: Double, system: UnitSystem, temperature: TemperatureUnit,
                effortScale: EffortScale = .hundred) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massFromKilograms(v, system: system)
        case "°C":  return UnitFormatter.temperatureFromCelsius(v, unit: temperature, decimals: decimals)
        default:    return isEffort ? format(v, effortScale: effortScale) : format(v)
        }
    }

    /// Like `format`, but for a DIFFERENCE between two values (e.g. the Δ StatTile). A temperature
    /// delta scales by 9/5 with NO +32 offset; mass/distance deltas scale by their plain factor; an
    /// Effort delta rescales 0–100→0–21 on the WHOOP scale (#268, no offset — it's a magnitude). The
    /// caller supplies the magnitude (sign is rendered separately).
    func formatDelta(_ v: Double, system: UnitSystem, temperature: TemperatureUnit,
                     effortScale: EffortScale = .hundred) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massFromKilograms(v, system: system)
        case "°C":  return UnitFormatter.temperatureDeltaFromCelsius(v, unit: temperature, decimals: decimals)
        default:
            guard isEffort else { return format(v) }
            // A delta on the 0–100 axis rescales by the same ×21/100 factor (the offset-free `effortValue`).
            let n = UnitFormatter.effortDisplay(v, scale: effortScale)
            return "\(n) \(displayUnit(effortScale: effortScale))"
        }
    }

    /// The unit LABEL as displayed (e.g. the trailing chip in the Metric Explorer list), mapped to the
    /// active system. Only the convertible units change; everything else returns its stored label.
    func displayUnit(system: UnitSystem, temperature: TemperatureUnit,
                     effortScale: EffortScale = .hundred) -> String {
        switch unit {
        case "kg":  return UnitFormatter.massUnit(system)
        case "°C":  return UnitFormatter.temperatureUnit(temperature)
        default:    return isEffort ? displayUnit(effortScale: effortScale) : unit
        }
    }

    /// The Effort metric's unit LABEL on the selected scale — "/100" or "/21" (#268). Non-Effort metrics
    /// return their stored label unchanged. Mirrors the Android `MetricSpec.displayUnit` swap.
    func displayUnit(effortScale: EffortScale) -> String {
        guard isEffort else { return unit }
        return "/" + UnitFormatter.effortScaleMax(effortScale)
    }
}

/// Canonical catalog — mirrors the WHOOP "Trend View" plus Apple Health body metrics.
/// Keys match exactly what the importers write into metricSeries.
enum MetricCatalog {
    static let categories = ["Heart", "Charge", "Rest", "Effort", "Health", "Nutrition", "Mind"]

    static let all: [MetricDescriptor] = [
        // ── Heart
        d("avg_hr", String(localized: "Average Heart Rate"), "Heart", "bpm", "my-whoop", "heart", 0, nil),
        d("max_hr", String(localized: "Max Heart Rate"), "Heart", "bpm", "my-whoop", "bolt.heart", 0, nil),
        d("energy_kcal", String(localized: "Calories"), "Heart", "kcal", "my-whoop", "flame", 0, nil),
        d("vo2max", String(localized: "VO₂ Max"), "Heart", "", "apple-health", "lungs.fill", 1, true),
        d("fitness_age", String(localized: "Fitness Age"), "Heart", "yrs", "my-whoop", "figure.run", 0, false),
        d("vo2max_est", String(localized: "VO₂ Max (estimated)"), "Heart", "", "my-whoop", "lungs", 1, true),
        d("vitality", String(localized: "Vitality"), "Heart", "", "my-whoop", "sparkles", 0, true),
        d("body_age", String(localized: "Body Age"), "Heart", "yrs", "my-whoop", "figure.stand", 0, false),

        // ── Charge (was Recovery)
        d("recovery", String(localized: "Charge"), "Charge", "%", "my-whoop", "heart.circle", 0, true,
          String(localized: "How recovered you are, led by HRV versus your personal baseline.")),
        d("hrv", String(localized: "Heart Rate Variability"), "Charge", "ms", "my-whoop", "waveform.path.ecg", 0, true),
        d("rhr", String(localized: "Resting Heart Rate"), "Charge", "bpm", "my-whoop", "heart", 0, false),
        d("resp_rate", String(localized: "Respiratory Rate"), "Charge", "rpm", "my-whoop", "lungs", 1, nil),
        d("spo2", String(localized: "Blood Oxygen"), "Charge", "%", "my-whoop", "drop", 0, true),
        d("skin_temp", String(localized: "Skin Temperature"), "Charge", "°C", "my-whoop", "thermometer", 1, nil),

        // ── Rest (was Sleep)
        d("sleep_performance", String(localized: "Rest"), "Rest", "%", "my-whoop", "moon.stars", 0, true,
          String(localized: "How restorative your sleep was: duration, efficiency, deep+REM, timing.")),
        d("in_bed_min", String(localized: "Time in Bed"), "Rest", "min", "my-whoop", "bed.double", 0, nil),
        d("sleep_total_min", String(localized: "Asleep Time"), "Rest", "min", "my-whoop", "moon.zzz", 0, true),
        d("hours_vs_needed_pct", String(localized: "Hours vs Needed"), "Rest", "%", "my-whoop", "gauge.medium", 0, true),
        d("sleep_consistency", String(localized: "Sleep Consistency"), "Rest", "%", "my-whoop", "calendar", 0, true),
        d("restorative_pct", String(localized: "Restorative Sleep"), "Rest", "%", "my-whoop", "sparkles", 0, true),
        d("restorative_min", String(localized: "Restorative Sleep"), "Rest", "min", "my-whoop", "sparkles", 0, true),
        d("sleep_efficiency", String(localized: "Sleep Efficiency"), "Rest", "%", "my-whoop", "bed.double.fill", 0, true),
        d("sleep_deep_min", String(localized: "Deep (SWS) Sleep"), "Rest", "min", "my-whoop", "moon.fill", 0, true),
        d("sleep_rem_min", String(localized: "REM Sleep"), "Rest", "min", "my-whoop", "moon.haze", 0, true),
        d("sleep_light_min", String(localized: "Light Sleep"), "Rest", "min", "my-whoop", "moon", 0, nil),
        d("sleep_need_min", String(localized: "Sleep Need"), "Rest", "min", "my-whoop", "gauge", 0, nil),
        d("sleep_debt_min", String(localized: "Sleep Debt"), "Rest", "min", "my-whoop", "exclamationmark.circle", 0, false),

        // ── Effort (was Strain)
        d("strain", String(localized: "Effort"), "Effort", "/100", "my-whoop", "flame", 1, nil,
          String(localized: "Cardiovascular load for the day, on a 0-100 scale (was 0-21).")),
        d("steps", String(localized: "Steps"), "Effort", "", "apple-health", "figure.walk", 0, true),
        // On-device steps ESTIMATE for a WHOOP 4.0 (no real step count over BLE): the strap's daily
        // motion volume scaled by a personal calibration. Stored under the computed "-noop" source, so
        // it reads through the same exploreSeries fallback fitness_age/vitality use. Distinct from the
        // real "steps" above — labelled "(estimated)" so it's never mistaken for a measured count.
        d("steps_est", String(localized: "Steps (estimated)"), "Effort", "steps", "my-whoop", "figure.walk.motion", 0, true,
          String(localized: "Estimated from your WHOOP's motion, calibrated to your phone. Not a measured step count.")),
        d("hr_zones13_min", String(localized: "HR Zones 1-3"), "Effort", "min", "my-whoop", "heart", 0, nil),
        d("hr_zones45_min", String(localized: "HR Zones 4-5"), "Effort", "min", "my-whoop", "heart.fill", 0, nil),
        d("hr_zones_all_min", String(localized: "HR Zones (All)"), "Effort", "min", "my-whoop", "heart.text.square", 0, nil),
        d("strength_min", String(localized: "Strength Activity Time"), "Effort", "min", "my-whoop", "dumbbell", 0, nil),
        d("active_kcal", String(localized: "Active Energy"), "Effort", "kcal", "apple-health", "flame.fill", 0, nil),

        // ── Health / Body
        d("weight", String(localized: "Weight"), "Health", "kg", "apple-health", "scalemass", 1, nil),
        d("body_fat", String(localized: "Body Fat"), "Health", "%", "apple-health", "percent", 1, false),
        d("lean_mass", String(localized: "Lean Body Mass"), "Health", "kg", "apple-health", "figure.arms.open", 1, true),
        d("bmi", "BMI", "Health", "", "apple-health", "figure", 1, nil),
        d("stress", String(localized: "Day Stress"), "Health", "/3", "my-whoop", "gauge.with.dots.needle.50percent", 1, false),

        // ── Nutrition (imported from a food-tracker CSV: calories-in alongside calories-out)
        d("calories_in", String(localized: "Calories In"), "Nutrition", "kcal", "nutrition-csv", "fork.knife", 0, nil),
        d("protein_g", String(localized: "Protein"), "Nutrition", "g", "nutrition-csv", "p.circle", 0, nil),
        d("carbs_g", String(localized: "Carbs"), "Nutrition", "g", "nutrition-csv", "c.circle", 0, nil),
        d("fat_g", String(localized: "Fat"), "Nutrition", "g", "nutrition-csv", "f.circle", 0, nil),

        // ── Mind (daily mood check-in, 1–5; non-clinical self-tracking)
        d("mood", String(localized: "Mood"), "Mind", "/5", "noop-mood", "face.smiling", 0, true),

        // ── Derived overnight / recovery analytics (computed on-device by the advanced pass in
        //    IntelligenceEngine; read through exploreSeries' computed layer). These already render
        //    as single-value rows on the Sleep analytics card — listing them here makes them
        //    TRENDABLE: full history, baseline band, stats, correlations. All APPROXIMATE and
        //    non-clinical. Fraction-stored keys carry displayScale 100 so they read as %.
        d("hrr60", String(localized: "HR Recovery (1 min)"), "Heart", "bpm", "my-whoop", "arrow.down.heart", 0, true,
          String(localized: "How far your heart rate falls one minute after a workout ends. A strong longitudinal fitness marker.")),
        d("hrr120", String(localized: "HR Recovery (2 min)"), "Heart", "bpm", "my-whoop", "arrow.down.heart.fill", 0, true,
          String(localized: "Heart-rate drop two minutes after a workout ends.")),
        d("nocturnal_dip", String(localized: "Overnight HR Dip"), "Rest", "%", "my-whoop", "moon.circle", 0, true,
          String(localized: "How far your sleeping heart rate drops below daytime. ~10%+ is the healthy pattern; a blunted dip is worth watching."), scale: 100),
        d("sleep_hr_mean", String(localized: "Sleeping Heart Rate"), "Rest", "bpm", "my-whoop", "heart.circle", 0, false),
        d("sleep_hr_trough", String(localized: "Sleep HR Trough"), "Rest", "bpm", "my-whoop", "heart", 0, false,
          String(localized: "The lowest point of your nightly heart-rate curve.")),
        d("sleep_hr_trough_frac", String(localized: "HR Trough Timing"), "Rest", "%", "my-whoop", "clock", 0, false,
          String(localized: "When your HR bottomed out (0% = sleep onset, 100% = wake). Earlier means recovery finished sooner."), scale: 100),
        d("sleep_hr_amplitude", String(localized: "Overnight HR Range"), "Rest", "bpm", "my-whoop", "arrow.up.and.down", 0, nil),
        d("sleep_hr_prewake_rise", String(localized: "Pre-wake HR Rise"), "Rest", "bpm/h", "my-whoop", "sunrise", 1, nil),
        d("hrv_lfhf", String(localized: "Autonomic Balance"), "Charge", "LF/HF", "my-whoop", "waveform.path", 2, nil,
          String(localized: "Sympathetic/parasympathetic balance overnight. >1 leans sympathetic, <1 parasympathetic.")),
        d("hrv_rmssd_deep", String(localized: "HRV in Deep Sleep"), "Charge", "ms", "my-whoop", "waveform.path.ecg", 0, true),
        d("hrv_rmssd_rem", String(localized: "HRV in REM"), "Charge", "ms", "my-whoop", "waveform.path.ecg", 0, true),
        d("spo2_min", String(localized: "Lowest SpO₂"), "Charge", "%", "my-whoop", "drop", 0, true),
        d("temp_amplitude", String(localized: "Skin-temp Swing"), "Rest", "Δ°C", "my-whoop", "thermometer", 2, nil,
          String(localized: "Peak-to-trough of the nightly skin-temperature curve — a circadian-rhythm marker.")),
        d("temp_nadir_frac", String(localized: "Temp Nadir Timing"), "Rest", "%", "my-whoop", "thermometer.low", 0, nil, nil, scale: 100),
        d("temp_prewake_slope", String(localized: "Pre-wake Temp Slope"), "Rest", "°C/h", "my-whoop", "thermometer.sun", 2, nil),
        d("odi", String(localized: "Desaturation Index"), "Rest", "/hr", "my-whoop", "drop.triangle", 1, false,
          String(localized: "Oxygen drops of 3%+ per hour of sleep. A screening signal, not a diagnosis.")),
        d("t90", String(localized: "Time Below 90% SpO₂"), "Rest", "%", "my-whoop", "drop.halffull", 1, false, nil, scale: 100),
        d("ahi_est", String(localized: "Apnea Screen (est.)"), "Rest", "AHI", "my-whoop", "lungs", 0, false,
          String(localized: "Estimated apnea-hypopnea index. A screening estimate against your own nights — never a diagnosis.")),
        d("supine_frac", String(localized: "Time on Back"), "Rest", "%", "my-whoop", "bed.double", 0, nil, nil, scale: 100),
        d("restless_frac", String(localized: "Restlessness"), "Rest", "%", "my-whoop", "wind", 0, false, nil, scale: 100),
        d("position_changes", String(localized: "Position Changes"), "Rest", "", "my-whoop", "arrow.left.arrow.right", 0, false),

        // Training-load & threshold analytics (WS-4c/4d). ACWR turns Effort history into forward-looking
        // guidance; DFA-α1 is an EXPERIMENTAL lab-free aerobic/anaerobic-threshold proxy (self-hides on
        // artifact-heavy wrist-PPG workouts). higherIsBetter is nil for both — the useful reading is the
        // BAND / zone, not a monotonic "up good", so we don't tint a delta as improvement.
        d("acwr", String(localized: "Training Load Ratio"), "Effort", "×", "my-whoop", "chart.line.uptrend.xyaxis", 2, nil,
          String(localized: "Acute:chronic workload ratio — your last 7 days of Effort against your last 28. Around 1.0 is steady; much above ~1.5 means you're ramping fast.")),
        d("dfa_a1", String(localized: "DFA-α1 (experimental)"), "Effort", "", "my-whoop", "waveform.path.ecg.rectangle", 2, nil,
          String(localized: "An experimental HRV-based training-intensity marker from your workout beat-to-beat intervals. ~0.75 marks the aerobic threshold, ~0.5 the anaerobic. Needs clean data, so it only appears for steady, low-motion sessions.")),

        // ── Mi Band (imported from Mi Fitness). Same metricSeries mechanism as Apple Health /
        //    Nutrition, so these light up Explore, Compare and the correlation scan. Distinct
        //    `source` keeps them comparable against the WHOOP/Apple versions rather than colliding.
        d("avg_hr", String(localized: "Average Heart Rate"), "Heart", "bpm", "xiaomi-band", "heart", 0, nil),
        d("max_hr", String(localized: "Max Heart Rate"), "Heart", "bpm", "xiaomi-band", "bolt.heart", 0, nil),
        d("energy_kcal", String(localized: "Calories"), "Heart", "kcal", "xiaomi-band", "flame", 0, nil),
        d("vitality", String(localized: "Vitality"), "Heart", "", "xiaomi-band", "sparkles", 0, true),
        d("rhr", String(localized: "Resting Heart Rate"), "Charge", "bpm", "xiaomi-band", "heart", 0, false),
        d("spo2", String(localized: "Blood Oxygen"), "Charge", "%", "xiaomi-band", "drop", 0, true),
        d("sleep_total_min", String(localized: "Asleep Time"), "Rest", "min", "xiaomi-band", "moon.zzz", 0, true),
        d("sleep_deep_min", String(localized: "Deep (SWS) Sleep"), "Rest", "min", "xiaomi-band", "moon.fill", 0, true),
        d("sleep_rem_min", String(localized: "REM Sleep"), "Rest", "min", "xiaomi-band", "moon.haze", 0, true),
        d("sleep_light_min", String(localized: "Light Sleep"), "Rest", "min", "xiaomi-band", "moon", 0, nil),
        d("sleep_score", String(localized: "Sleep Score"), "Rest", "", "xiaomi-band", "moon.stars", 0, true),
        d("steps", String(localized: "Steps"), "Effort", "", "xiaomi-band", "figure.walk", 0, true),
        d("intensity_min", String(localized: "Intensity Minutes"), "Effort", "min", "xiaomi-band", "figure.run", 0, true),
        d("stress", String(localized: "Stress"), "Health", "/100", "xiaomi-band", "gauge.with.dots.needle.50percent", 0, false),
    ]

    static func inCategory(_ c: String) -> [MetricDescriptor] { all.filter { $0.category == c } }

    /// Localized display name for a catalog category, mapped AT THE RENDER SITE only. The
    /// catalog's `category` VALUES stay English identifiers on purpose (`inCategory` and the
    /// colour-world / gradient switches compare them raw), so screens must never feed this
    /// function's output back into matching logic. Unknown values pass through untranslated.
    static func categoryDisplayName(_ category: String) -> String {
        switch category {
        case "Heart":     return String(localized: "Heart")
        case "Charge":    return String(localized: "Charge")
        case "Rest":      return String(localized: "Rest")
        case "Effort":    return String(localized: "Effort")
        case "Health":    return String(localized: "Health")
        case "Nutrition": return String(localized: "Nutrition")
        case "Mind":      return String(localized: "Mind")
        default:          return category
        }
    }

    private static func d(_ key: String, _ title: String, _ category: String, _ unit: String,
                          _ source: String, _ icon: String, _ decimals: Int,
                          _ higherIsBetter: Bool?, _ description: String? = nil,
                          scale: Double = 1) -> MetricDescriptor {
        MetricDescriptor(key: key, title: title, category: category, unit: unit,
                         source: source, icon: icon, decimals: decimals, higherIsBetter: higherIsBetter,
                         description: description, displayScale: scale)
    }
}
