# Local iPhone Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build, sign, install, and launch an iPhone-only NOOP build on Jot's connected iPhone.

**Architecture:** Retain the existing `NOOPiOS` application and widget targets, but stop embedding the Watch app so Xcode does not require a watchOS runtime. Put all local Apple signing identifiers in `project.yml`, regenerate the project, and use the existing CoreDevice connection for installation.

**Tech Stack:** Xcode 26.3, XcodeGen 2.45.4, Swift Package Manager, SwiftUI, CoreBluetooth, `xcodebuild`, and `xcrun devicectl`.

## Global Constraints

- Apple team is `B6925R5WYB`.
- App bundle identifier is `com.jotsarup.noop`.
- Widget bundle identifier is `com.jotsarup.noop.widgets`.
- Shared App Group is `group.com.jotsarup.noop`.
- Background task identifier is `com.jotsarup.noop.debugexport`.
- Do not modify protocol, analytics, or persistence behavior.
- Keep machine-specific signing settings in Jot's fork rather than proposing them upstream.

---

### Task 1: Local iOS project configuration

**Files:**
- Modify: `project.yml`
- Modify: `Strand/System/ScheduledDebugExport.swift`

**Interfaces:**
- Consumes: XcodeGen settings and the existing `NOOPiOS` target graph.
- Produces: An iPhone app graph containing `NOOPiOSWidgets` but not `NOOPWatch`.

- [x] **Step 1: Confirm the existing build fails for the expected reason**

Run:

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Expected: failure stating that watchOS 26.2 is required because the scheme embeds an Apple Watch app.

- [x] **Step 2: Apply the minimum local settings**

Set `DEVELOPMENT_TEAM`, `APP_GROUP_ID`, the iOS app and widget bundle identifiers, and both copies of the background-task identifier to the values in Global Constraints. Remove only `- target: NOOPWatch` from `NOOPiOS.dependencies`.

- [x] **Step 3: Regenerate and inspect the project**

Run:

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -showBuildSettings
```

Expected: the iOS target reports `com.jotsarup.noop`, team `B6925R5WYB`, and no Watch product dependency.

### Task 2: Build verification and device installation

**Files:**
- Generated: `Strand.xcodeproj/*` (ignored by Git)
- Generated: `/tmp/noop-deriveddata-device/Build/Products/Debug-iphoneos/NOOP.app`

**Interfaces:**
- Consumes: The generated Xcode project and connected `<COREDEVICE_IDENTIFIER>`.
- Produces: A signed and installed `com.jotsarup.noop` application.

- [x] **Step 1: Run the protocol regression suite**

Run:

```bash
swift test --package-path Packages/WhoopProtocol
```

Expected: 240 tests, 0 failures.

- [x] **Step 2: Build and provision for the connected iPhone**

Run:

```bash
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS -configuration Debug \
  -destination 'platform=iOS,id=<COREDEVICE_IDENTIFIER>' \
  -derivedDataPath /tmp/noop-deriveddata-device -allowProvisioningUpdates build
```

Expected: `** BUILD SUCCEEDED **` and a signed `NOOP.app` product.

- [x] **Step 3: Install and launch**

Run:

```bash
xcrun devicectl device install app \
  --device <COREDEVICE_IDENTIFIER> \
  /tmp/noop-deriveddata-device/Build/Products/Debug-iphoneos/NOOP.app
xcrun devicectl device process launch \
  --device <COREDEVICE_IDENTIFIER> \
  --terminate-existing com.jotsarup.noop
```

Expected: installation and launch both report success.

- [x] **Step 4: Read back installed state**

Run:

```bash
xcrun devicectl device info apps \
  --device <COREDEVICE_IDENTIFIER>
```

Expected: both `com.jotsarup.goose` and `com.jotsarup.noop` are present.
