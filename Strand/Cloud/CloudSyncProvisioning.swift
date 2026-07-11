import Foundation

/// Zero-touch cloud-sync provisioning for a personal build (docs/CLOUD_SYNC_PLAN.md §3-A, BYO-S3).
///
/// The stock flow makes the user type bucket / region / access-key / secret into the Cloud Sync card.
/// On an owner's own fork that is pure friction — the values never change. This seeds them at launch
/// from a **bundled, gitignored** `CloudSyncSecrets.plist` so the app arrives fully configured and the
/// card needs no interaction.
///
/// Security note: the secret access key lives inside the app bundle's Resources when this file is
/// present, which is only as private as the device / build. Use a **scoped IAM key** (PutObject /
/// GetObject / DeleteObject / ListBucket on this one bucket, nothing else) so a leaked bundle can't
/// touch anything but this backup. The plist is gitignored (`secrets.*`) so it never reaches the repo.
///
/// No-op when the resource is absent (every non-owner build, and the macOS build, which doesn't bundle
/// it) — `Bundle.main` simply returns nil and nothing is seeded, so the manual card still works.
enum CloudSyncProvisioning {

    /// Plist keys (mirror `CloudSyncSettings` fields). Strings unless noted.
    private enum K {
        static let bucket = "bucket"
        static let region = "region"
        static let accessKeyId = "accessKeyId"
        static let secretAccessKey = "secretAccessKey"
        static let prefix = "prefix"
        static let retentionDays = "retentionDays"   // Int
        static let enabled = "enabled"               // Bool
        static let consent = "consent"               // Bool
        static let autoSync = "autoSync"             // Bool
    }

    /// Seed `CloudSyncSettings` (+ Keychain secret) from the bundled plist, if present. Idempotent and
    /// cheap; safe to call on every launch. Runs on the main actor because `CloudSyncSettings` is
    /// `@MainActor`-isolated. Values in the plist are authoritative for the connection fields (bucket /
    /// region / key id / secret / prefix / retention) — this is a hardcoded config, so it re-applies
    /// them each launch rather than letting a stale in-app edit drift. The enable / consent / autoSync
    /// switches are applied only when the plist explicitly sets them.
    @MainActor
    static func seedIfPresent() {
        guard let url = Bundle.main.url(forResource: "CloudSyncSecrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else {
            return   // no bundled config — manual Cloud Sync card is unchanged
        }

        let settings = CloudSyncSettings.shared

        if let bucket = (dict[K.bucket] as? String)?.trimmed, !bucket.isEmpty { settings.bucket = bucket }
        if let region = (dict[K.region] as? String)?.trimmed, !region.isEmpty { settings.region = region }
        if let keyId = (dict[K.accessKeyId] as? String)?.trimmed, !keyId.isEmpty { settings.accessKeyId = keyId }
        if let prefix = (dict[K.prefix] as? String)?.trimmed, !prefix.isEmpty { settings.prefix = prefix }
        if let retention = dict[K.retentionDays] as? Int, retention > 0 { settings.retentionDays = retention }

        // Secret → Keychain (only when the plist actually carries one, so a key-less template can't wipe
        // a secret already saved on the device).
        if let secret = (dict[K.secretAccessKey] as? String)?.trimmed, !secret.isEmpty {
            settings.saveSecret(secret)
        }

        // Switches: apply only when explicitly present in the plist. `enabled`+`consent` are what let the
        // uploader run at all; `autoSync` opts into the scheduled background pass.
        if let enabled = dict[K.enabled] as? Bool { settings.enabled = enabled }
        if let consent = dict[K.consent] as? Bool { settings.consent = consent }
        if let autoSync = dict[K.autoSync] as? Bool { settings.autoSync = autoSync }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
