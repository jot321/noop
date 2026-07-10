# Local iPhone Build Design

## Goal

Build, sign, install, and launch NOOP on Jot's connected iPhone without installing the watchOS runtime.

## Approach

Keep the upstream application, BLE protocol, storage, analytics, iOS widget, and HealthKit behavior unchanged. Configure the existing `NOOPiOS` target for Apple team `B6925R5WYB`, use unique local bundle and App Group identifiers under `com.jotsarup.noop`, and remove only the `NOOPWatch` dependency from the iPhone app target. The standalone Watch targets stay in `project.yml` for future use but are not embedded in this local iPhone build.

The background task identifier must use the same local reverse-domain prefix in both `project.yml` and `ScheduledDebugExport.swift`. `xcodegen generate` remains the only way to create `Strand.xcodeproj`.

## Success Criteria

- `NOOPiOS` builds for the connected `<COREDEVICE_IDENTIFIER>` without requiring watchOS.
- Xcode signs the app and widget with team `B6925R5WYB` using automatic provisioning.
- The built app has bundle identifier `com.jotsarup.noop`.
- `devicectl` installs and launches the app on Jot's iPhone.
- Existing protocol tests still pass.

## Constraints

- Do not alter WHOOP protocol or analytics behavior.
- Do not remove the standalone Watch targets.
- Keep machine-specific signing settings in Jot's fork rather than proposing them upstream.
- Preserve Goose under its existing `com.jotsarup.goose` bundle identifier.
