# SideStore Release and Data-Preserving Upgrade Design

## Goal

Publish the current `dev` work, produce NOOP iOS build 174 from that exact source, install it through the already-configured SideStore environment, preserve the existing WHOOP database, and leave a repeatable release guide for future upgrades.

## Selected approach

Use SideStore's supported update path for the existing SideStore-managed application. Build the source IPA with the original project bundle identifier (`com.jotsarup.noop`); SideStore will re-sign it to the already-established installed identifier (`com.jotsarup.noop.B6925R5WYB`). Because SideStore already manages build 173 under that identifier, build 174 should replace it in place instead of creating another app container.

The ignored `StrandiOS/Resources/CloudSyncSecrets.plist` is intentionally included in this personal build. It must remain excluded from Git. The owner accepts that its scoped AWS credentials are extractable from the IPA.

## Source-control shape

Keep the history reviewable with separate commits:

1. Commit the current application, analytics, tests, cloud-provisioning, and tooling changes.
2. Bump the shared iOS/widget build number from 173 to 174.
3. Add the durable `docs/SIDESTORE_RELEASE.md` operational guide.

Push the resulting `dev` branch directly to `origin/dev`, matching the repository's single-branch model. No pull request is required for this owner-directed release.

## Build flow

1. Confirm the real cloud plist is ignored and the example plist is tracked.
2. Regenerate the Xcode project from `project.yml`.
3. Run the relevant Swift package tests and an iOS Release build for `NOOPiOS`.
4. Package the Release `.app` as `Payload/NOOP.app` in `NOOP-174.ipa`.
5. Verify the IPA archive, version, build number, bundle identifier, embedded widget version, and presence of the approved cloud plist without printing secret values.

## Device data flow

The WHOOP database is not copied into the IPA and is never committed. Immediately before installation, copy the current SideStore NOOP `Library` container to a dated diagnostics folder and record table counts, latest timestamps, and `PRAGMA quick_check`.

Serve the IPA temporarily over the local network and invoke SideStore's supported `sidestore://install?url=...` URL. After installation:

1. Confirm only SideStore and one NOOP developer app are installed.
2. Confirm NOOP is build 174 under `com.jotsarup.noop.B6925R5WYB`.
3. Copy the post-install container and compare database integrity and counts with the pre-install snapshot.
4. Launch NOOP and verify the SideStore-managed process is running.
5. Require fresh `hrSample` or `rrInterval` persistence after launch before declaring the upgrade complete. A live UI value alone is not sufficient evidence.

If the in-place update unexpectedly creates a fresh container, stop the app, restore the pre-install `Library` backup into the new SideStore bundle container, relaunch, and repeat the same integrity and live-write checks.

## Failure handling

- Do not uninstall the working build before the pre-install container backup passes integrity checks.
- Do not expose the cloud plist or its values in Git output, logs, documentation, or commit contents.
- If SideStore reports a free-app limit, verify the installed developer apps before deleting anything.
- If installation fails, preserve the existing build and container and record SideStore's console log.
- If data counts regress or the database fails `quick_check`, restore the backup before continuing.
- If the UI is live but database timestamps do not advance, leave the app running and report the persistence gap instead of claiming success.

## Durable guide contents

`docs/SIDESTORE_RELEASE.md` will document prerequisites, build-number bumping, tests, Release build and IPA packaging, secret-handling rules, pre-upgrade backup, SideStore delivery, verification, rollback, and the exact future-version checklist. Commands will use discoverable device and network values rather than treating today's IDs or IP address as permanent.

## Success criteria

- All intended source changes are committed and pushed to `origin/dev`.
- Tests and the Release build complete successfully from the committed tree.
- `NOOP-174.ipa` is structurally valid and contains build 174 for both app and widget.
- The approved cloud plist is bundled but remains ignored and uncommitted.
- The phone has one SideStore-managed NOOP build 174.
- The restored/preserved WHOOP database passes `PRAGMA quick_check` with non-regressing counts.
- At least one persisted live-data stream advances after launch, or the remaining persistence problem is reported explicitly.
- The release guide is committed and contains no secrets.
