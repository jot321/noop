import Foundation
import Combine
import WhoopStore

/// Keychain wrapper for the S3 secret access key — the only true secret in the cloud-sync config.
/// Bucket, region and access-key-id are non-secret and live in UserDefaults. Clone of `AIKeyStore`
/// (Strand/AI/AICoach.swift) with its own service so the two never collide.
enum CloudSecretStore {
    private static let service = "com.noop.cloudsync"
    private static let account = "s3-secret-key"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func save(_ secret: String) -> Bool {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { clear(); return true }
        guard let data = trimmed.data(using: .utf8) else { return false }
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let str = String(data: data, encoding: .utf8),
              !str.isEmpty else { return nil }
        return str
    }

    static func clear() { SecItemDelete(baseQuery as CFDictionary) }
}

/// Observable cloud-sync configuration + consent. Non-secret fields persist to UserDefaults; the
/// secret access key is Keychain-only. Off by default and opt-in: nothing leaves the device until the
/// user enables sync AND grants consent (docs/CLOUD_SYNC_PLAN.md §2.3 — this reverses the app's stated
/// offline-first invariant, so it must be explicit and revocable).
@MainActor
public final class CloudSyncSettings: ObservableObject {
    public static let shared = CloudSyncSettings()

    private enum Keys {
        static let enabled = "cloud.enabled"
        static let consent = "cloud.consent"
        static let bucket = "cloud.bucket"
        static let region = "cloud.region"
        static let accessKeyId = "cloud.accessKeyId"
        static let prefix = "cloud.prefix"
        static let retentionDays = "cloud.retentionDays"
        static let lastSyncAt = "cloud.lastSyncAt"
    }

    /// Master switch. When false the uploader never runs.
    @Published public var enabled: Bool { didSet { d.set(enabled, forKey: Keys.enabled) } }
    /// Explicit "I understand my health data will leave the device" consent, separate from `enabled`
    /// so toggling sync off/on doesn't silently re-consent.
    @Published public var consent: Bool { didSet { d.set(consent, forKey: Keys.consent) } }

    @Published public var bucket: String { didSet { d.set(bucket, forKey: Keys.bucket) } }
    @Published public var region: String { didSet { d.set(region, forKey: Keys.region) } }
    @Published public var accessKeyId: String { didSet { d.set(accessKeyId, forKey: Keys.accessKeyId) } }
    @Published public var prefix: String { didSet { d.set(prefix, forKey: Keys.prefix) } }
    /// Days of full-resolution decoded data kept on device before an uploaded+verified day is pruned.
    @Published public var retentionDays: Int { didSet { d.set(retentionDays, forKey: Keys.retentionDays) } }

    public var lastSyncAt: Date? {
        get { let t = d.double(forKey: Keys.lastSyncAt); return t > 0 ? Date(timeIntervalSince1970: t) : nil }
        set { d.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Keys.lastSyncAt) }
    }

    private let d = UserDefaults.standard

    private init() {
        enabled = d.bool(forKey: Keys.enabled)
        consent = d.bool(forKey: Keys.consent)
        bucket = d.string(forKey: Keys.bucket) ?? ""
        region = d.string(forKey: Keys.region) ?? "ap-south-1"
        accessKeyId = d.string(forKey: Keys.accessKeyId) ?? ""
        prefix = d.string(forKey: Keys.prefix) ?? "noop"
        let r = d.integer(forKey: Keys.retentionDays)
        retentionDays = r > 0 ? r : 60
    }

    /// True once every field needed to talk to S3 is present.
    public var isConfigured: Bool {
        !bucket.isEmpty && !region.isEmpty && !accessKeyId.isEmpty && (CloudSecretStore.read() != nil)
    }

    /// Sync should actually run only when enabled, consented and configured.
    public var isActive: Bool { enabled && consent && isConfigured }

    /// Build the S3 config from current settings + Keychain secret, or nil if incomplete.
    public func makeS3Config() -> S3Config? {
        guard let secret = CloudSecretStore.read(),
              !bucket.isEmpty, !region.isEmpty, !accessKeyId.isEmpty else { return nil }
        return S3Config(bucket: bucket, region: region, accessKeyId: accessKeyId,
                        secretAccessKey: secret, prefix: prefix)
    }

    public func saveSecret(_ secret: String) { CloudSecretStore.save(secret); objectWillChange.send() }

    /// Full local opt-out: disable, revoke consent, forget the secret. (Remote purge is a separate,
    /// explicit action so a user never loses cloud data by accident.)
    public func disableAndForget() {
        enabled = false
        consent = false
        CloudSecretStore.clear()
        objectWillChange.send()
    }
}
