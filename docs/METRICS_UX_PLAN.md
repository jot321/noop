# Metrics & Experience Plan — Surface What We Compute, Add What Matters, Explain the Numbers

**Status:** IMPLEMENTED (2026-07-12). All four workstreams landed; macOS build green, StrandAnalytics
1015 tests pass (+17 new for ACWR + DFA-α1). WS-4e was already fully built in `InsightsHubView` —
no new code needed there.
**Scope:** on-device analytics + UI. Everything here stays on-device, pure-function, clearly labelled
**approximate / non-clinical**, consistent with the existing engines in
`Packages/StrandAnalytics/Sources/StrandAnalytics/`.
**Sibling docs:** [`ADVANCED_ANALYTICS_PLAN.md`](ADVANCED_ANALYTICS_PLAN.md) (the four raw-signal engines),
[`ANALYTICS.md`](ANALYTICS.md), [`WHOOP5_DEEP_DATA.md`](WHOOP5_DEEP_DATA.md) (the R22 unlock).

## Why this plan

Four user observations kicked this off:

1. **Vitality** shows a single number, no timeline.
2. **Effort** of 3 on a car-travel day "seems too low."
3. **Rest** jumped 60→80 after enabling R22, and a 3–4 h night still scores ~60.
4. **Charge** "field hasn't come yet."

Tracing each through the engines showed the scores are *correct*, but the product doesn't **explain** or
**trend** them, and — the biggest finding — **a whole tier of computed signals is shown only as
point-in-time numbers, with no history or baseline context**.

### The headline gap: computed but not trendable

Cross-checking every `metricSeries` key the engines persist against `MetricCatalog` (what the UI can
chart) reveals a whole tier of signals that today appear only as **single-value rows** — mostly on
`SleepAnalyticsCard` (`Strand/Screens/SleepAnalyticsCard.swift:82`), plus the live HRR card in
`WorkoutDetailView` — with no history, no trend, no baseline context:

| Computed & persisted | Shown today | Trendable in UI today? | What it tells you |
|---|---|---|---|
| `hrr60` / `hrr120` (heart-rate recovery) | Per-workout card only | No | One of the strongest longitudinal cardio-fitness markers |
| `nocturnal_dip` | Single-value row | No | Blunted dip is a cardiovascular-risk flag |
| `hrv_lfhf` (autonomic balance) + per-stage RMSSD | Single-value rows | No | Sympathetic/parasympathetic balance |
| `sleep_hr_trough` / `sleep_hr_trough_frac` | Single-value rows | No | The "HR hammock" — did you recover overnight |
| `sleep_hr_prewake_rise` / `sleep_hr_amplitude` | **Not shown at all** | No | Pre-wake arousal, overnight HR range |
| `temp_amplitude` / `temp_nadir_frac` | Single-value rows | No | Circadian phase, illness lead-time, cycle |
| `temp_prewake_slope` | **Not shown at all** | No | Circadian phase marker |
| `odi` / `ahi_est` (apnea screen) | Single-value rows | No | Sleep-apnea risk band |
| `t90` | **Not shown at all** | No | Time below 90% SpO2 |
| `supine_frac` / `restless_frac` / `position_changes` | Single-value rows | No | Sleep posture / restlessness |

So the math is built, unit-tested, and running, and most outputs *are* rendered — but as naked
point-in-time numbers. **None of these keys exist in `MetricCatalog`** (46 keys today, none of the
advanced tier), so none can be charted, trended, or read against a personal baseline — which is exactly
the interpretive frame the research section below says these signals need. The gap is not "surface for
the first time"; it is "promote from single-value rows to first-class trendable metrics." That framing
matters for scoping: WS-2 is catalog + detail-sheet routing work, not new card-building.

---

## Workstreams

### WS-1 — Universal metric-detail sheet + baseline bands  *(foundation; highest ROrI)*

**Problem:** several metrics render only `.last?.value` (e.g. Vitality hero,
`HealthView.swift:1113`). There is no shared "tap a score → see its history" surface. Fixing Vitality's
missing timeline in isolation would leave the same gap on every other metric.

**Build:**
- One reusable metric-detail sheet: **sparkline + 30/90-day chart + the personal baseline band +
  a "what's driving this" breakdown**. Tap any score / tile / hero to open it.
- **Baseline bands on every chart** — shade the personal normal range (from the existing `Baselines`
  engine) so a reading reads as *inside / outside your normal*, not a naked number. This is the single
  change that best matches how the research says this data should be interpreted (trend vs. personal
  baseline, never a population cutoff).
- Reuse the existing trace engines (`RestSubScoreTrace`, `RecoveryScorer+Trace`, `HRVAnalyzer+Trace`,
  `StepsEstimateEngine+Trace`, `DisplayTrace`) as the "what drove this" content — they already compute
  the breakdown.

**Why first:** it simultaneously fixes the Vitality-timeline complaint (#1) *and* unlocks every buried
metric in WS-2, and gives the "why this number" affordance that answers the trust questions behind all
four original observations.

**Touch points:** `Strand/Screens/HealthView.swift`, `Strand/Screens/MetricExplorerView.swift`,
`Strand/Data/MetricCatalog.swift`, `Strand/Liquid/LiquidTodayView.swift`.

---

### WS-2 — Make the already-computed metrics trendable  *(no new algorithms)*

Add `MetricCatalog` entries + route them through the WS-1 detail sheet for the keys the engines already
write but the UI shows only as single-value rows (or not at all — see the table above):

- **Heart-rate recovery** — `hrr60`, `hrr120` (`HRRecoveryEngine`). Present as a cardio-fitness trend.
- **Nocturnal HR dip** — `nocturnal_dip` (`SleepHRCurveEngine`). Flag a blunted dip against baseline.
- **Overnight HR curve** — `sleep_hr_trough`, `sleep_hr_trough_frac`, `sleep_hr_prewake_rise`,
  `sleep_hr_amplitude` as an "HR hammock" chart on Sleep detail.
- **Autonomic balance** — `hrv_lfhf` (`HRVFreqDomain`) + per-stage RMSSD (`HRVByStage`) as an HRV detail
  screen with time / frequency / nonlinear tabs.
- **Thermoregulation / circadian** — `temp_amplitude`, `temp_nadir_frac`, `temp_prewake_slope`
  (`ThermoCurveEngine`) as a nightly temperature-curve chart + circadian-phase card.
- **Apnea screen** — `odi`, `t90`, `ahi_est` (`ApneaScreener`) as a non-diagnostic "consider screening"
  card (already partly on the Sleep analytics card — promote to first-class + trend). **Note:** this
  reverses an earlier explicit decision to defer apnea UI (HR-trajectory batch, 2026-07-11); revisit
  deliberately now that the screener has accumulated nightly data, rather than treating it as
  uncontroversial.
- **Sleep posture / restlessness** — `supine_frac`, `restless_frac`, `position_changes` on Sleep detail.

**Constraint:** self-hide rows the current device can't produce (e.g. SpO2/apnea on a 5/MG that banks no
raw red/IR) — never fabricate a number. This matches the existing "these rows self-hide" behaviour.

---

### WS-3 — The three approved trust/timeline fixes

1. **Vitality history backfill + trend chart.**
   - Backfill: `IntelligenceEngine.analyzeRecent` (`Strand/Data/IntelligenceEngine.swift`, Vitality
     upsert ~line 1120) computes Vitality only for the current week's Saturday from the trailing
     7 days — even the full-history pass (`analyzeFullHistory`) writes just that one Saturday key.
     Stored dailies go back far enough to compute a Vitality point for every historical Saturday (or a
     daily rolling value). Make the upsert loop over historical weeks, idempotent on the Saturday key.
     Note `VitalityEngine.compute` gates on ≥3 inputs, so sparse historical weeks will legitimately
     produce no point — the chart must render gaps, not interpolate across them.
   - Chart: render the backfilled series through the WS-1 detail sheet (replaces the `.last?.value`
     hero-only read at `HealthView.swift:1113`).
2. **Low-Effort explainer.** For low `strain` days, show zone-minutes and HR coverage
   ("we saw 14 h of HR, 0 min above 50% HRR") so a low score reads as *verified calm* rather than
   *possibly missing data*. Data source: `StrainScorer` TRIMP internals + the day's HR sample span.
3. **Charge calibration progress after R22.** Verify `RecoveryScorer.calibrationNights` "N of 4" progress
   actually renders on the Charge ring (`LiquidTodayView.swift:590` shows only "Solid"/"Calibrating" — no
   count). Add the count, and a note like *"HRV unlocked 2 days ago — 2 more nights to your first
   Charge."* Since HRV needs the R22 R-R stream, the calibration clock only starts at R22 enable.

---

### WS-4 — Net-new engines *(research-backed, differentiating)*

Ordered by ROI. All pure, DB-free, unit-tested, labelled approximate/non-clinical.

1. **HRV trend vs. personal baseline** *(presentation of existing data — do first).*
   7-day rolling RMSSD vs. the 60-day personal baseline: within ~10% normal, a sustained 15–20% drop for
   a week flags accumulated stress / oncoming illness. Uses the existing `Baselines` engine + nightly
   RMSSD. Makes Charge legible ("your HRV is 12% below your normal band").
2. **Resting-HR trend headline.** RHR is an independent predictor of cardiovascular and all-cause
   mortality. Promote the existing `rhr` series from a supporting tile to a 90-day trend-with-baseline
   headline via WS-1.
3. **Acute-to-chronic load ratio (ACWR)** on Effort. 7-day ÷ 28-day `strain`; band it
   (ramping too fast > ~1.5 / balanced / detraining). Turns Effort history into forward-looking guidance.
4. **DFA-α1 aerobic-threshold estimate** *(the standout feature; WHOOP itself doesn't expose it).*
   Short-term detrended-fluctuation exponent of the R-R stream: crosses ~0.75 at the aerobic (first
   ventilatory) threshold, ~0.5 at the anaerobic threshold — lab-free training zones from HRV. Natural
   sibling to `HRVFreqDomain` (already doing Lomb–Scargle on R-R). New engine `DFAAlpha1Engine`.
   **Feasibility caveat:** unlike the other items this is *not* pure math on data we already trust.
   DFA-α1 needs clean R-R **during exercise**, and wrist-PPG beat detection under high motion is
   heavily artifact-laden (published DFA-α1 tooling assumes chest straps). The store can serve R-R for
   any window (`WhoopStore.rrIntervals`), but the engine must gate on artifact fraction — discard any
   analysis window where more than ~5% of beats needed correction — and the feature should be expected
   to self-hide on many workout types, working mainly for steady low-motion cardio (cycling, easy
   runs). Validate against a chest strap before promoting the output beyond an "experimental" label.
5. **Lifestyle correlates via `DoseResponseEngine` + journal.** Surface personalized links like
   "your HRV runs ~15% lower the day after you log alcohol." Scaffolding already exists; this is wiring +
   a card.

---

## UI changes (cross-cutting)

1. **Universal metric-detail sheet** (WS-1) — the backbone; tap any number for its story.
2. **Baseline bands on every chart** — shaded personal-normal range, so readings read as in/out of normal.
3. **"Why this number" on every score** — expand Charge/Effort/Rest/Vitality to show their trace-driven
   breakdown.
4. **Calibration/onboarding status strip** — a persistent "what's still warming up" indicator (R22,
   sleep, Charge all have "N of 4"-style gates), to prevent "field hasn't come / is it broken?" confusion.
5. **Annotated timeline** — mark events (R22 enabled, strap switched, recalibrated) on trend charts so
   step-changes (e.g. the 60→80 Rest jump) are explained in place rather than looking like drift.

---

## Recommended sequence

1. **WS-1** — universal metric-detail sheet + baseline bands. Unlocks the Vitality timeline *and* every
   buried metric; delivers the "why this number" affordance.
2. **WS-2** — make the already-computed HRR / nocturnal-dip / HRV-balance / HR-curve / thermo /
   apnea / posture keys trendable via the catalog. No new math, near-zero risk.
3. **WS-3** — the three approved fixes (Vitality backfill+chart, low-Effort explainer, Charge "N of 4").
4. **WS-4** — net-new engines, in the order listed (HRV-vs-baseline → RHR headline → ACWR → DFA-α1 →
   lifestyle correlates).

---

## Research basis

The 2025–2026 literature converges on a few points that shape the framing above:

- **Trends vs. a personal baseline, never population cutoffs.** Single days are noise; the 7-day rolling
  average vs. a 60-day personal baseline is the signal (within ~10% normal; sustained 15–20% drop = stress
  / overreach).
  [athletedata.health HRV guide](https://www.athletedata.health/guides/hrv-guided-training) ·
  [smartphone HRV / training-load study](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7795557/)
- **Nocturnal beats spot readings.** Nocturnal HR/HRV segments are more sensitive to training load and
  recovery than morning/pre-test readings.
  [Morning vs. nocturnal HRV, Sports Medicine Open 2024](https://link.springer.com/article/10.1186/s40798-024-00779-5)
- **RHR & HRV are independent mortality predictors**, and WHOOP-class straps show *acceptable* nocturnal
  agreement vs. ECG.
  [Consumer-wearable validation, Physiological Reports 2025](https://physoc.onlinelibrary.wiley.com/doi/10.14814/phy2.70527) ·
  [Nocturnal validation, PMC12367097](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC12367097/)
- **Resting HRV associates with broad health domains** (average blood glucose, depressive symptoms, sleep
  difficulty; within-person: work recovery, prior-day alcohol).
  [Five-study longitudinal analysis, Sensors 2025](https://pmc.ncbi.nlm.nih.gov/articles/PMC12693838/)
- **ACWR:** injury risk rises 2–4× the following week when the acute-to-chronic workload ratio exceeds
  ~1.5.
  [Training-load monitoring review, PMC6409702](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6409702/)
- **DFA-α1:** drops below ~0.75 at the aerobic threshold and ~0.5 at the anaerobic threshold — a lab-free
  HRV-based training-zone estimate.
  [Rogers et al., Frontiers 2021](https://www.frontiersin.org/journals/sports-and-active-living/articles/10.3389/fspor.2021.668812/full) ·
  [Threshold-detection method, PMC7845545](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7845545/)

> Not medical advice. Every metric here is a wellness estimate against the user's own baseline, on-device,
> labelled approximate / non-clinical — consistent with the existing engines.
