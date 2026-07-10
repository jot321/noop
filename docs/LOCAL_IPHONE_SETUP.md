# Jot's Local iPhone Setup

This document records the owner-specific configuration used to build, sign, install, and diagnose
NOOP on Jot's iPhone. It belongs in the `jot321/noop` fork; the signing values are not intended for
the canonical upstream repository.

## Locations

- Local repository: `/Users/jotsarup/Desktop/experiments/noop`
- GitHub fork: `https://github.com/jot321/noop`
- Private device diagnostics: `/Users/jotsarup/Desktop/experiments/noop_diagnostics/2026-07-10-live-hr`

The diagnostics directory is deliberately outside Git. It contains SQLite data, raw WHOOP frames,
preferences, and logs that may reveal private health or device information. Do not commit it.

## Environment Used

- macOS 15.6 on Apple Silicon
- Xcode 26.3, build 17C529
- Apple Swift 6.2.4
- XcodeGen 2.45.4
- A free Apple Personal Team with Developer Mode enabled on the iPhone

NOOP is a native Swift/Xcode project. Rust is not required for this repository. The separate Goose
project uses Rust, but NOOP does not.

## Fork-Specific Configuration

The following owner-specific values are set in `project.yml`:

| Setting | Value |
|---|---|
| Development team | `B6925R5WYB` |
| iOS bundle identifier | `com.jotsarup.noop` |
| Widget bundle identifier | `com.jotsarup.noop.widgets` |
| App Group | `group.com.jotsarup.noop` |
| Background task identifier | `com.jotsarup.noop.debugexport` |

Additional build adjustments:

- `NOOPWatch` is no longer embedded in `NOOPiOS`, avoiding a watchOS runtime requirement. The
  standalone Watch targets remain in `project.yml` for future use.
- The empty `com.apple.developer.healthkit.access` entitlement was removed because free Personal
  Team provisioning rejected it. The normal HealthKit entitlement remains enabled.
- The background task identifier is kept identical in `project.yml`, `Info.plist`, and
  `ScheduledDebugExport.swift`.
- The widget remains embedded and signed with the same Personal Team.

No WHOOP protocol decoder, analytics algorithm, database schema, or application UI behavior was
changed as part of the installation work.

## First-Time Mac and iPhone Setup

1. Install a version of Xcode supported by the current macOS version. The working setup uses Xcode
   26.3.
2. Open Xcode once, accept the license, and let it install required components.
3. In Xcode, open Settings, choose Accounts, and sign in with the Apple ID used for the Personal Team.
4. Install XcodeGen if needed:

   ```bash
   brew install xcodegen
   ```

5. Connect the iPhone by cable, unlock it, trust the Mac if prompted, and enable Developer Mode under
   Settings > Privacy & Security > Developer Mode. Restart and confirm when iOS requests it.
6. Confirm that CoreDevice sees the phone:

   ```bash
   xcrun devicectl list devices
   ```

Use the connected phone's identifier in place of `<COREDEVICE_IDENTIFIER>` below. Do not publish the
identifier in Git.

## Generate, Test, and Build

`project.yml` is the source of truth. Regenerate `Strand.xcodeproj` after changing project settings:

```bash
cd /Users/jotsarup/Desktop/experiments/noop
xcodegen generate
```

Run the protocol regression tests:

```bash
swift test --package-path Packages/WhoopProtocol
```

The installation run completed 240 tests with zero failures.

Build and allow Xcode to create or refresh the free provisioning profile:

```bash
xcodebuild \
  -project Strand.xcodeproj \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'platform=iOS,id=<COREDEVICE_IDENTIFIER>' \
  -derivedDataPath /tmp/noop-deriveddata-device \
  -allowProvisioningUpdates \
  build
```

The signed application is produced at:

```text
/tmp/noop-deriveddata-device/Build/Products/Debug-iphoneos/NOOP.app
```

## Install and Launch

```bash
xcrun devicectl device install app \
  --device <COREDEVICE_IDENTIFIER> \
  /tmp/noop-deriveddata-device/Build/Products/Debug-iphoneos/NOOP.app

xcrun devicectl device process launch \
  --device <COREDEVICE_IDENTIFIER> \
  --terminate-existing \
  com.jotsarup.noop
```

Verify installation:

```bash
xcrun devicectl device info apps \
  --device <COREDEVICE_IDENTIFIER>
```

A free Personal Team profile normally expires after about seven days. Re-run the build, install, and
launch commands to refresh the app. Source code and the on-phone application database are separate;
rebuilding does not intentionally clear the database, but a full uninstall can remove app data.

## Pair the WHOOP

1. Ensure the official WHOOP app, Goose, or another BLE client is not actively connected to the
   strap. A WHOOP generally permits only one active host for this connection.
2. In NOOP, select `WHOOP 5.0 / MG` and scan.
3. Complete the Bluetooth pairing prompt if iOS presents one.
4. Confirm the connected state and current battery reading in Settings or Live.

The tested connection completed `CLIENT_HELLO`, established an encrypted bond, enabled the standard
heart-rate and battery notifications, synchronized the strap clock, and began historical offload.

## Live HR Workaround

Live HR should appear within seconds, not after several minutes. The current UI has a lifecycle edge
case when the Live screen appears before bonding finishes: the screen can miss the command that arms
realtime HR.

Workaround:

1. Open another tab such as Today.
2. Return to Live.
3. Keep the strap on the wrist and wait 10-15 seconds.

This workaround restored live HR during the installation session. The lifecycle bug has been
diagnosed but not patched in this branch.

## Overnight Collection

For denser overnight HR and R-R data, open Settings > Strap and enable:

1. `Continuous HRV capture`
2. `Overnight only`

The default overnight window is 22:00-07:00. Keep Bluetooth enabled, keep the phone within normal BLE
range, and do not force-quit NOOP. The phone can be locked and NOOP can remain in the background.

In the morning, open NOOP and leave it connected in the foreground for 10-15 minutes so offload and
analysis can complete. Recovery needs several nights to establish a personal baseline.

## Known WHOOP 5/MG Limitation

The tested strap sends historical layouts v18, v20, and v21. NOOP decoded some older v18 history, but
explicitly reported that v20 and v21 records are not decoded. The undecodable raw records are archived
rather than discarded.

Consequences:

- Live HR can work while historical sleep inputs remain incomplete.
- Overnight HR and R-R may accumulate with Continuous HRV capture enabled.
- Sleep detection, sleep stages, strain, and recovery may be absent or partial.
- Waiting longer cannot make an unsupported layout decode; parser work is still required.

## App Data and Diagnostics

Important paths inside the iOS app data container:

```text
Library/Application Support/OpenWhoop/whoop.sqlite
Library/Application Support/com.noopapp.noop/rejected_history.jsonl
Library/Preferences/com.jotsarup.noop.plist
```

Copy the app's Library directory to the Mac without modifying the phone:

```bash
xcrun devicectl device copy from \
  --device <COREDEVICE_IDENTIFIER> \
  --domain-type appDataContainer \
  --domain-identifier com.jotsarup.noop \
  --source Library \
  --destination "$HOME/Desktop/noop-device-library"
```

The preferences plist contains `strapLog.tail`. The SQLite database contains tables such as
`hrSample`, `rrInterval`, `battery`, `gravitySample`, `sleepSession`, and `dailyMetric`. Always inspect
a copied database with its adjacent `-wal` and `-shm` files so recent committed rows are visible.

Never add the copied app container, SQLite database, rejected frame archive, provisioning profiles,
or Apple credentials to Git.

## Current Verification Record

- XcodeGen generation succeeded.
- `WhoopProtocol` completed 240 tests with zero failures.
- The iPhone Debug build succeeded with automatic provisioning.
- NOOP and its widget were signed and installed as `com.jotsarup.noop`.
- The app launched, bonded to the WHOOP, received current battery notifications, and displayed live HR
  after cycling back into the Live tab.
- Raw diagnostics were copied only to the private sibling diagnostics directory listed above.
