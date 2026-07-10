import Foundation
#if os(iOS)
import BackgroundTasks
#endif

/// Automatic daily-ish cloud offload runs (docs/CLOUD_SYNC_PLAN.md §4 "Scheduling") — the piece that
/// makes offload + prune happen without the user remembering to tap "Sync now". Opt-in via
/// `CloudSyncSettings.autoSync`, default OFF like every NOOP automation, and inert unless cloud sync
/// is enabled + consented + configured (`isActive`).
///
/// HONEST about platform limits (mirrors ScheduledDebugExport):
/// - **macOS** — the app is usually running, so an hourly foreground timer plus a catch-up on
///   launch/foreground runs the pass reliably about once a day. Dependable.
/// - **iOS** — a `BGProcessingTaskRequest` gated on external power + network asks iOS to run the pass
///   while the phone charges; iOS decides when (and whether). The foreground catch-up on app open is
///   the guaranteed path, so a phone that never grants the background slot still syncs daily-ish.
///
/// Network gate: automatic runs use a URLSession that refuses expensive (cellular/hotspot) and
/// constrained (Low-Data-Mode) paths — the plan's "Wi-Fi only" posture without a private API. A run
/// attempted off Wi-Fi simply fails its requests and retries at the next due check; `lastAutoSyncAt`
/// is only advanced by a clean pass, so nothing is silently skipped. Manual "Sync now" keeps using
/// the unrestricted shared session — an explicit tap is the user's own call.
@MainActor
enum CloudSyncScheduler {

    /// iOS BGTask identifier. Must be listed in `BGTaskSchedulerPermittedIdentifiers` (project.yml +
    /// StrandiOS Info.plist) and registered at launch (`register()`) for iOS to deliver the task.
    static let bgTaskIdentifier = "com.jotsarup.noop.cloudsync"

    /// Run at most ~daily; 20 h (not 24) so a run that lands a little later each day can't drift
    /// forever past the user's routine charge window.
    static let minRunSpacing: TimeInterval = 20 * 3600

    private static weak var model: AppModel?
    private static var macTimer: DispatchSourceTimer?
    private static var running = false

    // MARK: - Wiring (app entry points call these)

    /// Give the scheduler its data source and arm the schedule. Idempotent — both entry points call
    /// it on launch, and the foreground handler may call it again.
    static func install(_ model: AppModel) {
        self.model = model
        activateIfEnabled()
    }

    /// (Re)arm the platform schedule and run a catch-up pass if one is due. Safe to call on every
    /// foreground; a no-op when auto-sync is off.
    static func activateIfEnabled() {
        guard CloudSyncSettings.shared.autoSync else { return }
        #if os(macOS)
        armMacTimerIfNeeded()
        #elseif os(iOS)
        submitBackgroundRequest()
        #endif
        Task { await runIfDue() }
    }

    /// Disarm everything (the auto-sync toggle turned off). Manual sync is untouched.
    static func cancelSchedule() {
        #if os(macOS)
        macTimer?.cancel()
        macTimer = nil
        #elseif os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: bgTaskIdentifier)
        #endif
    }

    // MARK: - Due check + the run itself

    /// Pure due predicate: never ran, or the spacing has elapsed. Static so it's unit-testable
    /// without a clock or settings.
    nonisolated static func isDue(last: Date?, now: Date, spacing: TimeInterval = minRunSpacing) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= spacing
    }

    /// One guarded automatic pass: only when active + opted-in + due, never reentrantly. Advances
    /// `lastAutoSyncAt` only when the pass made progress or completed clean, so a fully-failed run
    /// (offline, cellular-only) retries at the next foreground/timer tick instead of waiting a day.
    static func runIfDue(now: Date = Date()) async {
        let settings = CloudSyncSettings.shared
        guard settings.autoSync, settings.isActive, !running,
              isDue(last: settings.lastAutoSyncAt, now: now),
              let model, let config = settings.makeS3Config(),
              let store = await model.repo.storeHandle() else { return }
        running = true
        defer { running = false }

        let deviceId = model.deviceRegistry?.activeDeviceId ?? "my-whoop"
        let client = S3Client(config: config, session: Self.unmeteredSession)
        let uploader = CloudUploader(store: store, client: client, deviceId: deviceId,
                                     retentionDays: settings.retentionDays)
        let report = await uploader.runOnce()
        if report.failures == 0 || report.uploaded > 0 || report.verified > 0 {
            settings.lastSyncAt = now
            settings.lastAutoSyncAt = now
        }
    }

    /// Refuses expensive (cellular/personal-hotspot) and constrained (Low Data Mode) network paths,
    /// so an automatic run can only ever move health data over an unmetered link.
    private static let unmeteredSession: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.allowsExpensiveNetworkAccess = false
        cfg.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: cfg)
    }()

    // MARK: - macOS foreground timer

    #if os(macOS)
    /// Hourly repeating tick; `runIfDue`'s spacing guard makes it a daily-ish run. Armed once.
    private static func armMacTimerIfNeeded() {
        guard macTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3600, repeating: 3600)
        timer.setEventHandler { Task { await runIfDue() } }
        timer.resume()
        macTimer = timer
    }
    #endif

    // MARK: - iOS background task plumbing

    #if os(iOS)
    /// Register the BGTask handler. MUST be called before app launch finishes (StrandiOSApp.init)
    /// AND the identifier listed in `BGTaskSchedulerPermittedIdentifiers`. Safe to leave uncalled:
    /// `submit` fails gracefully and the foreground catch-up still runs.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier, using: nil) { task in
            let work = Task { @MainActor in
                await runIfDue()
                submitBackgroundRequest()   // single-shot: queue the next slot
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            // On expiry, cancel and let the pass stop at its next day boundary (CloudUploader checks
            // Task.isCancelled); every already-verified upload/prune is durable, so a cut-short run
            // simply resumes where it left off next time.
            task.expirationHandler = { work.cancel() }
        }
    }

    /// Ask iOS for a charging + network processing slot no earlier than the next due time. iOS
    /// decides when (and whether) to grant it — the foreground catch-up covers a phone that never
    /// gets one. `try?` swallows the not-permitted error on builds without the Info.plist wiring.
    private static func submitBackgroundRequest() {
        let request = BGProcessingTaskRequest(identifier: bgTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        let dueAt = CloudSyncSettings.shared.lastAutoSyncAt.map { $0.addingTimeInterval(minRunSpacing) } ?? Date()
        request.earliestBeginDate = max(dueAt, Date(timeIntervalSinceNow: 3600))
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}
