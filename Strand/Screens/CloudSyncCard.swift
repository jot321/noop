import SwiftUI
import StrandDesign
import WhoopStore

/// BYO-S3 cloud-offload settings + consent (docs/CLOUD_SYNC_PLAN.md §3A). Mirrors the AI-Coach
/// "bring your own key" pattern: non-secret fields in UserDefaults (`CloudSyncSettings`), the S3 secret
/// in the Keychain (`CloudSecretStore`). Nothing leaves the device until the user both enables sync AND
/// grants explicit consent — this feature deliberately reverses the app's offline-first invariant, so
/// consent is a separate, revocable switch with clear "what leaves the device" copy.
struct CloudSyncCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var settings = CloudSyncSettings.shared

    @State private var secretDraft = ""
    @State private var status = ""
    @State private var busy = false
    @State private var ledger: CloudLedgerSummary?
    @State private var dbSize: Int64?
    @State private var showPurgeConfirm = false

    private var deviceId: String { model.deviceRegistry?.activeDeviceId ?? "my-whoop" }

    var body: some View {
        SettingsSection(
            icon: "icloud.and.arrow.up",
            title: "Cloud sync (S3)",
            blurb: "Off by default. Offload older raw sensor history to your OWN Amazon S3 bucket, then reclaim the space on \(Platform.deviceNounPhrase). Recent data always stays local. This is the one feature that sends health data off-device — it needs your explicit consent below."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2 + 4) {
                masterToggles
                if settings.enabled {
                    Divider().overlay(StrandPalette.hairline)
                    credentialFields
                    Divider().overlay(StrandPalette.hairline)
                    retentionRow
                    actionButtons
                    if !status.isEmpty {
                        Text(status)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    statusReadout
                    Divider().overlay(StrandPalette.hairline)
                    dangerZone
                }
            }
        }
        .task { await refreshStatus() }
    }

    // MARK: - Sections

    private var masterToggles: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Toggle(isOn: $settings.enabled) {
                Text("Enable cloud sync").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.switch).tint(StrandPalette.accent)

            Toggle(isOn: $settings.consent) {
                Text("I consent to uploading my health data").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.switch).tint(StrandPalette.accent)
            .disabled(!settings.enabled)

            Text("What leaves the device: your older per-second heart-rate, R-R, SpO₂, skin-temp and motion streams, compressed and uploaded to the bucket you configure. Transport is TLS; enable SSE on the bucket for at-rest encryption. You can disable and purge at any time.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var credentialFields: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2 + 2) {
            labeledField("Bucket", "my-noop-bucket", text: $settings.bucket)
            labeledField("Region", "ap-south-1", text: $settings.region)
            labeledField("Access key ID", "AKIA…", text: $settings.accessKeyId)
            VStack(alignment: .leading, spacing: 6) {
                Text("Secret access key").strandOverline()
                SecureField(CloudSecretStore.read() != nil ? "•••••••• (stored)" : "Paste your S3 secret key", text: $secretDraft)
                    .textFieldStyle(.plain).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
                    .onSubmit(saveSecret)
                    .accessibilityLabel("S3 secret access key")
            }
            HStack {
                NoopButton("Save secret", systemImage: "key.fill", kind: .secondary, action: saveSecret)
                    .disabled(secretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Text(settings.isConfigured ? "Configured" : "Incomplete")
                    .font(StrandFont.caption)
                    .foregroundStyle(settings.isConfigured ? StrandPalette.statusPositive : StrandPalette.textTertiary)
            }
        }
    }

    private var retentionRow: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text("Keep on device").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Stepper(value: $settings.retentionDays, in: 14...365, step: 7) {
                    Text("\(settings.retentionDays) days").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
                .fixedSize()
            }
            Toggle(isOn: $settings.autoSync) {
                Text("Sync automatically").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
            }
            .toggleStyle(.switch).tint(StrandPalette.accent)
            .onChangeCompat(of: settings.autoSync) { on in
                if on { CloudSyncScheduler.activateIfEnabled() } else { CloudSyncScheduler.cancelSchedule() }
            }
            Text(autoSyncBlurb)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Honest per-platform copy about when automatic runs actually happen.
    private var autoSyncBlurb: String {
        #if os(iOS)
        return String(localized: "Runs about once a day: in the background while your iPhone charges on an unmetered network (when iOS allows), and as a catch-up when you open the app. Never over cellular.")
        #else
        return String(localized: "Runs about once a day while the app is open, over unmetered networks only.")
        #endif
    }

    private var actionButtons: some View {
        HStack {
            NoopButton("Test connection", systemImage: "checkmark.shield", kind: .secondary, action: { run(testConnection) })
                .disabled(busy || !settings.isConfigured)
            Spacer()
            NoopButton("Sync now", systemImage: "arrow.triangle.2.circlepath", kind: .primary, action: { run(syncNow) })
                .disabled(busy || !settings.isActive)
        }
    }

    @ViewBuilder private var statusReadout: some View {
        if let l = ledger {
            VStack(alignment: .leading, spacing: 4) {
                readoutRow("Uploaded objects", "\(l.uploadedObjects)")
                readoutRow("Verified", "\(l.verifiedObjects)")
                readoutRow("Pruned (space reclaimed locally)", "\(l.prunedObjects)")
                readoutRow("Uploaded size", ByteCountFormatter.string(fromByteCount: Int64(l.uploadedBytes), countStyle: .file))
                if let db = dbSize {
                    readoutRow("Local database", ByteCountFormatter.string(fromByteCount: db, countStyle: .file))
                }
                if let last = settings.lastSyncAt {
                    readoutRow("Last sync", last.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .padding(.top, 2)
        }
    }

    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                NoopButton("Delete remote data", systemImage: "trash", kind: .secondary, action: { showPurgeConfirm = true })
                    .disabled(busy || !settings.isConfigured)
                Spacer()
                NoopButton("Disable & forget key", systemImage: "xmark.icloud", kind: .secondary) {
                    settings.disableAndForget()
                    secretDraft = ""
                    status = "Cloud sync disabled. The stored secret was removed from the Keychain."
                }
            }
            .confirmationDialog("Delete every uploaded object from the bucket? This cannot be undone.",
                                isPresented: $showPurgeConfirm, titleVisibility: .visible) {
                Button("Delete remote data", role: .destructive) { run(purgeRemote) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Field helpers

    private func labeledField(_ label: LocalizedStringKey, _ placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StrandPalette.hairline, lineWidth: 1))
                #if os(iOS)
                .autocorrectionDisabled(true)
                .textInputAutocapitalization(.never)
                #endif
        }
    }

    private func readoutRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Text(value).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: - Actions

    private func saveSecret() {
        settings.saveSecret(secretDraft)
        secretDraft = ""
        status = "Secret saved to the Keychain."
    }

    private func run(_ op: @escaping () async -> Void) {
        busy = true
        Task {
            await op()
            await refreshStatus()
            busy = false
        }
    }

    private func testConnection() async {
        guard let config = settings.makeS3Config() else { status = "Fill in every field first."; return }
        do {
            try await S3Client(config: config).validateAccess()
            status = "Connection OK — the bucket is reachable and the credentials work."
        } catch {
            status = "Connection failed: \(error.localizedDescription)"
        }
    }

    private func syncNow() async {
        guard settings.isActive, let config = settings.makeS3Config(),
              let store = await model.repo.storeHandle() else {
            status = "Enable sync, grant consent, and finish configuration first."
            return
        }
        let uploader = CloudUploader(store: store, client: S3Client(config: config),
                                     deviceId: deviceId, retentionDays: settings.retentionDays)
        let report = await uploader.runOnce()
        settings.lastSyncAt = Date()
        status = "Synced: \(report.uploaded) uploaded, \(report.verified) verified, "
            + "\(report.prunedDays) day-streams pruned (\(report.rowsFreed) rows freed)"
            + (report.failures > 0 ? ", \(report.failures) failed" : "") + "."
    }

    private func purgeRemote() async {
        guard let config = settings.makeS3Config(), let store = await model.repo.storeHandle() else { return }
        let uploader = CloudUploader(store: store, client: S3Client(config: config),
                                     deviceId: deviceId, retentionDays: settings.retentionDays)
        let n = await uploader.purgeRemote()
        status = "Deleted \(n) remote object(s) from the bucket."
    }

    private func refreshStatus() async {
        guard let store = await model.repo.storeHandle() else { return }
        ledger = try? await store.cloudLedgerSummary(deviceId: deviceId)
        dbSize = await store.databaseFileSizeBytes()
    }
}
