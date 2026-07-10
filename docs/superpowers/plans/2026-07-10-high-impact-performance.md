# High-Impact Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the approved U1-U5 and P1-P4 performance/power changes without changing decoded metrics, scoring, background history offload, or user-visible workout behavior.

**Architecture:** Put pure, testable policy/state helpers at the hot-path boundaries, then keep the existing SwiftUI, `AppModel`, and `BLEManager` ownership structure. High-frequency values stay in leaf views; durability uses bounded coalescing plus explicit lifecycle flushes; BLE command demand is derived from idempotent owners rather than an integer ref-count.

**Tech Stack:** Swift 5, SwiftUI, Combine, CoreBluetooth, ActivityKit, XCTest, XcodeGen, `xcodebuild`.

**Approved design:** `docs/superpowers/specs/2026-07-10-high-impact-performance-design.md`

**Rollback point:** annotated tag `performance-baseline-2026-07-10` at `1e49b86`.

**Branch/worktree:** `agent/high-impact-performance` in `/Users/jotsarup/Desktop/experiments/noop-performance-worktree`.

**Baseline:** 801 macOS tests: 798 pass, one fixture skip, and the two accepted `TodayExplainabilityTests` localization-key failures documented in the design. Every verification below must add no failures.

---

## Task 1: Isolate Live Root Observation and Stabilize the Log

**Files:**
- Modify: `Strand/Screens/LiveView.swift`
- Modify: `Strand/BLE/LiveState.swift`
- Create: `StrandTests/LiveScreenSnapshotTests.swift`
- Create: `StrandTests/LiveLogProjectionTests.swift`

### Step 1: Write failing snapshot-boundary tests

Add `LiveScreenSnapshotTests` for an internal `Equatable` snapshot that contains only root-level, low-frequency values:

- connection, bond, and encrypted-bond state;
- reconnect/pairing guidance;
- standard-HR fallback message;
- active-workout presence and last-workout summary inputs;
- active device name and HR-max;
- any coarse sync badge value that remains at root.

Assert that equivalent snapshots compare equal and that root-visible state changes compare unequal. High-frequency HR, R-R, frame, and log values must not be snapshot fields.

Run:

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/LiveScreenSnapshotTests test
```

Expected: FAIL because `LiveScreenSnapshot` does not exist.

### Step 2: Write failing stable-log projection tests

Add `LiveLogProjectionTests` for `LiveState.VisibleLogLine` and the projection behavior:

- visible rows cap at 200;
- IDs increase monotonically;
- trimming the 5,000-line source does not reuse visible IDs;
- `newestVisibleLogID` changes for every append after either cap is reached;
- `exportableLogText()` still includes source lines outside the 200-row visible tail.

Run:

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/LiveLogProjectionTests test
```

Expected: FAIL because the visible projection does not exist.

### Step 3: Implement the projection

In `LiveState`:

- keep `log: [String]` and its 5,000-line behavior for existing diagnostics/export code;
- add an internal/public-read `VisibleLogLine: Identifiable, Equatable` with monotonic `UInt64` ID;
- publish `visibleLog`, capped at 200, and expose `newestVisibleLogID`;
- append the already-tagged/redacted line to both stores in the single `append(log:domain:)` sink.

Do not alter tagging, PII redaction, export headers, or test-domain filtering.

### Step 4: Implement the observation host

In `LiveView.swift`:

- make `LiveView` a small environment-observing host;
- create `LiveScreenSnapshot` from the coarse root values;
- pass plain `AppModel`, `LiveState`, and `NavRouter` references plus the snapshot into an equatable content view;
- move the active-workout card into its own `AppModel`-observing leaf so sample/stat changes do not change the root snapshot;
- move the backfill badge into a small `LiveState` leaf if retaining chunk-level progress would otherwise invalidate root content;
- keep HR/R-R/battery/frame/signal leaves observing the objects they actually need.

Attach `.onAppear`, `.onDisappear`, connection-edge rearm, workout sheet, HRV sheet, and navigation consumption exactly once. `onAppear` acquires the Live-screen owner; reconnect edges only rearm; `onDisappear` releases once.

### Step 5: Render the stable lazy tail

Replace `Array(live.log.enumerated())` + `VStack` with `LazyVStack` over `live.visibleLog`. Use each row's monotonic ID and scroll to `newestVisibleLogID`. Copy and Save continue calling `exportableLogText()`.

### Step 6: Run UI-focused and regression tests

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/LiveScreenSnapshotTests \
  -only-testing:StrandTests/LiveLogProjectionTests \
  -only-testing:StrandTests/LiveStateDomainTagTests test
```

Expected: PASS.

### Step 7: Commit the UI patch

```bash
git add Strand/Screens/LiveView.swift Strand/BLE/LiveState.swift \
  StrandTests/LiveScreenSnapshotTests.swift StrandTests/LiveLogProjectionTests.swift
git commit -m "Reduce Live screen render churn"
```

---

## Task 2: Coalesce Workout, Log, and Stress Persistence

**Files:**
- Modify: `Strand/App/ActiveWorkoutPersistence.swift`
- Modify: `Strand/App/AppModel.swift`
- Modify: `Strand/BLE/LiveState.swift`
- Modify: `Strand/Screens/BiofeedbackPrefs.swift`
- Modify: `Strand/System/ScheduledDebugExport.swift`
- Modify: `Strand/App/StrandApp.swift`
- Modify: `StrandiOS/App/StrandiOSApp.swift`
- Create: `Strand/App/ActiveWorkoutRuntime.swift`
- Create: `Strand/System/LogTailPersistence.swift`
- Create: `Strand/App/StressStatePersistence.swift`
- Modify: `StrandTests/ActiveWorkoutPersistenceTests.swift`
- Create: `StrandTests/ActiveWorkoutRuntimeTests.swift`
- Create: `StrandTests/LogTailPersistenceTests.swift`
- Create: `StrandTests/StressStatePersistenceTests.swift`

### Step 1: Write failing workout-runtime tests

Test a pure `ActiveWorkoutRuntime` seeded from zero or restored samples:

- accepts at most one sample per Unix second;
- keeps exact sample count, BPM sum, rounded average, and peak in O(1) state;
- restored samples seed the same values as a fresh run;
- requests strain immediately for the first accepted sample and no more than every 10 seconds afterward;
- forces final strain at workout end.

Test `ActiveWorkoutPersistenceCoordinator` with an isolated defaults suite and short/injected timing:

- start persists immediately;
- repeated updates coalesce to one trailing write per 15-second production interval;
- `flush` persists the newest snapshot;
- end cancels/invalidate pending work and clears after all prior queued writes;
- delayed encode/write work cannot recreate the key after end.

Run targeted tests and confirm RED.

### Step 2: Implement workout accumulation and durable writer

Add `ActiveWorkoutRuntime` with `sampleCount`, `bpmSum`, `peakBpm`, `lastSampleSecond`, and `lastStrainAt`. Seed it during rehydration and reset it on start/end.

Add a serial `ActiveWorkoutPersistenceCoordinator`:

- production snapshot interval: 15 seconds;
- delayed work captures a workout generation;
- JSON encoding and defaults mutation run on its serial background queue;
- start enqueues immediately;
- dirty updates schedule one trailing deadline;
- `flush` enqueues the newest snapshot now;
- `finishAndClear` invalidates delayed callbacks and enqueues clear after earlier writes.

Update `captureWorkoutSample()` to use per-second dedup, O(1) average/peak, and the 10-second strain gate. Recompute strain from the final samples in `endWorkout()` before saving the row.

### Step 3: Write failing log-tail persistence tests

Test a `LogTailPersistence` instance using an isolated defaults suite:

- append preserves ordering and caps at 2,000;
- continuous appends result in bounded writes at a five-second production cadence;
- trailing state is eventually written even when logging continues;
- explicit flush writes the latest line immediately;
- a clean flush performs no additional write;
- loading an existing persisted tail seeds subsequent appends.

Run targeted tests and confirm RED.

### Step 4: Implement incremental log-tail persistence

Move durable-tail mutation out of `LiveState.persistTail(_:)` into a serial `LogTailPersistence` writer that receives one already-redacted line per append. It owns the 2,000-line tail and performs at most one defaults-array write per five seconds, with a trailing deadline.

Expose `LiveState.flushPersistedLogTail()` for lifecycle/export boundaries. Make `persistedLogTail()` drain/flush pending work before returning so scheduled exports include the newest lines. Do not rebuild a 2,000-element suffix on each main-actor append.

### Step 5: Write failing stress ingestion/persistence tests

Test a small `StressStatePersistence` policy/coordinator:

- `wasBelow` and `lastFireAt` transitions persist immediately;
- baseline-only changes coalesce to a 60-second production deadline;
- flush commits the latest baseline;
- unchanged/disabled state writes nothing;
- immediate `lastFireAt` persistence occurs before the nudge callback in the AppModel seam.

Add an AppModel-adjacent pure packet-consumption test if needed to prove one R-R packet is appended once and an HR-only update does not replay it.

### Step 6: Split HR and R-R sinks and implement stress persistence

In `AppModel.init`:

- HR publications call HR smoothing/workout capture only;
- R-R publications call HR fallback smoothing/workout capture and `evaluateStress(rrPacket:)` exactly once;
- use `.dropFirst()` or an empty-packet guard so publisher attachment does not create work.

In `evaluateStress(rrPacket:)`, filter and append only the supplied packet. Keep the detector formulas and nudge gates unchanged. Persist replay-safety edges immediately before buzz/present side effects; route baseline-only changes through the 60-second coordinator.

### Step 7: Wire flush boundaries

Add one idempotent `AppModel.flushPerformanceState()` that flushes active workout, log tail, and stress state. Call it on:

- iOS/macOS background or inactive transition where available;
- explicit and observed BLE disconnect;
- best-effort app termination notification;
- scheduled debug export before reading the persisted log tail.

On workout end, call `finishAndClear` instead of directly clearing defaults.

### Step 8: Run persistence-focused tests

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/ActiveWorkoutPersistenceTests \
  -only-testing:StrandTests/ActiveWorkoutRuntimeTests \
  -only-testing:StrandTests/LogTailPersistenceTests \
  -only-testing:StrandTests/StressStatePersistenceTests test
```

Expected: PASS.

### Step 9: Commit the persistence patch

```bash
git add Strand/App Strand/BLE/LiveState.swift Strand/Screens/BiofeedbackPrefs.swift \
  Strand/System/LogTailPersistence.swift Strand/System/ScheduledDebugExport.swift \
  StrandiOS/App/StrandiOSApp.swift StrandTests
git commit -m "Coalesce hot-path state persistence"
```

---

## Task 3: Fix Late-Pin Reconnect and Derive Realtime Demand

**Files:**
- Modify: `Strand/BLE/BLEManager.swift`
- Modify: `Strand/App/AppModel.swift`
- Modify: `Strand/Screens/LiveView.swift`
- Modify: `Strand/Screens/LiveWorkoutView.swift`
- Modify: `Strand/App/LiveSessionRunner.swift`
- Modify: `Strand/MenuBar/MenuBarContent.swift`
- Modify: `StrandiOS/App/StrandiOSApp.swift`
- Create: `Strand/BLE/RealtimeDemandPolicy.swift`
- Create: `StrandTests/PreferredPeripheralRedirectTests.swift`
- Create: `StrandTests/RealtimeDemandPolicyTests.swift`

### Step 1: Write failing late-pin planning tests

Extract a pure redirect decision and test:

- a newly loaded valid UUID redirects an ordinary automatic scan;
- same/nil/invalid UUID does not redirect;
- presentation scans do not redirect;
- restoration takes precedence;
- connected or non-scanning states do not redirect;
- no retrieved target leaves the filtered scan/fallback path intact.

Run the new test and confirm RED.

### Step 2: Implement bounded scan redirection

In `setPreferredPeripheral(_:)`, after updating refusal/handoff state:

- only for a genuinely new valid pin during an ordinary automatic scan;
- skip `isPresentingScan`, restored-peripheral handling, connected state, and bond-loop-paused state;
- retrieve the known `CBPeripheral` by UUID;
- when retrieved, cancel family fallback, stop scan, prepare the peripheral, and use the existing `central.connect` path;
- when retrieval returns nothing, leave the current scan active so preferred filtering and family fallback continue.

Update the obsolete comment that says setting the pin never redirects a scan.

### Step 3: Write failing realtime-demand policy tests

Define owners `liveScreen`, `workout`, `liveSession`, and `manualControl`, plus passive continuous capture as a separate input. Test the pure output `(toggleWanted, heavyWhoop4Wanted)` across:

- WHOOP4 and WHOOP5/MG;
- foreground/background transitions;
- every owner independently and in combination;
- passive capture inside/outside its overnight window;
- marginal-radio fallback;
- disconnect/post-bond reset inputs.

Required assertions:

- background suppresses only `liveScreen`;
- workout and live session remain active in background;
- passive capture can request the toggle but never WHOOP4 R10/R11;
- WHOOP5 never requests R10/R11;
- WHOOP4 fallback suppresses R10/R11 without dropping toggle demand.

Run the new test and confirm RED.

### Step 4: Implement idempotent owners in AppModel

Replace `realtimeWanters` with a `Set<RealtimeDemandOwner>` and APIs:

```swift
func acquireRealtime(_ owner: RealtimeDemandOwner)
func releaseRealtime(_ owner: RealtimeDemandOwner)
func rearmRealtimeIfWanted()
func setAppForeground(_ foreground: Bool)
var hasActiveRealtimeExperience: Bool { get }
```

Set insertion/removal is idempotent, so duplicate appear/disappear events cannot leak a count. Map callers:

- `LiveView` -> `.liveScreen`;
- `LiveWorkoutView` -> `.workout`;
- `LiveSessionRunner` -> `.liveSession`;
- menu-bar manual toggle -> `.manualControl`.

Preserve the current stale-smoothing reset on the first active owner and reconnect rearm without acquiring a second owner.

### Step 5: Apply one BLE policy at every arm site

In `BLEManager`:

- store the explicit owner set and app foreground state;
- retain continuous-HRV preference/window state as the passive input;
- track toggle armed state separately from WHOOP4 heavy-stream armed state;
- reconcile both edges on owner, scene, preference, and overnight-window changes;
- use the same derived policy in `startRealtime` replacement, keep-alive, WHOOP4 post-bond, WHOOP5 post-bond, and disconnect reset;
- keep WHOOP4 heavy rearm out of passive-only capture;
- keep WHOOP5 puffin toggle armed for workout/session/passive capture where policy requests it;
- keep standard HR notification subscription, historical offload, and the BLE connection unchanged.

The 30-second keep-alive may re-send a wanted WHOOP4 heavy command, but it must not manufacture heavy demand from the passive toggle.

### Step 6: Wire scene state

Call `model.setAppForeground(true/false)` from iOS and macOS scene transitions. A background transition immediately reconciles away a Live-screen-only heavy stream but does not release the stored owner, so returning foreground re-arms without a new appear event.

### Step 7: Run BLE policy and existing detector tests

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/PreferredPeripheralRedirectTests \
  -only-testing:StrandTests/RealtimeDemandPolicyTests \
  -only-testing:StrandTests/ContinuousHrvScheduleTests \
  -only-testing:StrandTests/MarginalRadioDetectorTests \
  -only-testing:StrandTests/PostBondTimeoutLoopDetectorTests test
```

Expected: PASS.

### Step 8: Commit the BLE patch

```bash
git add Strand/BLE Strand/App/AppModel.swift Strand/App/LiveSessionRunner.swift \
  Strand/Screens/LiveView.swift Strand/Screens/LiveWorkoutView.swift \
  Strand/MenuBar/MenuBarContent.swift StrandiOS/App/StrandiOSApp.swift StrandTests
git commit -m "Derive realtime BLE demand from explicit owners"
```

---

## Task 4: Adapt Live Activity Cadence

**Files:**
- Modify: `StrandiOS/App/StrandiOSApp.swift`
- Modify: `StrandiOS/Widgets/LiveActivityController.swift`
- Create: `Strand/System/LiveActivityUpdatePolicy.swift`
- Create: `StrandTests/LiveActivityUpdatePolicyTests.swift`

### Step 1: Write failing fake-clock policy tests

Test the shared pure policy with explicit timestamps:

- no existing activity starts immediately with valid connected HR;
- active use permits updates at two seconds, not before;
- passive wear permits updates at 30 seconds, not before;
- changing passive -> active uses the active minimum;
- disconnect and opt-out return an immediate end decision regardless of the last push;
- missing HR does not start/update.

Run and confirm RED.

### Step 2: Implement the policy and controller integration

Add `LiveActivityUpdatePolicy` under shared `Strand/System` so the macOS test target can compile it. In `LiveActivityController`:

- keep ActivityKit start/re-adopt/end behavior;
- select active mode from `model.hasActiveRealtimeExperience`;
- evaluate enable/connect/HR/cadence before building recovery/effort content;
- accept a lazy score provider so a throttled HR publication does not scan `repo.days`;
- use two seconds for active Live/workout/session/manual use and 30 seconds for passive wear;
- bypass cadence for disconnect/opt-out end.

Update both HR and connected sinks in `StrandiOSApp` to call the new API. Keep the common `Repository.widgetAnchor` source for updates that are actually emitted.

### Step 3: Run policy tests and build iOS sources

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/LiveActivityUpdatePolicyTests test
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: tests PASS and unsigned generic iOS build succeeds.

### Step 4: Commit the Live Activity patch

```bash
git add Strand/System/LiveActivityUpdatePolicy.swift \
  StrandiOS/App/StrandiOSApp.swift StrandiOS/Widgets/LiveActivityController.swift \
  StrandTests/LiveActivityUpdatePolicyTests.swift
git commit -m "Throttle passive Live Activity updates"
```

---

## Task 5: Correct the Report and Verify the Integrated Branch

**Files:**
- Modify: `docs/PERFORMANCE_ANALYSIS.md`
- Create: `docs/PERFORMANCE_IMPLEMENTATION.md`

### Step 1: Update evidence and corrections

Correct the imported report where implementation inspection disproved the original wording:

- root invalidation risk is not proof of a complete layout per packet;
- `UserDefaults.set` does not prove a physical disk write per call;
- P1 is a late persisted-UUID startup race, not missing UUID persistence;
- WHOOP5/MG uses puffin toggle and rejects WHOOP4 R10/R11;
- Live Activity is event-driven with a two-second floor, not a two-second timer;
- remove the unsupported 43,000/day claim or label it only as a theoretical maximum.

Mark U1-U5/P1-P4 implemented and link the implementation document.

### Step 2: Document operational behavior and rollback

In `docs/PERFORMANCE_IMPLEMENTATION.md`, record:

- baseline tag and per-subsystem commits;
- active/passive BLE ownership matrix;
- persistence intervals and flush boundaries;
- Live Activity active/passive intervals;
- exact verification commands/results;
- any physical-device checks not completed;
- individual `git revert <commit>` rollback commands.

### Step 3: Regenerate the Xcode project

```bash
xcodegen generate
git status --short
```

Commit `project.pbxproj` only if XcodeGen legitimately adds/removes source references. Do not commit DerivedData or user schemes.

### Step 4: Run the full macOS suite

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' test
```

Expected: no failures beyond the two recorded `TodayExplainabilityTests`; the Xiaomi fixture test may remain skipped.

### Step 5: Build macOS and generic iOS

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' build
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Expected: both PASS.

### Step 6: Run physical-device verification when available

List devices and use the connected iPhone destination if present:

```bash
xcrun xctrace list devices
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -destination 'id=<connected-device-udid>' build
```

Verify manually and record status:

1. Live HR appears and leaving/re-entering Live arms/disarms correctly.
2. Start/end workout records one sample per second and survives background/foreground.
3. A Live-screen-only WHOOP4 stream drops heavy demand on background; workout/session continues.
4. Continuous HRV does not arm WHOOP4 R10/R11 by itself.
5. Disconnect/reconnect and late registry load reconnect to the selected strap.
6. Live Activity updates rapidly in active use, slowly in passive wear, and ends immediately on disconnect.
7. Copy/Save includes the full retained strap log while the card shows only 200 rows.

Hardware-unavailable checks are documented as pending, not reported as passed.

### Step 7: Commit documentation and generated references

```bash
git add docs/PERFORMANCE_ANALYSIS.md docs/PERFORMANCE_IMPLEMENTATION.md Strand.xcodeproj/project.pbxproj
git commit -m "Document performance changes and verification"
```

Omit `project.pbxproj` from `git add` when XcodeGen produces no tracked change.

### Step 8: Review, push, and preserve rollback markers

```bash
git status --short
git log --oneline --decorate performance-baseline-2026-07-10..HEAD
git diff --check performance-baseline-2026-07-10..HEAD
git push origin agent/high-impact-performance
```

Perform a final review focused on lifecycle ownership balance, delayed-write resurrection, WHOOP family command differences, and no new test failures before reporting completion.

---

## Plan Self-Review Checklist

- Every included design item U1-U5/P1-P4 has a production change and a named test.
- High-frequency UI data is excluded from the root snapshot or delegated to a leaf.
- Workout, log, and stress durability all have explicit background/disconnect/termination flushes.
- Delayed workout writes cannot recreate a cleared session.
- Presentation scan and state restoration remain outside late-pin redirection.
- WHOOP4 R10/R11 and WHOOP5 puffin behavior are tested separately.
- Realtime acquisition is idempotent per owner; reconnect does not acquire.
- Live Activity end decisions bypass throttling.
- Baseline exceptions and hardware-unverified items remain explicit.
- The local iPhone setup branch is never modified.
