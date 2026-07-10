# Task 2 Report: Coalesce Workout, Log, and Stress Persistence

Status: implementation complete.
Branch: agent/high-impact-performance
Base: 38fbe5b

## Summary

Implemented coalesced persistence for manual workout snapshots, durable log tail writes, and stress replay-safety state. Split HR and R-R ingestion so HR updates smooth/workout only, while fresh R-R packets drive stress exactly once. Added idempotent performance flush wiring for lifecycle, explicit/observed disconnect, termination notifications, and scheduled debug export.

## RED and GREEN Evidence

### Workout

RED command:
```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/ActiveWorkoutPersistenceTests \
  -only-testing:StrandTests/ActiveWorkoutRuntimeTests test
```

RED key output:
```text
Cannot find 'ActiveWorkoutRuntime' in scope
** TEST FAILED **
```

GREEN command:
```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/ActiveWorkoutPersistenceTests \
  -only-testing:StrandTests/ActiveWorkoutRuntimeTests test
```

GREEN key output:
```text
Test Suite 'ActiveWorkoutPersistenceTests' passed
Test Suite 'ActiveWorkoutRuntimeTests' passed
Executed 18 tests, with 0 failures
** TEST SUCCEEDED **
```

### Log

RED command:
```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/LogTailPersistenceTests test
```

RED key output:
```text
Cannot find type 'LogTailPersistence' in scope
** TEST FAILED **
```

GREEN command:
```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/LogTailPersistenceTests test
```

GREEN key output:
```text
Test Suite 'LogTailPersistenceTests' passed
Executed 6 tests, with 0 failures
** TEST SUCCEEDED **
```

### Stress

RED command:
```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/StressStatePersistenceTests test
```

RED key output:
```text
Cannot find 'StressStatePersistence' in scope
Extra argument 'from' in call to BiofeedbackPrefs.loadStressState
** TEST FAILED **
```

Interim failure caught by tests:
```text
XCTAssertEqual failed: isMainThread was true for immediate safety-edge writes
```

GREEN command:
```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/StressStatePersistenceTests test
```

GREEN key output:
```text
Test Suite 'StressStatePersistenceTests' passed
Executed 6 tests, with 0 failures
** TEST SUCCEEDED **
```

### Final Focused Verification

Command:
```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -only-testing:StrandTests/ActiveWorkoutPersistenceTests \
  -only-testing:StrandTests/ActiveWorkoutRuntimeTests \
  -only-testing:StrandTests/LogTailPersistenceTests \
  -only-testing:StrandTests/StressStatePersistenceTests test
```

Key output:
```text
Test Suite 'ActiveWorkoutPersistenceTests' passed
Executed 14 tests, with 0 failures
Test Suite 'ActiveWorkoutRuntimeTests' passed
Executed 4 tests, with 0 failures
Test Suite 'LogTailPersistenceTests' passed
Executed 6 tests, with 0 failures
Test Suite 'StressStatePersistenceTests' passed
Executed 6 tests, with 0 failures
Executed 30 tests, with 0 failures
** TEST SUCCEEDED **
```

Additional checks:
```bash
git diff --check
```
Key output: no output.

Attempted iOS compile verification:
```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
Key output:
```text
This scheme builds an embedded Apple Watch app. watchOS 26.2 must be installed in order to run the scheme
```

Fallback target build:
```bash
xcodebuild -project Strand.xcodeproj -target NOOPiOS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```
Key output:
```text
Unable to find module dependency: 'NetworkImage'
import NetworkImage
** BUILD FAILED **
```

## Files Changed

- Strand/App/ActiveWorkoutPersistence.swift
- Strand/App/ActiveWorkoutRuntime.swift
- Strand/App/AppModel.swift
- Strand/App/StressStatePersistence.swift
- Strand/App/StrandApp.swift
- Strand/BLE/LiveState.swift
- Strand/Screens/BiofeedbackPrefs.swift
- Strand/System/LogTailPersistence.swift
- Strand/System/ScheduledDebugExport.swift
- StrandiOS/App/StrandiOSApp.swift
- StrandTests/ActiveWorkoutPersistenceTests.swift
- StrandTests/ActiveWorkoutRuntimeTests.swift
- StrandTests/LogTailPersistenceTests.swift
- StrandTests/StressStatePersistenceTests.swift

## Self-Review

- Preserved scoring formulas, nudge gates, redaction/domain tags, log export shape, Bluetooth connection/offload behavior, and user-visible metrics.
- Replaced only durable-tail persistence in LiveState; full log and visibleLog projection are still maintained on append.
- Workout samples now dedupe per Unix second, keep O(1) count/sum/average/peak state, gate live strain to immediate plus at most every 10 seconds, and still compute final saved workout strain from final samples.
- Workout start writes immediately; updates coalesce to a 15 second trailing snapshot; flush and finish/clear complete through the coordinator queue; delayed work is generation-guarded so it cannot resurrect a completed workout.
- Log tail appends pass one redacted line to a serial writer; the writer owns the 2,000-line cap, 5 second trailing persistence, and flush-before-export behavior.
- Stress state persists wasBelow/lastFireAt safety edges immediately off main and before nudge side effects; baseline-only changes coalesce to the 60 second coordinator; disabled/unchanged states do not write.
- Lifecycle flushes are idempotent and wired for iOS/macOS scene or notification transitions where available, explicit disconnect, observed disconnect, scheduled export, and termination notifications.

## Concerns

- iOS compile verification could not be completed in this environment: the scheme is blocked by missing watchOS 26.2 support, and the direct target build failed before app-source compilation on an external MarkdownUI/NetworkImage module-resolution issue.
- Final macOS focused persistence tests passed. Remaining xcodebuild warnings observed during the successful test run are pre-existing/unrelated warnings in AppleWatchDevice, AddDeviceWizard, and AppModel.

## Commit

Subject: Coalesce hot-path state persistence
Note: final SHA is reported in the task handoff; embedding this commit's own SHA in this file would change the SHA.
