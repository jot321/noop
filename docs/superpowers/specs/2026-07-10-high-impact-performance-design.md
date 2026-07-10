# High-Impact Performance and Power Design

## Status

Approved in conversation on 2026-07-10. This design implements the high-impact core of
`docs/PERFORMANCE_ANALYSIS.md`: U1-U5 and P1-P4.

## Baseline and Rollback

- Source base: `1e49b86` (`Add performance and power analysis report`).
- Known-good remote tag: `performance-baseline-2026-07-10`.
- Implementation branch: `agent/high-impact-performance`.
- Isolated worktree: `/Users/jotsarup/Desktop/experiments/noop-performance-worktree`.
- The existing `agent/local-iphone-setup` branch and its installed-app configuration remain
  untouched.

Implementation is split into separate commits for documentation, UI observation/log rendering,
persistence hot paths, BLE/realtime policy, and Live Activity cadence. The whole effort can be
rolled back to the baseline tag; individual subsystems can be reverted by commit.

## Objective

Reduce avoidable main-actor work, SwiftUI invalidations, defaults serialization, BLE scanning, raw
stream airtime, and passive Live Activity updates without reducing background HR/R-R collection,
workout durability, WHOOP reconnect reliability, historical offload, or current user-visible
features.

## Scope

### Included

- U1: isolate high-frequency `LiveState` and `AppModel` publications from the Live screen root.
- U2: render a stable, lazy, bounded log tail while retaining the full exportable log.
- U3: make active-workout aggregation O(1) per sample and coalesce durable snapshots.
- U4: coalesce persisted strap-log tails with explicit flush boundaries.
- U5: consume each R-R packet once and coalesce non-critical stress state persistence.
- P1: redirect cold-launch scans when a persisted peripheral UUID arrives after scanning starts.
- P2/P3: separate realtime ownership and WHOOP4 heavy-stream demand from passive capture.
- P4: adapt Live Activity cadence to active versus passive use.
- Correct material overstatements in `docs/PERFORMANCE_ANALYSIS.md` as implementation evidence is
  added.

### Excluded

- Liquid animation scheduling, classic Today rendering, pull-to-refresh, BreathingView, Oura power
  behavior, HealthKit catch-up, repository history-window reduction, widget/watch deep-history
  reads, and other U6-U10/P5-P8 items.
- WHOOP protocol decoding changes, including historical v20/v21 mapping.
- Changes to scoring, sleep staging, strain formulas, database schema, or user-visible metric values.
- A broad split of `LiveState` or `AppModel` into new global observable-object hierarchies.

## Audit Corrections

The imported report correctly identifies the hot paths, but implementation follows these verified
corrections:

- Source inspection proves root-body invalidation risk, not a guaranteed complete layout/render for
  every packet. SwiftUI may coalesce and diff invalidations.
- `UserDefaults.set` repeats serialization and defaults-domain mutation; it does not prove a physical
  plist write for every call.
- The peripheral UUID is already persisted. P1 is a startup-order race: the saved UUID can arrive
  after an ordinary reconnect scan has started, and applying the pin does not redirect that scan.
- WHOOP5/MG rejects the WHOOP4 R10/R11 command and relies on its puffin realtime toggle. Background
  teardown must therefore be device-family- and owner-aware.
- Live Activity has a two-second minimum interval but no two-second timer. The 43,000 updates/day
  figure is an unmeasured worst-case estimate and will not be presented as observed behavior.

## Design

### 1. Live Screen Observation Boundary

Introduce an equatable low-frequency `LiveScreenSnapshot` containing only root layout inputs:
connection/bond state, reconnect and pairing banners, standard-HR mode, active-workout presence, and
active device name. A small observation host reads the environment objects and passes this snapshot
to equatable content. High-frequency HR, R-R, frame, log, and workout-sample values remain in leaf
views that already need them.

Move the full active-workout/session card behind its own `AppModel`-observing leaf. Pass `AppModel`,
`LiveState`, and `NavRouter` as plain references where they are used only for actions or sheet
environment injection. Keep the current Live screen lifecycle modifiers structurally attached once:
appear acquires the screen realtime owner, connection edges rearm without acquiring again, and
disappear releases exactly once. The workout sheet retains its independent realtime owner.

### 2. Stable Bounded Live Log

Keep the existing 5,000-string in-memory log and full `exportableLogText()` behavior. Track a
monotonic sequence for appended lines and project the newest 200 rows as stable-ID values. Render
those rows with `LazyVStack`. Autoscroll follows the newest row ID, which continues advancing after
the source ring reaches its fixed count.

Copy and Save continue to export the full retained log, not only the visible tail. The first patch
does not throttle visual log delivery; it removes eager materialization and unstable identity while
preserving immediate diagnostics.

### 3. Active Workout Accumulation and Persistence

Deduplicate workout samples by epoch second so HR and R-R publications from one BLE notification
cannot append the same reading twice. Maintain sample count, BPM sum, and peak BPM as an accumulator,
seeded from a restored workout. Average and peak become O(1) per accepted sample. Recompute live
strain no more than once every 10 seconds and always at workout end.

Replace per-sample snapshot writes with a serial, generation-aware persistence coordinator:

- Persist immediately on workout start.
- Coalesce normal snapshots to at most once every 15 seconds.
- Encode the snapshot away from the main actor.
- Commit encoded data only if its workout generation is still current.
- Force the latest snapshot on app background, BLE disconnect, and best-effort termination.
- On end, invalidate pending writes before clearing the key so delayed work cannot resurrect a
  completed workout.

The maximum ungraceful-kill exposure during foreground execution is the latest 15 seconds. The iOS
background transition is the required durability boundary because termination callbacks are not
guaranteed after suspension.

### 4. Log-Tail Persistence

Preserve redaction, domain tags, ordering, and the 2,000-line persisted cap. `append` marks the tail
dirty and a trailing throttle writes at most once every five seconds. This is a maximum-delay
throttle rather than pure debounce, so continuous logging cannot starve persistence.

Expose an explicit flush used by app background, BLE disconnect, best-effort termination, and
scheduled debug export before it reads the persisted tail. A clean flush is a no-op.

### 5. Stress Evaluation and Persistence

Split heart-rate and R-R ingestion responsibilities. Workout capture consumes deduplicated HR;
stress evaluation consumes each new R-R packet exactly once and never reuses the previous packet in
response to an HR-only publication.

Keep the detector state in memory. Persist replay-safety transitions immediately when `wasBelow` or
`lastFireAt` changes, and commit `lastFireAt` before posting the nudge side effect. Coalesce
baseline-only EMA changes to a 60-second maximum delay, with background/disconnect flushes. Disabled
mode performs no state writes.

### 6. Reconnect Race

Retain the existing peripheral UUID adoption and `DeviceRegistry` persistence. When a saved UUID is
applied while an ordinary system reconnect scan is active:

1. Cancel the family fallback work item and stop the scan.
2. Retrieve the known peripheral by UUID.
3. Use the existing targeted CoreBluetooth connect path.

Do not redirect user-initiated presentation scans or CoreBluetooth state restoration. Preserve
first-time pairing with no UUID, stale-family recovery, multi-WHOOP active-device filtering,
failed-connect backoff, bond-loop pause behavior, and characteristic discovery for both supported
WHOOP families after targeted connection.

### 7. Explicit Realtime Ownership

Replace the undifferentiated realtime ref-count with explicit owners:

- foreground Live screen
- active workout view/session
- `LiveSessionRunner`
- passive continuous-HRV capture

Track app foreground state separately from screen visibility. Backgrounding suppresses only the
foreground Live-screen owner; active workout, live session, and passive continuous capture retain
their intended data paths.

Derive two command demands through a pure policy:

- Toggle demand: any active owner, window-gated for passive continuous capture.
- WHOOP4 heavy R10/R11 demand: foreground Live screen, active workout, or live session only.

Apply the policy consistently at owner changes, post-bond setup, keep-alive, foreground/background
transitions, and disconnect reset. Passive continuous capture never implies WHOOP4 R10/R11.
WHOOP5/MG retains its puffin toggle for workout/session/background capture because it has no R10/R11
implementation. Standard 0x2A37 notification subscription, persistence, historical offload, and the
BLE connection itself continue in background.

### 8. Adaptive Live Activity Cadence

Extract a fake-clock-testable cadence policy:

- Start immediately when enabled, connected, and a valid HR is available.
- While a Live screen, workout, or live session is active: minimum two-second update interval.
- During passive connected wear: minimum 30-second update interval.
- Disconnect and opt-out end the activity immediately, bypassing update throttles.

Move gating before expensive anchor construction where practical so dropped passive HR events do not
perform unnecessary dashboard scans. Preserve diff/change gating from the HR publishers.

## Error Handling and Safety

- Delayed persistence work is generation checked and cancelable.
- Flush APIs are idempotent and safe when no workout/log/stress state is dirty.
- Reconnect redirection is limited to ordinary automatic scans with a valid saved UUID.
- Realtime policy is pure and total across device family, scene state, ownership, continuous-capture
  window, and marginal-radio fallback inputs.
- No optimization disconnects BLE, disables standard HR/R-R notifications, or stops historical
  offload merely because the app backgrounds.

## Testing Strategy

Add pure or fake-clock tests for:

- `LiveScreenSnapshot` low-frequency equality behavior.
- Log projection cap, stable IDs after front trimming, newest-ID autoscroll trigger, and full export.
- Workout per-second deduplication, restored accumulator seeding, running average/peak, strain cadence,
  persistence throttle, lifecycle flush, and end-generation race.
- Log-tail throttle, maximum delay, cap/redaction, lifecycle/export flush, and clean no-op.
- Stress one-packet consumption, immediate edge persistence, delayed baseline persistence, replay
  prevention, and lifecycle flush.
- Reconnect planning for late UUID, no UUID, stale family, multi-device filtering, presentation scan,
  and restoration precedence.
- WHOOP4/WHOOP5 command demand across all owners, scene transitions, continuous-HRV window edges,
  post-bond, keep-alive, and disconnect.
- Live Activity active/passive fake-clock cadence and immediate end behavior.

Verification order:

1. Run each new test red before production implementation and green afterward.
2. Run touched package suites.
3. Run full `StrandTests` and compare with the recorded baseline.
4. Build macOS and a signed generic iOS app/widget.
5. When the phone is available, install and verify Live HR, background workout capture, overnight
   continuous HRV, reconnect after the strap is unavailable, and passive Live Activity cadence.

## Recorded Baseline Test Exception

Before source changes, the full macOS suite executed 801 tests: 798 passed, one fixture-dependent
Xiaomi test skipped, and two `TodayExplainabilityTests` failed. Both failures compare the internal
`LocalizedStringKey` representation of interpolated strings under the installed Xcode toolchain:

- `testScoreState_carryWithinCap_isFreshLastNight`
- `testScoreState_staleCarry_relabelsLatestSleep`

These failures are unrelated to U1-U5/P1-P4 and are present at the rollback tag. This effort must
introduce no additional failures. Repairing those pre-existing localization assertions is a separate
scope decision.

## Success Criteria

- Live root snapshots do not change for HR, R-R, frame, log, or in-workout sample-only updates.
- The visible log creates at most 200 lazy rows with stable identities while exports retain 5,000.
- Workout defaults encoding no longer occurs per packet; durability boundaries force current state.
- Log and stress baseline persistence are bounded and coalesced with immediate safety edges.
- A late saved UUID redirects automatic scan rotation to targeted connection.
- WHOOP4 passive continuous capture does not arm R10/R11; active Live/workout/session behavior remains.
- WHOOP5 live/workout/background toggle behavior remains intact.
- Passive Live Activity updates are no more frequent than every 30 seconds.
- No new test failures, successful macOS and signed generic iOS builds, and documented on-device
  validation status.
