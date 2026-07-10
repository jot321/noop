# Advanced Analytics Plan — Deeper Signal from the Raw Data

**Status:** IMPLEMENTED — all four engines built, unit-tested (25 golden/behaviour tests), and wired into
`IntelligenceEngine.analyzeRecent` as a purely-additive second pass that persists to `metricSeries` and
fills `dailyMetric.spo2Pct` only where nil (never overwriting an import). Surfaced in a new
"Overnight analytics" card on the Sleep screen (`Strand/Screens/SleepAnalyticsCard.swift`); measured SpO₂
also flows into the existing blood-oxygen tile. Calibration (raw ADC → real units) remains the seed-curve
follow-up as noted below — the numbers ship labelled APPROXIMATE / non-clinical until validated.

- **`SpO2Engine` / `ApneaScreener`** (`Packages/StrandAnalytics/.../`): ratio-of-ratios SpO₂ with
  perfusion gating + asleep-epoch restriction; nightly mean/min/T90/ODI; fused AHI band. WHOOP-4.0 /
  Oura-BLE only (5-MG banks no raw red/IR), so on a 5/MG these rows self-hide — no fabricated numbers.
- **`HRVByStage`**: wires the existing `HRVAnalyzer`/`HRVFreqDomain` math to the stager's stage windows
  (per-stage RMSSD, whole-night LF/HF, nocturnal rolling RMSSD).
- **`ThermoCurveEngine`**: nightly skin-temp curve (nadir time, amplitude, rise/pre-wake slope) via the
  existing device-family ADC→°C map.
- **`PostureEngine`**: supine/prone/left/right from the gravity vector, supine-fraction (positional-apnea),
  restlessness/actigraphy + position-change count.

**metricSeries keys written:** `spo2_mean`, `spo2_min`, `odi`, `t90`, `ahi_est`, `hrv_lfhf`,
`hrv_rmssd_{deep,rem,light,wake}`, `temp_amplitude`, `temp_nadir_frac`, `temp_prewake_slope`,
`supine_frac`, `restless_frac`, `position_changes`.

**Decision on record:** build all four workstreams; recommended sequence below.

The on-device pipeline is already deep (recovery, strain, sleep staging, time- *and* frequency-domain
HRV, Baevsky stress, illness early-warning, cycle phase — all in
`Packages/StrandAnalytics/Sources/StrandAnalytics/`). But three raw streams are stored and barely
used. Everything below stays on-device, pure-function, clearly labelled **approximate / non-clinical**,
consistent with the existing engines.

Recommended order: **1 → 2 → 4 → 3** (SpO2 unlocks the most and ties into the others; autonomic is
mostly wiring existing math; thermo enriches existing engines; posture is the most net-new signal).

---

## 1. SpO2 + sleep-apnea screening — *biggest differentiation*

**Today:** `spo2Sample` stores raw red/IR optical ADC at ~1 Hz, but `DailyMetric.spo2Pct` is
**hard-coded `nil`** for measured WHOOP data (`AnalyticsEngine.swift:600`). There is *no* pulse-oximetry
algorithm; `Spo2ReTrace.swift` only reverse-engineers trace dumps. SpO2 % currently exists only via
imported Apple Health / Oura data. **This is pure untapped raw signal.**

**Build — `SpO2Engine.swift`:**
- Ratio-of-ratios: `R = (AC_red/DC_red) / (AC_ir/DC_ir)` per short window; map `R → SpO2` with a
  calibration curve (seed with the empirical `SpO2 ≈ 110 − 25·R`, then refine).
- Signal conditioning: perfusion-index gating, motion rejection using `gravitySample`, compute only
  during still/asleep epochs (reuse `SleepStager` epoch labels).
- **Calibrate + validate** against the Apple Health SpO2 the app already imports (Bland–Altman
  agreement reported internally) so the curve is trustworthy before it ships.

**Build — `ApneaScreener.swift`:**
- Nocturnal outputs: SpO2 median/min, **T90** (time below 90%), **ODI** (oxygen desaturation index —
  desaturations ≥3%/hour).
- Apnea proxy: fuse ODI + HR-surge microarousals (from `rrInterval`) + movement bursts →
  an estimated **AHI band** and a "consider screening" flag (explicitly non-diagnostic).

**Persist:** fill `dailyMetric.spo2Pct` (column already exists), add `metricSeries` keys
`odi`, `t90`, `ahi_est`. **UI:** nocturnal SpO2 chart + desaturation timeline on Sleep; apnea-screening
card in Health/Insights.

## 2. Deeper HRV / autonomic — *mostly wiring existing math to the UI*

**Today:** `HRVFreqDomain.swift` (Lomb–Scargle LF/HF/LF:HF), `RhythmScreener.swift` (Poincaré SD1/SD2),
`StressIndex.swift` (Baevsky SI), and `HRVAnalyzer.rollingRmssd:227` all exist but are labelled
"additive" with 2–4 references — computed, not surfaced. Nightly recovery collapses rich beat-to-beat
`rrInterval` data to a single RMSSD number.

**Build:**
- **Sleep-stage-resolved HRV** (`HRVByStage`): RMSSD / LF / HF per deep / REM / light, using existing
  `SleepStager` epochs + `rrInterval` — shows parasympathetic drive by stage.
- **Autonomic-balance timeline:** nightly LF/HF trend fused with the wired intraday `DaytimeStress`
  into one "autonomic" lane.
- **Nocturnal HRV curve:** surface `rollingRmssd` as the through-the-night dip-and-rise; expose both
  "last slow-wave" and "whole-night" HRV (the well-known scoring choice).
- **Poincaré view:** SD1/SD2 ellipse as a first-class HRV detail.

**Persist:** per-stage HRV + LF/HF to `metricSeries`. **UI:** HRV detail screen with
time / frequency / nonlinear tabs; an "autonomic balance" card.

## 3. Accelerometer richness — *most net-new signal*

**Today:** `gravitySample` stores 1 Hz x/y/z, but it's reduced to an L2 stillness scalar
(`SleepStager.gravityDeltas:282`); the `activityClass` byte is lightly used.

**Build:**
- **Sleep position / posture** (`PostureEngine`): from the gravity-vector orientation (supine / prone /
  left / right) during sleep → position-time breakdown, and **positional-apnea correlation** (supine
  worsens apnea — ties directly into #1).
- **Actigraphy** (`ActigraphyEngine`): proper wrist-actigraphy counts (Cole–Kripke is already used for
  in-bed detection) exposed as restlessness + a tossing/turning count.
- **Activity-type classification:** 3-axis features (not just magnitude) to separate
  walk / run / cycle / strength beyond the coarse `activityClass` byte — improves auto-workout detection.

**Persist:** position segments + restlessness in `metricSeries`. **UI:** sleep-position ring on Sleep
detail; restlessness in the sleep-score breakdown.

## 4. Thermoregulation / circadian — *enriches existing engines*

**Today:** `skinTempSample` raw ADC at 1 Hz → only a nightly **mean → deviation** scalar feeds Charge
(`RecoveryScorer`), illness (`IllnessSignalEngine`), and cycle phase (`CyclePhaseEngine`). The *shape*
of the curve is discarded.

**Build — `ThermoCurveEngine`:**
- Calibrate raw ADC → °C, then model the **nightly curve** (nocturnal rise / plateau / pre-wake drop —
  a proxy for the circadian core-temperature rhythm). Extract nadir time, amplitude, slope.
- **Circadian phase / misalignment:** nadir timing → circadian phase + "social jetlag" when it drifts
  from sleep timing.
- **Illness lead-time:** curve-shape shifts precede fever — augment `IllnessSignalEngine` (already uses
  temp deviation) with curve features.
- **Cycle tracking:** enrich `CyclePhaseEngine` with curve amplitude (luteal phase raises nocturnal temp).

**Persist:** curve features to `metricSeries`. **UI:** nightly temperature-curve chart; circadian-phase card.

---

## Cross-cutting

- **Calibration is the risk.** Raw ADC → physical units (SpO2 %, °C) needs per-sensor calibration;
  validate against imported Apple Health / Oura where available before surfacing numbers.
- **Non-clinical framing** throughout, matching existing "APPROXIMATE / non-clinical" labels.
- **Storage impact:** these produce new *derived* series. Daily-grain keys are tiny, but any
  **intraday** derived series (e.g. per-minute SpO2) adds volume — coordinate with
  [CLOUD_SYNC_PLAN.md](CLOUD_SYNC_PLAN.md) (offload + downsample) so new analytics don't reintroduce
  the device-fill problem.
- **Testing:** golden-vector tests per engine (the codebase already does this for HRV/sleep), plus
  agreement checks against reference sources for the calibrated metrics.
