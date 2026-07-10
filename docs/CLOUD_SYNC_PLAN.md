# Cloud Sync Plan — Tiered Offload + Prune (AWS)

**Status:** IMPLEMENTED (BYO-S3, shape A). Store layer + S3 client + uploader + settings/consent UI
shipped and validated end-to-end against a real ap-south-1 bucket (upload → re-download hash-verify →
downsample-prune round-trip). Remaining follow-up: iOS `BGProcessingTask` scheduling under Wi-Fi+charging
(the manual "Sync now" action and the whole engine are in place; only the background trigger is deferred),
and shape B (managed multi-user) if the app ever goes multi-user.
**Decision on record:** *tiered offload + prune* — keep a recent window on device for
speed/offline; upload older raw + aggregates to AWS; prune (downsample/drop) the old local raw.

## Implementation map (as built)

- **Schema (migration `v23-cloud-sync`, `Packages/WhoopStore/.../Database.swift`):** `cloudObject`
  per-(deviceId, day, stream) upload ledger (`uploaded`→`verified`, `prunedAt`); `minuteAgg` 1-minute
  min/mean/max/count echo kept after prune.
- **Store API (`Packages/WhoopStore/.../CloudSync.swift`):** UTC-day sealing + CSV export +
  zlib(length-prefixed) compression, ledger upsert/verify, `downsampleAndPruneCloudDay` (verified-only,
  count-mismatch-guarded), `minuteAggSeries`, `cloudLedgerSummary`. `fillDailySpo2IfNil` in `MetricsCache`.
- **S3 client (`Strand/Cloud/S3Client.swift`):** from-scratch SigV4 (CryptoKit HMAC-SHA256), path-style
  PUT/GET/HEAD/DELETE, cache-bypass (avoids the `If-Modified-Since`→501 trap), content-hash return.
- **Uploader (`Strand/Cloud/CloudUploader.swift`):** seal→upload→verify(re-download+hash)→prune actor.
- **Settings/consent (`Strand/Cloud/CloudSyncSettings.swift`, `Strand/Screens/CloudSyncCard.swift`):**
  Keychain secret (`CloudSecretStore`), opt-in + explicit consent, retention setting, Test connection,
  Sync now, ledger/storage readout, disable-and-forget + delete-remote.

---

## 1. Why (the actual problem)

Everything lives in one on-device SQLite file (`<AppSupport>/OpenWhoop/whoop.sqlite`, GRDB/WAL).
The *raw-frame outbox* is already bounded (off by default, zlib-compressed, 50 MB cap, 24 h
prune — `Strand/Collect/PrunePolicy.swift`, `Packages/WhoopStore/.../RawOutbox.swift`).

The unbounded growth is the **decoded per-second streams** — `hrSample`, `rrInterval`,
`ppgHrSample`, `spo2Sample`, `skinTempSample`, `gravitySample`, `stepSample`, `sleepStateSample`
(see `Packages/WhoopStore/.../Database.swift`). These are **never pruned, never downsampled,
never row-compressed**. Order of magnitude: **~300k–500k rows/day, ~10–30 MB/day, multiple GB/year**
for a continuously-worn WHOOP 5. That is the device-fill problem.

## 2. Design principles

1. **Recent stays local.** A configurable retention window (default 60–90 days) of full-resolution
   decoded data remains on device — the app stays fast and fully offline for recent history.
2. **Old offloads, then prunes.** Once a *sealed* day (older than the window) is durably uploaded and
   verified, its high-rate local rows are downsampled (1 Hz → 1 min) or dropped, cloud becoming the
   source of truth. Derived daily/session tables (`dailyMetric`, `sleepSession`, `workout`,
   `metricSeries`) are tiny and stay local forever.
3. **Opt-in + private by default.** This reverses the app's stated offline-first invariant
   ("no server uploader/sync — all data stays on-device", `BLEManager.swift:917`). It must be an
   explicit, revocable user choice with clear consent, encryption in transit and at rest, and ideally
   **client-side (envelope) encryption** of health payloads so the bucket never holds plaintext.
4. **Reuse the scaffolding.** The removed upload feature left `rawBatch.syncedAt`, a vestigial
   `synced` column, and clock refs. The outbox + `PrunePolicy` + cursor patterns are the template;
   we extend them to decoded streams rather than inventing a new subsystem.

## 3. Two backend shapes (recommend A for v1, B as the scale path)

**A — BYO-S3 (no server, on-brand, ship first).**
Mirrors the app's existing "bring your own key" ethos (AI providers in `Strand/AI/Providers/*`).
User supplies an S3 bucket + scoped IAM credentials (or a Cognito identity). Client uploads objects
directly via the AWS S3 API / presigned PUT. Zero backend to run, cheapest, fastest to build.
Good enough for a power-user / self-host audience.

**B — Managed multi-user (if this becomes a product).**
- **Auth:** Cognito user + identity pool.
- **Ingest:** API Gateway + Lambda issues presigned URLs and validates writes.
- **Cold/raw tier:** S3, one object per `(deviceId, UTC-day, stream)`, zlib or **Parquet**,
  partitioned `deviceId/date/`; S3 Lifecycle → Glacier after N days. Queryable via Athena.
- **Warm/queryable tier:** downsampled series (e.g. 1-min HR, nightly metrics) in Timestream or
  Aurora Serverless v2 / DynamoDB, so trends load without touching raw.
- Cost driver to watch is **restore egress**, not storage (compressed raw ≈ 3–10 MB/day/user; S3 at
  ~$0.023/GB-mo is negligible; Glacier cheaper).

Both shapes share the same **client** sync engine and object layout, so starting with A does not
throw away work when moving to B.

## 4. Client architecture

- **`CloudUploader` actor** (next to `WhoopStore`): batches decoded rows by `(deviceId, day, stream)`,
  serializes compactly (reuse `packFrames` + `zlibCompressWithLength`, or Parquet), uploads
  idempotently keyed by a content hash so retries are safe.
- **`cloudCursor` table:** per `(deviceId, stream)` high-water `ts` of what's durably uploaded, plus a
  per-day upload state (`pending / uploaded / verified`). New GRDB migration.
- **Scheduling:** iOS `BGProcessingTask`, gated on **Wi-Fi + charging**, sealing and uploading whole
  days older than "now − small lag". Respect the existing power/BLE budget work already in the tree.
- **Backfill:** existing local history uploads once in the background under the same gates.

## 5. Prune / downsample (the part that frees the disk)

Extend `PrunePolicy`:
- Only ever prune a day whose remote object exists **and** hash-matches (verify before delete).
- For days older than the retention window: downsample 1 Hz decoded rows → 1-min aggregates
  (min/mean/max) in a compact `metricSeries`-style table, then delete the raw rows; OR drop entirely
  when cloud is authoritative. Keep the existing 50 MB raw-outbox cap untouched.
- Guardrails: never prune unsynced/unverified data; retention window is a user setting; a "storage
  used / freed" readout (the app already surfaces `databaseFileSizeBytes()`).

## 6. Read / restore path

- **On-demand hydration:** scrolling to an old day not on device fetches its object, renders, and may
  cache briefly.
- **Long-range trends** query the warm/aggregate tier, never raw — so year views stay instant.

## 7. Security & privacy checklist

- Explicit opt-in consent screen; clear "what leaves the device" copy; one-tap disable + purge-remote.
- TLS in transit; SSE-KMS at rest; strongly consider **client-side envelope encryption** with a
  user-held key (health data).
- Region / data-residency selection. Update `docs/PRIVACY_SECURITY.md`.

## 8. Phased delivery

1. **Schema + settings** — SHIPPED: `cloudObject` ledger migration (v23), BYO-S3 (shape A) settings UI + consent (`CloudSyncCard`).
2. **Upload sealed days** — SHIPPED: idempotent seal→upload→hash-verify (`CloudUploader`), backfill from the oldest day, plus AUTOMATIC daily-ish runs (`CloudSyncScheduler`): iOS `BGProcessingTask` gated on external power + network with a foreground catch-up, macOS hourly timer with a 20 h spacing guard, both restricted to unmetered/unconstrained network paths. Opt-in (`autoSync`, default OFF).
3. **Verified prune/downsample** — SHIPPED: `downsampleAndPruneCloudDay` behind the retention setting, 1-min `minuteAgg` echo kept locally.
4. **On-demand hydration** — SHIPPED for the Deep Timeline: a pruned window renders the `minuteAgg` echo (flagged "cloud echo"), and an explicit "Restore" tap re-downloads, ledger-hash-verifies and re-imports the day's raw (`CloudHydrator` → `WhoopStore.importCloudDayPayload`). Hydration clears `prunedAt`, so restored raw is a temporary cache the next pass re-prunes. Long-range trend queries against the aggregate tier remain open.
5. **(Scale)** managed backend (shape B: Cognito / Lambda / S3+Athena / Timestream) if going multi-user — open.

## 9. Testing

Round-trip integrity (hash equality), prune-safety (property test: never lose unsynced data),
resumable/interrupted uploads, offline resilience, restore correctness, and a storage-growth
regression that asserts the local DB stops growing unbounded under the retention policy.
