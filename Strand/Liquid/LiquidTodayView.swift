//  LiquidTodayView.swift
//  NOOP · Liquid design language — the Today screen, rebuilt in the liquid finish.
//
//  This is the FULL Today, re-created faithfully from the locked mockup
//  (scratchpad/liquid-metal-home.html): sky title + record/add/battery controls,
//  the three scores as liquid vessels with source pills, the live heart-rate
//  thread, the five "your cards" as liquid chips, a greeting + readiness pills,
//  Synthesis, Recovery Vitals, a Key Metrics grid (incl. steps), Last Workouts
//  and Data Sources. Every value binds to the SAME real data the classic
//  TodayView reads (accessors verified against TodayView.swift), and every tap
//  routes to the same public destination. The sky is a fixed, full-bleed
//  background (edge-to-edge under the status bar, does not scroll).

import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics

struct LiquidTodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var profile: ProfileStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var power = LiquidPower.shared

    /// Shared with the real Today's card-customise editor so the two stay in sync.
    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""

    // async-loaded via the confirmed Repository accessors
    @State private var restScore: Double?          // sleep_performance, day-keyed
    @State private var stress: Double?             // StressModel(...).score, 0–3
    @State private var stressDay: String?          // the day that score describes (StressModel.asOfDay)
    @State private var fitnessAge: Double?         // exploreSeries("fitness_age").last
    @State private var vitality: Double?           // exploreSeries("vitality").last
    @State private var fitnessAgeDay: String?      // the day those weekly values were banked
    @State private var vitalityDay: String?
    /// Today's logical day key; a change (04:00 rollover seen on foreground or at midnight) reloads.
    @State private var logicalToday = Repository.logicalDayKey(Date())
    @Environment(\.scenePhase) private var scenePhase
    @State private var stepsEst: Double?           // steps_est, day-keyed to the selected day (fallback)
    @State private var hrValues: [Double] = []     // hrBuckets since midnight → 5-min means
    @State private var hrPoints: [TrendPoint] = [] // the same buckets with their times, for the HR chart
    @State private var workouts: [WorkoutRow] = [] // newest-first
    // History-wide series cached by `loadHistory()`, which runs only when the repository refreshes. A day
    // swipe used to re-read and re-sort them, plus 4,000 days of workouts, on the main actor each time.
    @State private var restByDay: [String: Double] = [:]
    @State private var restLast: (day: String, value: Double)?
    @State private var stepsByDay: [String: Double] = [:]
    @State private var stepsLast: Double?
    /// 7-day series (oldest first) ending on the selected day, for the tiles' mini charts. Built in load().
    /// One slot per calendar day (nil = no reading), so a gap stays a gap in the mini charts.
    @State private var weekHrv: [Double?] = []
    @State private var weekRhr: [Double?] = []
    @State private var weekResp: [Double?] = []
    @State private var weekSteps: [Double?] = []
    /// The days before the selected day inside the same 7-day window, for the "vs 7 days" captions.
    @State private var priorHrv: [Double] = []
    @State private var priorRhr: [Double] = []

    // sheets / expanders
    @State private var guideSection: ScoreSection?
    @State private var showChargeDetail = false
    @State private var showCustomise = false
    @State private var showSettings = false
    @State private var showSupport = false
    @State private var synthesisExpanded = false
    @State private var showLiveSession = false

    /// Live Sessions (silent guardian) beta gate — the SAME key the Settings toggle writes. Default ON
    /// (the entry is BETA-labelled in-UI); off removes the Start-session control entirely.
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true

    // day navigation (0 = today, 1 = yesterday, …)
    @State private var selectedDayOffset = 0
    @State private var showDayPicker = false

    // PERF: the body was rescanning repo.days (599 days) ~23× per pass for displayDay and ~3× for
    // readiness on EVERY re-render (every HR notify, every canvas frame that invalidates, every scroll).
    // Resolve both ONCE per data/day change in load() and read the cache in body (O(1)).
    @State private var cachedDisplayDay: DailyMetric?
    @State private var cachedReadiness: ReadinessEngine.Readiness?
    /// The recovery-INDEPENDENT prior-day vitals carry (HRV / RHR / respiratory), resolved ONCE in load()
    /// alongside cachedDisplayDay. Fixes the v8 rollover blank: after 04:00, before tonight's sleep scores,
    /// today's row has no vitals yet, so these fall back to the last night that recorded them. Never
    /// resolved in body — body rescans repo.days ~23× per pass, and this cache keeps that read O(1).
    @State private var cachedVitalsDay: DailyMetric?
    /// Flips true once the first load() completes. Until then the hero gauges + sky render STATIC so the
    /// launch data-churn (refresh publish + BLE/HR notifies) isn't fighting 4 live canvases + CoreMotion.
    @State private var dataLoaded = false
    /// True once the hero band (scores + HR thread) has scrolled well out of the viewport. TimelineView
    /// keeps ticking on clipped-out views, so without this the hero vessels + thread kept animating at
    /// full rate while the user read Key Metrics at the bottom. Driven from the same scroll-offset
    /// preference the pull-to-refresh uses, with a hysteresis band so it can't flap at the boundary;
    /// flipping swaps the leaves to their cached static renders (`animated: false`).
    @State private var heroOffscreen = false

    // Custom liquid pull-to-refresh: a vessel that FILLS as you drag, releases into a refresh (replaces
    // the system spinner). Driven by the scroll's top overscroll offset.
    //
    // The pull offset changes every frame while you drag. Held here as a plain `@State` object (NOT
    // `@StateObject`), this view does NOT subscribe to its `objectWillChange`, so a pull no longer
    // re-evaluates the entire dashboard body per frame — only `LiquidRefreshIndicator`, which observes
    // it, redraws. (U8) Firing the refresh calls back into `fireRefresh()`.
    @State private var pull = LiquidPullState()

    /// Mock Vitality purple (#9b7bff) has no exact StrandPalette token in this theme.
    private let liquidPurple = StrandPalette.accent
    /// The liquid heart pink (matches LiquidThread's default + the mockup #ff6b81).
    private let liquidHeart = StrandPalette.accent
    /// Hero card fill: a translucent near-black so it floats over the sky (mock rgba(13,14,20,.78)).
    private let heroFill = StrandPalette.surfaceRaised

    // MARK: - Day navigation (ported from classic Today: swipe + calendar, day-keyed reads)

    /// The logical day the selector resolves to (offset 0 = today's logical day, rolls at 04:00).
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    /// The day key the day-scoped read-outs key on. At offset 0 follows repo.today?.day.
    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }
    /// The DailyMetric shown for the selected day — read from the cache resolved in load() (was an
    /// O(days) `.last(where:)` scan referenced ~23× per body pass; now O(1)).
    private var displayDay: DailyMetric? { cachedDisplayDay }
    /// The prior-day vitals carry (see `cachedVitalsDay`), read O(1) from the cache. Non-nil only at
    /// offset 0 (today); a navigated past day carries nothing (its own row is the whole story).
    private var vitalsDay: DailyMetric? { cachedVitalsDay }

    /// Cold-start Charge calibration progress (WS-3c): how many of the seed nights of usable HRV are
    /// banked up to the displayed day, so "Calibrating" carries a concrete "N of 4" count instead of
    /// an opaque state. nil once Charge exists (the pill reads "Solid") or no usable HRV night exists
    /// yet (still "Calibrating", 0 of N). Since HRV needs the R22 R-R stream, this clock only advances
    /// once R22 is enabled — exactly the confusion the count resolves ("field hasn't come / is it broken?").
    private var chargeCalibration: (n: Int, seed: Int)? {
        guard displayDay?.recovery == nil else { return nil }
        let upTo = displayDay?.day
        let hrv: [Double?] = repo.days
            .filter { upTo == nil || $0.day <= upTo! }
            .map { $0.avgHrv }
        let seed = Baselines.minNightsSeed
        guard let n = RecoveryScorer.calibrationNights(nightlyHrv: hrv, hasRecovery: false, seed: seed) else {
            return nil
        }
        return (n, seed)
    }

    /// The Charge status-pill text: the calibrating "N of 4" count while cold-starting, else Solid /
    /// Calibrating. Whole-phrase variants so translators never see a stitched count.
    private var chargeStatusText: String {
        if let c = chargeCalibration { return String(localized: "Calibrating · \(c.n) of \(c.seed)") }
        return displayDay?.recovery != nil ? String(localized: "Solid") : String(localized: "Calibrating")
    }

    /// A one-line "how close to your first Charge" note shown under the synthesis card while
    /// calibrating (WS-3c). Whole-phrase variants per remaining-night count; nil once Charge exists.
    private var chargeCalibrationNote: String? {
        guard let c = chargeCalibration else { return nil }
        let remaining = max(0, c.seed - c.n)
        switch remaining {
        case 0:  return String(localized: "Your first Charge unlocks after tonight's sleep.")
        case 1:  return String(localized: "1 more night of HRV to your first Charge.")
        default: return String(localized: "\(remaining) more nights of HRV to your first Charge.")
        }
    }

    /// The actual O(days) resolution. Offset 0 prefers live repo.today; past offsets look up. Run ONCE
    /// per data/day change from load(), never from body.
    private func resolveDisplayDay() -> DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }
    /// How far back navigation can go (whole days from the earliest banked day to today).
    private var earliestDayOffset: Int {
        Self.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                          todayKey: Repository.logicalDayKey(Date()))
    }
    /// The big header title: Today / Yesterday / weekday for older days.
    private var dayTitle: String {
        switch selectedDayOffset {
        case 0: return "Today"
        case 1: return "Yesterday"
        default:
            return Self.weekdayFormatter.string(from: selectedLogicalDay)
        }
    }
    /// Two-way binding for the graphical calendar: reads the shown day, writes back an offset.
    private var dayPickerBinding: Binding<Date> {
        Binding(
            get: { selectedLogicalDay },
            set: { newValue in
                selectedDayOffset = Self.pickedDayOffset(pickedDate: newValue,
                                                         anchorLogicalDay: Repository.logicalDay(Date()))
                showDayPicker = false
            }
        )
    }
    /// Horizontal swipe between days (left = older, right = newer), clamped to [today, earliest].
    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                let delta = dx < 0 ? 1 : -1
                let next = Self.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                 maxOffset: earliestDayOffset)
                guard next != selectedDayOffset else { return }
                withAnimation(StrandMotion.interactive) { selectedDayOffset = next }
            }
    }

    static func clampedDayOffset(current: Int, delta: Int, maxOffset: Int) -> Int {
        min(max(0, maxOffset), max(0, current + delta))
    }
    static func maxDayOffset(earliestDayKey: String?, todayKey: String) -> Int {
        guard let earliestKey = earliestDayKey,
              let earliest = dayKeyParser.date(from: earliestKey),
              let today = dayKeyParser.date(from: todayKey) else { return 0 }
        let gap = Calendar.current.dateComponents([.day],
                                                  from: Calendar.current.startOfDay(for: earliest),
                                                  to: Calendar.current.startOfDay(for: today)).day ?? 0
        return max(0, gap)
    }
    static func pickedDayOffset(pickedDate: Date, anchorLogicalDay: Date) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: pickedDate),
                                      to: cal.startOfDay(for: anchorLogicalDay)).day ?? 0
        return max(0, days)
    }
    // Formatters are built once: creating them inside body-time properties cost a formatter per render.
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEEE"; return f
    }()
    private static let dateLineFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEEE, d MMMM"; return f
    }()
    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter(); f.numberStyle = .decimal; return f
    }()
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Scroll-offset probe at the very top (before padding), so its minY in the scroll's
                // coordinate space reads the top OVERSCROLL: ~0 at rest, positive as you pull down.
                GeometryReader { g in
                    Color.clear.preference(key: PullOffsetKey.self,
                                           value: g.frame(in: .named(Self.pullSpace)).minY)
                }
                .frame(height: 0)

                LiquidRefreshIndicator(pull: pull, tint: liquidHeart)   // grows in the revealed space; a vessel filling with the pull

                // Minimal layout (2026-10-21): scores + verdict, a tile grid with mini charts, then the
                // detail sections. Recovery vitals and the synthesis card folded into the tiles/verdict.
                VStack(alignment: .leading, spacing: 12) {
                    scene
                    keyMetricsSection
                    heartRateSection
                    yourCardsSection
                    lastWorkoutsSection
                    dataSourcesSection
                    Color.clear.frame(height: 90) // floating tab-bar clearance
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            #if os(macOS)
            // Keep the phone-shaped column readable + centred on the wide mac detail pane. The sky is a
            // ScrollView background (full-bleed), so constraining the content column here doesn't touch it.
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            #endif
        }
        .coordinateSpace(name: Self.pullSpace)
        .onPreferenceChange(PullOffsetKey.self) { y in
            // This fires on every frame the content moves (drag AND deceleration) — exactly the window
            // the live canvases should stand down for. Stamping the gate is a plain property write
            // (never publishes); the canvases poll it from their draw closures.
            LiquidScrollGate.shared.stamp()
            pull.update(y) { fireRefresh() }
            // Hero-band visibility, with hysteresis (writes only on a crossing, never per frame).
            // -700 puts the hero scores AND the HR thread card fully above the viewport.
            if heroOffscreen {
                if y > -640 { heroOffscreen = false }
            } else if y < -700 {
                heroOffscreen = true
            }
        }
        // The sky is a FIXED full-bleed backdrop drawn behind the scroll content, edge-to-edge under the
        // status bar. A ScrollView background does not scroll with the content, so pulling down never
        // moves the sky (the exact behaviour the scaffold uses on the classic Today).
        // Flat canvas (minimal redesign): no sky.
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // Swipe left/right to change DAYS (WHOOP-style). Tab-swipe is disabled on Today in RootTabView so
        // this owns the horizontal gesture here.
        .simultaneousGesture(daySwipeGesture)
        // A light tick when the day changes (swipe or calendar pick) — the WHOOP-style day nav should
        // feel physical ("every tiny little thing").
        .liquidSelectionHaptic(trigger: selectedDayOffset)
        .task(id: repo.refreshSeq) { await loadHistory() }
        .task(id: "\(repo.refreshSeq)-\(selectedDayOffset)-\(logicalToday)") { await load() }
        // Day rollover: the data may not change overnight (strap off), so key the load on the day too.
        .onChangeCompat(of: scenePhase) { phase in
            guard phase == .active else { return }
            let k = Repository.logicalDayKey(Date())
            if k != logicalToday { logicalToday = k }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            logicalToday = Repository.logicalDayKey(Date())
        }
        .sheet(item: $guideSection) { section in
            NavigationStack { ScoringGuideView(initialSection: section, onClose: { guideSection = nil }) }
        }
        .sheet(isPresented: $showChargeDetail) {
            NavigationStack { chargeDetail }
        }
        .sheet(isPresented: $showCustomise) {
            DashboardCardsEditorSheet(selectionRaw: $dashboardCardsRaw)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .liquidSheetDoneChrome { showSettings = false }
            }
        }
        // The heart opens the Support sheet.
        .sheet(isPresented: $showSupport) {
            NavigationStack {
                SupportView()
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .liquidSheetDoneChrome { showSupport = false }
            }
        }
        // Live Session (silent guardian, beta): the in-session screen owns the whole display — full
        // screen on iOS (nothing should compete with the ring mid-workout), a sheet on macOS where
        // fullScreenCover doesn't exist.
        .liveSessionCover(isPresented: $showLiveSession)
        #if os(macOS)
        // Hide the mac window toolbar's vibrant material so the full-bleed day-of-sky reads dark + edge-to-edge
        // at the top instead of the white scroll-under-titlebar wash.
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
    }

    // MARK: - Liquid pull-to-refresh

    static let pullSpace = "liqTodayScroll"

    /// Run the actual refresh once the release has fired. Kept on the root because it drives the shared
    /// repository + day reload; `pull.finishRefreshing()` clears the spinner when the reload settles.
    private func fireRefresh() {
        Task { @MainActor in
            await repo.refresh()
            await load()
            try? await Task.sleep(nanoseconds: 350_000_000)   // let the fill read as "done"
            pull.finishRefreshing()
        }
    }

    // MARK: - Scene (sky title + controls + hero)

    private var scene: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Button { showDayPicker = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dayTitle)
                            .font(StrandFont.rounded(28))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(dateLine)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(dayTitle). Tap to pick a day, swipe to change day.")
                .popover(isPresented: $showDayPicker) {
                    DatePicker("", selection: dayPickerBinding, in: ...Repository.logicalDay(Date()),
                               displayedComponents: [.date])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(12)
                        .frame(minWidth: 320, minHeight: 360)
                        .liquidPopoverAdaptation()
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    // Support: a tap opens project info, attribution, and contact.
                    Button { showSupport = true } label: {
                        Image(systemName: "heart")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("Support NOOP: help and contact.")
                    // Profile pic (the one set in Settings) → opens Settings, matching the classic Today.
                    Button { showSettings = true } label: {
                        ProfileAvatarView(imageData: profile.avatarImageData, size: 34)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("Profile and settings")
                    LiquidAddButton()
                    LiquidBatteryButton()
                }
            }
            heroCard.padding(.top, 18)
            verdict.padding(.top, 10)
            if liveSessionsBeta {
                liveSessionStartRow.padding(.top, 10)
            }
        }
    }

    /// One-tap Live Session start (silent guardian, beta) — sits directly under the hero scores, the
    /// Charge its band is gated on. Same translucent chrome as the hero card so it reads as part of the
    /// sky scene, quiet by design.
    private var liveSessionStartRow: some View {
        Button { showLiveSession = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.metricCyan)
                Text("Start session")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("BETA")
                    .font(StrandFont.overlineScaled(8.5)).tracking(1.2)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 2.5)
                    .background(Capsule().strokeBorder(StrandPalette.hairlineStrong, lineWidth: 0.5))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frostedCardSurface()
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Start a live session. Beta. Silent strap coaching against today's Charge.")
    }

    /// Three flat score rings on the canvas (minimal redesign). Tap a ring for its scoring guide.
    private var heroCard: some View {
        HStack(alignment: .top, spacing: 0) {
            MinimalScoreCell(label: "Charge", score: displayDay?.recovery, tint: StrandPalette.chargeColor,
                             onGuide: { showChargeDetail = true })
            MinimalScoreCell(label: "Effort", score: displayDay?.strain, tint: StrandPalette.effortColor,
                             // The ring prints whole numbers on 0–100; only the 0–21 scale needs the converter.
                             text: effortScale == .hundred
                                 ? nil : displayDay?.strain.map { UnitFormatter.effortDisplay($0, scale: effortScale) },
                             onGuide: { guideSection = .effort })
            MinimalScoreCell(label: "Rest", score: restScore, tint: StrandPalette.restColor,
                             onGuide: { guideSection = .rest })
        }
    }

    /// The Charge ring's detail page. Built only while the sheet is open: the drivers fold the HRV, RHR
    /// and breathing baselines from repo.days (the inputs the score used), which is too much for body.
    private var chargeDetail: some View {
        let row = displayDay
        var drivers: [ChargeDriver] = []
        // Fold only the nights before this one, with the engine's recalibration epochs, so the drivers
        // explain the score the ring shows (folding every day, this night included, explained another).
        let prior = repo.days.filter { $0.day < (row?.day ?? selectedDayKey) }.sorted { $0.day < $1.day }
        let keys = prior.map(\.day)
        let epoch = Baselines.recoveryBaselineEpoch()
        let hrvBase = Baselines.foldHistory(prior.map(\.avgHrv), dayKeys: keys, cfg: Baselines.hrvCfg)
        if let row, let hrv = row.avgHrv, let rhr = row.restingHr, hrvBase.usable {
            let rhrBase = Baselines.foldHistory(prior.map { $0.restingHr.map(Double.init) }, dayKeys: keys,
                                                cfg: Baselines.restingHRCfg, baselineEpoch: epoch)
            let respBase = Baselines.foldHistory(prior.map(\.respRateBpm), dayKeys: keys,
                                                 cfg: Baselines.respCfg, baselineEpoch: epoch)
            drivers = RecoveryScorer.chargeDrivers(
                hrv: hrv, rhr: Double(rhr), resp: row.respRateBpm,
                hrvBaseline: hrvBase,
                rhrBaseline: rhrBase.usable ? rhrBase : nil,
                respBaseline: respBase.usable ? respBase : nil,
                sleepPerf: restScore.map { $0 / 100.0 }, skinTempDev: row.skinTempDevC)
        }
        return ScoreDetailView(
            title: String(localized: "Charge"), score: row?.recovery, tint: StrandPalette.chargeColor,
            verdict: synthLine, note: chargeCalibrationNote, drivers: drivers,
            confidence: ScoreConfidence.charge(recovery: row?.recovery, hrvBaseline: hrvBase),
            skinTempRel: RecoveryScorer.skinTempRelative(deviationC: row?.skinTempDevC),
            guide: .charge, onClose: { showChargeDetail = false })
    }

    /// One sentence under the rings: the synthesis line, plus the cold-start note while Charge warms up.
    private var verdict: some View {
        VStack(spacing: 4) {
            Text(synthLine)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if selectedDayOffset == 0, let note = chargeCalibrationNote {
                Text(note).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Heart rate

    private var heartRateSection: some View {
        VStack(spacing: 8) {
            sectionHead("HEART RATE", trailing: "Live")
            // #979: the whole-day HR trend (Deep Timeline) still exists but was buried behind Metrics →
            // Show all → Deep Timeline. Make the live HR card a one-tap route into it, with a visible
            // "Full day" affordance so it's discoverable again. (This comment used to claim the Deep
            // Timeline already drew sleep + activity bands — it didn't at the time; the #979 spin-off
            // added that parity in FullDayChartView.)
            // Only the "Full day" row is the link, so pressing and dragging on the chart scrubs it
            // instead of opening the timeline on release.
            card {
                VStack(spacing: 10) {
                    // Isolated leaf: it observes LiveState so the ~1 Hz HR notifies re-render ONLY
                    // this card, never the whole Today. Shows the current bpm live with a rolling
                    // beat-by-beat trace; falls back to today's banked 5-minute chart when idle.
                    LiquidLiveHR(tint: liquidHeart, fallback: hrValues, points: hrPoints,
                                 allowLive: selectedDayOffset == 0, animated: dataLoaded && !heroOffscreen)
                    NavigationLink {
                        FullDayChartView(dayStart: selectedDayOffset == 0
                                         ? nil : Calendar.current.startOfDay(for: selectedLogicalDay))
                    } label: {
                        HStack(spacing: 4) {
                            Spacer()
                            Text("Full day").font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(StrandPalette.accent)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the full-day heart rate timeline")
                }
            }
        }
    }

    // MARK: - Your cards

    private var yourCardsSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text("YOUR CARDS").font(StrandFont.overline).tracking(1.6)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Button { showCustomise = true } label: {
                    Text("CUSTOMISE").font(StrandFont.overlineScaled(11)).tracking(1.0)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)

            // Data-driven off the SAME @AppStorage the CUSTOMISE editor writes, so add / remove /
            // reorder in Customise reflects on the home screen live.
            ForEach(DashboardCardPrefs.decodeEnabled(dashboardCardsRaw)) { card in
                liquidCard(for: card)
            }
        }
    }

    /// One "Your cards" row for a given card type — honours the user's CUSTOMISE selection + order.
    /// Wired cards show real values; the rest render "–" for now (they still appear, so add/remove/
    /// reorder is reflected). stress → Stress screen, sleep → Sleep, everything else → Health.
    @ViewBuilder
    private func liquidCard(for card: DashboardCard) -> some View {
        switch card {
        case .stress:
            cardLink(dest: StressView(), title: card.title, sub: card.subtitle,
                     value: stressText, tint: StrandPalette.accent, frac: fracOver(stress, 3))
        case .fitnessAge:
            cardLink(dest: metricDetail("fitness_age"), title: card.title,
                     sub: weeklySubtitle(card.subtitle, fitnessAgeDay),
                     value: unitText(fitnessAge, card.unit), tint: StrandPalette.chargeColor, frac: nil)
        case .vitality:
            cardLink(dest: metricDetail("vitality"), title: card.title,
                     sub: weeklySubtitle(card.subtitle, vitalityDay),
                     value: intText(vitality), tint: liquidPurple, frac: frac(vitality))
        case .hrv:
            cardLink(dest: metricDetail("hrv"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.avgHrv, card.unit), tint: StrandPalette.metricCyan,
                     frac: fracOver(displayDay?.avgHrv, 120))
        case .restingHr:
            cardLink(dest: metricDetail("rhr"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.restingHr.map(Double.init), card.unit),
                     tint: StrandPalette.metricRose, frac: fracOver(displayDay?.restingHr.map(Double.init), 100))
        case .respiratory:
            cardLink(dest: metricDetail("resp_rate"), title: card.title, sub: card.subtitle,
                     value: unitText(displayDay?.respRateBpm, card.unit, decimals: 1),
                     tint: StrandPalette.accent, frac: fracOver(displayDay?.respRateBpm, 24))
        case .steps:
            cardLink(dest: metricDetail("steps_est"), title: card.title, sub: card.subtitle,
                     value: stepsText, tint: StrandPalette.metricCyan, frac: fracOver(stepCount, 10000))
        case .bloodOxygen:
            // Not wired to a real read yet — render EMPTY (not half-full) so it doesn't imply a reading.
            cardLink(dest: metricDetail("spo2"), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricCyan, frac: nil)
        case .skinTemp:
            cardLink(dest: metricDetail("skin_temp"), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricAmber, frac: nil)
        case .calories:
            cardLink(dest: metricDetail("active_kcal"), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricAmber, frac: nil)
        case .sleep:
            cardLink(dest: SleepView(), title: card.title, sub: card.subtitle,
                     value: sleepText, tint: StrandPalette.restColor, frac: fracOver(displayDay?.totalSleepMin, 480))
        case .hydration:
            cardLink(dest: HydrationView(), title: card.title, sub: card.subtitle,
                     value: "–", tint: StrandPalette.metricCyan, frac: nil)
        case .coupled:
            // A tap-through to the full Coupled day screen. No value.
            cardLink(dest: CoupledView(), title: card.title, sub: card.subtitle,
                     value: "", tint: StrandPalette.chargeColor, frac: 0.6)
        }
    }

    /// The per-metric detail page (its own data screen with chart + history), looked up by catalog key.
    /// Each card opens ITS metric (2026-07-02: not the shared Health screen). Falls back to Health
    /// only if the key is somehow absent from the catalog.
    @ViewBuilder
    private func metricDetail(_ key: String) -> some View {
        if let m = MetricCatalog.all.first(where: { $0.key == key }) {
            MetricDetailView(metric: m)
        } else {
            HealthView()
        }
    }

    private func cardLink<Dest: View>(dest: Dest, title: String, sub: String,
                                      value: String, tint: Color, frac: Double?) -> some View {
        NavigationLink { dest } label: {
            HStack(spacing: 12) {
                LiquidVessel(value: frac, tint: tint, animated: false).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.uppercased()).font(StrandFont.overlineScaled(11)).tracking(1.0)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(sub).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Text(value).font(StrandFont.number(17)).foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(StrandPalette.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1))
            )
        }
        .buttonStyle(LiquidPressStyle())
    }

    // MARK: - Synthesis (greeting + readiness pills + one-liner)

    private var synthesisSection: some View {
        VStack(spacing: 8) {
            HStack {
                Text(greeting).font(StrandFont.rounded(19)).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.6)   // yield to the pills rather than push them to wrap
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if let word = readinessWord {
                        Text(word)
                            .font(StrandFont.caption.weight(.bold))
                            .foregroundStyle(StrandPalette.chargeColor)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(StrandPalette.chargeColor.opacity(0.14))
                                .overlay(Capsule().strokeBorder(StrandPalette.chargeColor.opacity(0.3), lineWidth: 1)))
                    }
                    HStack(spacing: 5) {
                        Circle().fill(StrandPalette.chargeColor).frame(width: 6, height: 6)
                        Text(chargeStatusText)
                            .font(StrandFont.caption.weight(.bold))
                            .foregroundStyle(StrandPalette.chargeColor)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().strokeBorder(StrandPalette.chargeColor.opacity(0.3), lineWidth: 1))
                }
                .fixedSize(horizontal: true, vertical: false)   // pills keep their natural width — no "Calibrating" wrap
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)

            Button { withAnimation(.easeInOut(duration: 0.2)) { synthesisExpanded.toggle() } } label: {
                card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("SYNTHESIS").font(StrandFont.overline).tracking(1.6)
                                .foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            Text(synthesisExpanded ? "hide" : "show").font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Text(synthLine).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if synthesisExpanded {
                            Text(readiness.summary).font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())

            // While Charge is still cold-starting, a concrete "N more nights" note so a missing Charge
            // reads as "still warming up" rather than "broken" (WS-3c).
            if let note = chargeCalibrationNote {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.chargeColor)
                    Text(note).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: - Recovery vitals

    private var recoveryVitalsSection: some View {
        // PER-FIELD, today-first carry: each vital reads today's own value, else falls back to the prior
        // day that recorded it (`vitalsDay`). Coalesce ONCE so the number and its fill fraction agree.
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("RECOVERY VITALS").font(StrandFont.overline).tracking(1.6)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    if let line = vitalsProvenanceLine {
                        Text(line).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                vitalRow("Heart-rate variability", unitText(hrv, "ms"),
                         StrandPalette.metricCyan, fracOver(hrv, 120))
                vitalRow("Resting heart rate", unitText(rhr, "bpm"),
                         StrandPalette.metricRose, fracOver(rhr, 100))
                vitalRow("Breaths per minute", unitText(resp, "rpm", decimals: 1),
                         StrandPalette.accent, fracOver(resp, 24))
            }
        }
    }

    private func vitalRow(_ label: String, _ value: String, _ tint: Color, _ frac: Double?) -> some View {
        HStack(spacing: 12) {
            LiquidVessel(value: frac, tint: tint, animated: false).frame(width: 26, height: 26)
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    // MARK: - Key metrics grid

    private var keyMetricsSection: some View {
        // HRV / Rest HR / breathing share the per-field today-first carry so they don't blank at the
        // rollover; sleep and steps stay strictly the selected day's own.
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
        // A value carried from an earlier night says which night, instead of a delta that would compare
        // that night with itself.
        let carriedFrom = vitalsDay.map { "From \(Self.shortDayLabel($0.day))" }
        let hrvCarried = displayDay?.avgHrv == nil && vitalsDay?.avgHrv != nil
        let rhrCarried = displayDay?.restingHr == nil && vitalsDay?.restingHr != nil
        let respCarried = displayDay?.respRateBpm == nil && vitalsDay?.respRateBpm != nil
        return VStack(spacing: 8) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                tile("HRV", intText(hrv), "ms",
                     caption: hrvCarried ? (carriedFrom ?? "") : deltaCaption(hrv, priorHrv, unit: "ms")) {
                    MinimalLine(slots: weekHrv, minSpan: 8)
                }
                tile("Resting HR", intText(rhr), "bpm",
                     caption: rhrCarried ? (carriedFrom ?? "") : deltaCaption(rhr, priorRhr, unit: "")) {
                    MinimalLine(slots: weekRhr, minSpan: 6)
                }
                tile("Sleep", sleepText, "", caption: sleepWindowCaption) { sleepStageBar }
                tile("Steps", stepsText, "", caption: weekAverageCaption(weekSteps)) {
                    MiniBars(values: weekSteps)
                }
                tile("Breathing", unitText(resp, "", decimals: 1), "rpm",
                     caption: respCarried ? (carriedFrom ?? "") : "During sleep") {
                    MinimalLine(slots: weekResp, minSpan: 2)
                }
                tile("Stress", stressWord, "",
                     caption: selectedDayOffset == 0 ? "Today" : Self.shortDayLabel(selectedDayKey)) {
                    MinimalBar(frac: stressDay == selectedDayKey ? (stress ?? 0) / 3 : 0, height: 6)
                        .padding(.top, 14)
                }
            }
            NavigationLink { MetricExplorerView() } label: {
                Text("Show all metrics").font(StrandFont.subhead).foregroundStyle(StrandPalette.accent)
                    .frame(maxWidth: .infinity).padding(.top, 2)
            }
            .buttonStyle(.plain)
        }
    }

    /// A metric tile: small label, big value, a 34pt mini chart, one caption line.
    private func tile<Chart: View>(_ label: String, _ value: String, _ unit: String, caption: String,
                                   @ViewBuilder chart: () -> Chart) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(StrandFont.overlineScaled(10)).tracking(1.0)
                .foregroundStyle(StrandPalette.textTertiary)
            (Text(value).font(StrandFont.number(22))
                + Text(unit.isEmpty ? "" : " \(unit)").font(StrandFont.caption)
                    .foregroundColor(StrandPalette.textSecondary))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            chart().frame(height: 34)
            Text(caption).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedCardSurface()
    }

    /// The night's stages as one segmented bar (deep, light, REM), shades of the accent.
    private var sleepStageBar: some View {
        let d = displayDay
        let parts: [(Double, Color)] = [(d?.deepMin ?? 0, StrandPalette.sleepDeep),
                                        (d?.lightMin ?? 0, StrandPalette.sleepLight),
                                        (d?.remMin ?? 0, StrandPalette.sleepREM)]
        let total = parts.reduce(0) { $0 + $1.0 }
        return GeometryReader { geo in
            HStack(spacing: 2) {
                if total > 0 {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                        Rectangle().fill(p.1).frame(width: max(0, geo.size.width * p.0 / total - 2))
                    }
                } else {
                    Rectangle().fill(StrandPalette.hairline)
                }
            }
            .frame(height: 8)
            .clipShape(Capsule())
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private var sleepWindowCaption: String {
        guard let m = displayDay?.efficiency else { return "Last night" }
        return "\(Int((m * 100).rounded()))% efficient"
    }

    /// Stress for the selected day only: the model's score describes its newest day with a signal,
    /// which can be weeks old, and must not be shown as this day's.
    private var stressWord: String {
        guard let v = stress, stressDay == selectedDayKey else { return "–" }
        switch v { case ..<1: return "Calm"; case ..<2: return "Moderate"; default: return "High" }
    }

    /// The rows inside the 7 calendar days ending on `day` (oldest first). A gap in the history stays
    /// a gap: taking the last 7 rows instead reached back months when the strap was off for a while,
    /// so "vs 7 days" compared last night with old naps.
    static func calendarWeek(_ days: [DailyMetric], endingOn day: String) -> [DailyMetric] {
        let start = WeeklyDigestEngine.addDays(day, -6)
        return days.filter { $0.day >= start && $0.day <= day }.sorted { $0.day < $1.day }
    }

    /// "+4 ms vs 7 days" against the mean of the earlier days in this calendar week (at least 3).
    private func deltaCaption(_ today: Double?, _ prior: [Double], unit: String) -> String {
        guard let t = today, prior.count >= 3 else { return "7-day trend" }
        let mean = prior.reduce(0, +) / Double(prior.count)
        let d = Int((t - mean).rounded())
        let u = unit.isEmpty ? "" : " \(unit)"
        return d == 0 ? "Steady vs 7 days" : "\(d > 0 ? "+" : "")\(d)\(u) vs 7 days"
    }

    /// Average of the completed days in the 7-day window (today's partial count is left out), and how
    /// many days it covers when that's fewer than 7.
    private func weekAverageCaption(_ slots: [Double?]) -> String {
        let done = (selectedDayOffset == 0 ? Array(slots.dropLast()) : slots).compactMap { $0 }
        guard !done.isEmpty else { return "No earlier days" }
        let avg = Int((done.reduce(0, +) / Double(done.count)).rounded())
        let n = Self.decimalFormatter.string(from: NSNumber(value: avg)) ?? ""
        return done.count >= 6 ? "7-day avg \(n)" : "Avg \(n) · \(done.count) day\(done.count == 1 ? "" : "s")"
    }

    /// "18 Jul" under a weekly card whose newest value is more than two weeks old; its own subtitle otherwise.
    private func weeklySubtitle(_ subtitle: String, _ day: String?) -> String {
        guard let day else { return subtitle }
        let age = WeeklyDigestEngine.addDays(logicalToday, -14)
        return day < age ? "As of \(Self.shortDayLabel(day))" : subtitle
    }

    /// The 7 calendar days ending on `day`, oldest first, each with its row or nil. Pure.
    static func weekSlots(_ week: [DailyMetric], endingOn day: String) -> [DailyMetric?] {
        let byDay = Dictionary(week.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        return (0..<7).map { byDay[WeeklyDigestEngine.addDays(day, $0 - 6)] }
    }

    /// "Mon 20 Oct" for a local day key.
    static func shortDayLabel(_ day: String) -> String {
        guard let d = dayKeyLocalParser.date(from: day) else { return day }
        return shortDayFormatter.string(from: d)
    }

    private static let dayKeyLocalParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return f
    }()

    // MARK: - Last workouts

    private var lastWorkoutsSection: some View {
        VStack(spacing: 8) {
            sectionHead("LAST WORKOUTS", trailing: "\(workouts.count) total")
            if let w = workouts.first {
                NavigationLink { WorkoutsView() } label: { workoutCard(w) }
                    .buttonStyle(LiquidPressStyle())
            } else {
                card {
                    Text("No workouts yet")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func workoutCard(_ w: WorkoutRow) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkoutSource.displaySport(w.sport)).font(StrandFont.number(15))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(workoutSub(w)).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    (Text(effortText(w.strain)).font(StrandFont.number(15))
                        + Text(" EFFORT").font(StrandFont.overlineScaled(9)))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                LiquidTube(frac: (w.strain ?? 0) / 100, tint: StrandPalette.effortColor, height: 12, animated: false)
            }
        }
    }

    // MARK: - Data sources

    private var dataSourcesSection: some View {
        VStack(spacing: 8) {
            sectionHead("DATA SOURCES", trailing: "Provenance")
            NavigationLink { DataSourcesView() } label: {
                card {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Synced from").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            HStack(spacing: 4) {
                                Text("View sources").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        LiquidStrapBatteryRow()
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    // MARK: - Reusable chrome

    private func sectionHead(_ title: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(StrandFont.overline).tracking(1.6).foregroundStyle(StrandPalette.textTertiary)
            Spacer()
            Text(trailing).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface()
    }

    // MARK: - Data

    private func load() async {
        // Resolve the O(days) lookups ONCE here (not on every body re-render): the selected day and the
        // readiness verdict. Both scan repo.days (up to 599 rows); doing it per-render was the stutter.
        let day = resolveDisplayDay()
        cachedDisplayDay = day
        cachedReadiness = ReadinessEngine.evaluate(days: repo.days, today: day?.day)
        // Prior-day vitals carry, resolved ONCE here (never in body). Bound to today's own key so it can't
        // echo today's still-forming row; only on today (a past day's own row is the whole story).
        let tkey = cachedDisplayDay?.day ?? selectedDayKey
        let carry = (selectedDayOffset == 0) ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil
        // A night older than the carry window isn't "today's" vitals: with the strap off for months the
        // tiles showed July values in October, undated. Same freshness rule as Rest.
        cachedVitalsDay = carry.flatMap { TodayView.isCarryStale(priorDayKey: $0.day, todayKey: tkey) ? nil : $0 }

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedLogicalDay)
        let from = Int(dayStart.timeIntervalSince1970)
        // today → midnight..now; a past day → its full 24h (a missing morning reads as empty space).
        let to: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)

        // 7-day series ending on the selected day for the tiles (oldest first), resolved once here.
        let week = Self.calendarWeek(repo.days, endingOn: selectedDayKey)
        let slots = Self.weekSlots(week, endingOn: selectedDayKey)
        weekHrv = slots.map { $0?.avgHrv }
        weekRhr = slots.map { $0?.restingHr.map(Double.init) }
        weekResp = slots.map { $0?.respRateBpm }
        weekSteps = slots.map { $0?.steps.map(Double.init) }
        let prior = week.filter { $0.day < selectedDayKey }
        priorHrv = prior.compactMap { $0.avgHrv }
        priorRhr = prior.compactMap { $0.restingHr.map(Double.init) }

        // Day-scoped only: the selected day's HR. History-wide series come from `loadHistory()`.
        let buckets = await repo.hrBuckets(from: from, to: to, bucketSeconds: 300)
        hrValues = buckets.map(\.bpm)
        hrPoints = buckets.map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }
        applyDaySeries()
        // First load done — bring the hero gauges + sky to life now the launch churn has settled.
        if !dataLoaded { withAnimation(.easeIn(duration: 0.4)) { dataLoaded = true } }
    }

    /// History-wide inputs: Rest and Steps series (kept per day), Fitness Age, Vitality, Stress and
    /// workouts. Runs when the repository refreshes, not on a day swipe.
    private func loadHistory() async {
        async let restA = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let stressA = repo.series(key: "stress", source: "my-whoop")
        async let fitA = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vitA = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let stepsA = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        async let wkA = repo.workoutRows()

        // Await everything into locals first, then commit in one synchronous block, so SwiftUI coalesces
        // the writes into one pass instead of one per await.
        let restSeries = await restA
        let stepsSeries = await stepsA
        let fitLast = (await fitA).last                 // history-wide latest banked (not day-scoped)
        let vitLast = (await vitA).last
        let newFitnessAge = fitLast?.value
        let newVitality = vitLast?.value
        let newWorkouts = await wkA
        // StressModel loops the full history to build its baseline — run it OFF the main actor so a big
        // history doesn't stutter the UI. Snapshot the inputs (value types) into the detached task.
        let storedStress = await stressA
        let daysSnapshot = repo.days
        let stressModel = await Task.detached(priority: .utility) {
            StressModel(days: daysSnapshot, stored: storedStress).map { (score: $0.score, day: $0.asOfDay) }
        }.value
        let newStress = stressModel?.score

        restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        restLast = restSeries.last.map { (day: $0.day, value: $0.value) }
        stepsByDay = Dictionary(stepsSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        stepsLast = stepsSeries.last?.value
        stress = newStress
        stressDay = stressModel?.day
        fitnessAge = newFitnessAge
        vitality = newVitality
        fitnessAgeDay = fitLast?.day
        vitalityDay = vitLast?.day
        workouts = newWorkouts
        applyDaySeries()
    }

    /// The selected day's Rest and Steps from the cached series. Rest's tail fallback applies only at
    /// offset 0 and only while the tail night is fresh (#977); Steps is keyed to the selected day.
    private func applyDaySeries() {
        restScore = TodayView.freshRestScore(
            todayValue: restByDay[selectedDayKey], lastDay: restLast?.day,
            lastValue: restLast?.value, isTodaySelected: selectedDayOffset == 0,
            todayKey: selectedDayKey)
        stepsEst = stepsByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? stepsLast : nil)
    }

    // MARK: - Derived (sync, off repo.today / repo.days)

    /// Cached in load() — ReadinessEngine.evaluate scans the full history and was invoked ~3× per body
    /// pass (readinessWord + synthLine + readiness.summary). The fallback runs only in the brief window
    /// before the first load() populates the cache.
    private var readiness: ReadinessEngine.Readiness {
        cachedReadiness ?? ReadinessEngine.evaluate(days: repo.days, today: cachedDisplayDay?.day)
    }

    private var readinessWord: String? {
        switch readiness.level {
        case .primed: return "Push"
        case .balanced: return "Maintain"
        case .strained, .rundown: return "Rest"
        case .insufficient: return nil
        }
    }

    private var synthLine: String {
        // No score of today's own: a readiness sentence from older days would read as today's verdict.
        // Effort alone (it starts at 0 each morning) isn't enough to judge readiness by.
        if displayDay?.recovery == nil, restScore == nil {
            return String(localized: "No scores for today yet. They fill in after a night's sleep.")
        }
        switch readiness.level {
        case .primed: return "You're primed. A hard session should land well today."
        case .balanced: return "You're in a good spot for training."
        case .strained: return "Signals are down a touch. Keep it easy today."
        case .rundown: return "Several recovery signals are down. Prioritise rest today."
        case .insufficient: return "Still learning your baseline. A few more nights and this fills in."
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
    }

    private var stepCount: Double? { displayDay?.steps.map(Double.init) ?? stepsEst }

    private var liveHour: Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    // MARK: - Formatting

    private func frac(_ v: Double?) -> Double? { v.map { max(0, min(1, $0 / 100)) } }
    private func fracOver(_ v: Double?, _ over: Double) -> Double? { v.map { max(0, min(1, $0 / over)) } }
    private func intText(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "–" }

    private func unitText(_ v: Double?, _ unit: String, decimals: Int = 0) -> String {
        guard let v else { return "–" }
        let n = decimals > 0 ? String(format: "%.\(decimals)f", v) : String(Int(v.rounded()))
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    // One decimal, matching StressView: integer rounding on the 0–3 scale misreads the 1.5
    // baseline as "2" (the HIGH-band floor).
    private var stressText: String {
        guard stressDay == selectedDayKey else { return stress == nil ? "Calibrating" : "–" }
        return stress.map { String(format: "%.1f", $0) } ?? "Calibrating"
    }

    private var sleepText: String {
        guard let m = displayDay?.totalSleepMin else { return "–" }
        return "\(Int(m) / 60)h \(Int(m) % 60)m"
    }

    private var stepsText: String {
        guard let s = stepCount else { return "–" }
        return Self.decimalFormatter.string(from: NSNumber(value: Int(s))) ?? "\(Int(s))"
    }

    // The user's Effort display scale (#268), 0–100 by default or the WHOOP 0–21 axis if chosen — the SAME
    // preference the Workouts screen + Trends read, so a workout's Effort number is identical everywhere.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private func effortText(_ s: Double?) -> String {
        guard let s else { return "–" }
        // Route through the shared formatter instead of hardcoding *21: a default (0–100) user was shown the
        // WHOOP-scaled number here while the hero + Workouts table showed 0–100, two numbers for one workout.
        return UnitFormatter.effortDisplay(s, scale: effortScale)
    }

    private func workoutSub(_ w: WorkoutRow) -> String {
        var parts: [String] = []
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        parts.append("\(Int(secs / 60)) min")
        if let dm = w.distanceM, dm > 0 { parts.append(String(format: "%.1f km", dm / 1000)) }
        if let k = w.energyKcal { parts.append("\(Int(k.rounded())) kcal") }
        return parts.joined(separator: " · ")
    }

    private var dateLine: String {
        Self.dateLineFormatter.string(from: selectedLogicalDay)
    }

    /// Provenance caption for the recovery-vitals card, keyed on the row a vital actually came from — NOT a
    /// hardcoded "yesterday". If ANY shown vital fell back to `vitalsDay` (today's own value is nil and the
    /// carried row supplies it), it stamps that row's date via the shared `TodayView.carriedCaption`, so a
    /// genuine post-rollover carry reads "Last night · <date>" and a weeks-old carry relabels to
    /// "Latest sleep · <date>" (#779) instead of a false "Last night". When every shown vital is today's
    /// own (or there's nothing to carry), it returns nil — the card must not claim "Last night" at all.
    private var vitalsProvenanceLine: String? {
        guard let carried = vitalsDay else { return nil }
        let carriedHrv = displayDay?.avgHrv == nil && carried.avgHrv != nil
        let carriedRhr = displayDay?.restingHr == nil && carried.restingHr != nil
        let carriedResp = displayDay?.respRateBpm == nil && carried.respRateBpm != nil
        guard carriedHrv || carriedRhr || carriedResp else { return nil }
        return TodayView.carriedCaption(priorDayKey: carried.day,
                                        todayKey: displayDay?.day ?? selectedDayKey)
    }
}

/// Carries the Today scroll's top overscroll offset up to the view for the custom liquid pull-to-refresh.
private struct PullOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Isolated pull-to-refresh state (keeps per-frame pull deltas off the dashboard body)

/// Holds the live pull offset + refresh lifecycle for the custom liquid pull-to-refresh. LiquidTodayView
/// holds this as a plain `@State` (so it does NOT observe it); only `LiquidRefreshIndicator` subscribes.
/// That way dragging — which updates `pullY` every frame — redraws just the small indicator, not the
/// whole dashboard. (U8)
@MainActor
final class LiquidPullState: ObservableObject {
    @Published var pullY: CGFloat = 0
    @Published private(set) var refreshing = false
    /// Bumped once when the pull crosses the release threshold, to drive a single medium haptic.
    @Published private(set) var haptic = 0

    let threshold: CGFloat = 80
    private var armed = false

    /// Feed the latest top-overscroll offset. Arms at the threshold and FIRES `onFire` on release
    /// (the pull springs back toward zero). Guarded so it can't double-fire or re-trigger mid-refresh.
    func update(_ y: CGFloat, onFire: () -> Void) {
        // Write only on a real change: this is called on EVERY scroll frame (minY changes all the way
        // down the page, clamped here to 0), and an unconditional assignment fires objectWillChange
        // regardless of value — re-rendering the indicator on every frame of every scroll, not just pulls.
        let clamped = max(0, y)
        if clamped != pullY { pullY = clamped }
        guard !refreshing else { return }
        if pullY >= threshold, !armed {
            armed = true
            haptic &+= 1
        }
        if armed, pullY < 6 {
            armed = false
            refreshing = true
            onFire()
        }
    }

    /// Clear the spinner once the reload settles.
    func finishRefreshing() {
        withAnimation(.easeOut(duration: 0.25)) { refreshing = false }
    }
}

/// The revealed-space indicator: a vessel that fills as you drag, then sloshes while the refresh runs.
/// Observes `LiquidPullState`, so only this small view redraws during a pull.
private struct LiquidRefreshIndicator: View {
    @ObservedObject var pull: LiquidPullState
    let tint: Color

    var body: some View {
        let progress = min(1, max(0, pull.pullY / pull.threshold))
        return ZStack {
            if pull.refreshing {
                LiquidVessel(value: 0.6, tint: tint, animated: true)
                    .frame(width: 34, height: 34)
            } else if pull.pullY > 2 {
                LiquidVessel(value: progress, tint: tint, animated: false)
                    .frame(width: 30, height: 30)
                    .opacity(progress)
                    .scaleEffect(0.7 + 0.3 * progress)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: pull.refreshing ? 64 : min(pull.pullY, pull.threshold * 1.15))
        .animation(.easeOut(duration: 0.22), value: pull.refreshing)
        // A firm tick when the pull passes the release threshold (the custom liquid refresh).
        .liquidMediumHaptic(trigger: pull.haptic)
    }
}

// MARK: - NOOP wordmark (centred, with a tap easter egg)

/// The subtle NOOP wordmark. Built as a row of letters (not `Text(...).tracking()`, which adds a
/// trailing gap after the last glyph and pushes the word off-centre), so it sits DEAD centre. Tap it
/// for a little easter egg: it plays one of several random one-shot animations — wiggle, shake, flip,
/// spin, bounce, or a jelly squash — with a light haptic.
private struct LiquidWordmark: View {
    @State private var rot = 0.0      // z-rotation (wiggle / spin)
    @State private var scaleX = 1.0   // horizontal scale (jelly squash)
    @State private var scaleY = 1.0   // vertical scale (bounce / jelly)
    @State private var dx = 0.0       // horizontal offset (shake)
    @State private var flip = 0.0     // y-axis 3D flip
    @State private var token = 0      // drives the tap haptic

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array("NOOP".enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(StrandFont.rounded(16, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
        .rotationEffect(.degrees(rot))
        .scaleEffect(x: scaleX, y: scaleY)
        .offset(x: dx)
        .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .contentShape(Rectangle())
        .onTapGesture { playRandomEgg() }
        .liquidTapHaptic(trigger: token)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// The easter egg: one of several one-shot animations at random. The oscillating ones (wiggle/shake/
    /// squash) kick the value to an extreme then let an under-damped spring settle it back through zero,
    /// which reads as a natural wobble without hand-authored keyframes.
    private func playRandomEgg() {
        token &+= 1
        switch Int.random(in: 0..<6) {
        case 0: // wiggle
            rot = -14
            withAnimation(.spring(response: 0.5, dampingFraction: 0.28)) { rot = 0 }
        case 1: // shake
            dx = -12
            withAnimation(.spring(response: 0.45, dampingFraction: 0.26)) { dx = 0 }
        case 2: // flip
            withAnimation(.easeInOut(duration: 0.6)) { flip += 360 }
        case 3: // spin
            withAnimation(.easeInOut(duration: 0.55)) { rot += 360 }
        case 4: // bounce
            scaleX = 1.28; scaleY = 1.28
            withAnimation(.spring(response: 0.5, dampingFraction: 0.42)) { scaleX = 1; scaleY = 1 }
        default: // jelly (squash + stretch)
            scaleX = 1.35; scaleY = 0.7
            withAnimation(.spring(response: 0.5, dampingFraction: 0.3)) { scaleX = 1; scaleY = 1 }
        }
    }
}

// MARK: - Hero score cell (count-up number over a filling vessel, tap-to-splash)

/// One of the three hero scores (Charge / Effort / Rest). The vessel fills from empty and the number
/// COUNTS UP to the value when data lands; tapping the gauge itself splashes (the number is
/// hit-transparent so the tap reaches the vessel). The label row taps through to the scoring guide.
private struct HeroScoreCell: View {
    let label: String
    let score: Double?            // 0–100 (nil = no data yet)
    let tint: Color
    let pill: String?
    let animated: Bool
    let onGuide: () -> Void

    @State private var shown: Double = 0

    private var frac: Double? { score.map { max(0, min(1, $0 / 100)) } }

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                LiquidVessel(value: frac, tint: tint, animated: animated)
                    .frame(width: 96, height: 96)
                Group {
                    if score != nil {
                        CountUpNumber(value: shown, font: StrandFont.rounded(26))
                    } else {
                        Text("–").font(StrandFont.rounded(26))
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsHitTesting(false)   // taps fall through to the vessel → splash
            }
            Button(action: onGuide) {
                HStack(spacing: 3) {
                    Text(label.uppercased()).font(StrandFont.overline).tracking(1.6)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).opacity(0.6)
                }
                .foregroundStyle(StrandPalette.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("\(label), \(score.map { String(Int($0.rounded())) } ?? "no data yet"). See how it is scored."))
            if let pill {
                Text(pill)
                    .font(StrandFont.overlineScaled(8.5)).tracking(1.2)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 2.5)
                    .background(Capsule().strokeBorder(StrandPalette.hairlineStrong, lineWidth: 0.5))
            } else {
                Color.clear.frame(height: 18) // keep the three labels vertically aligned
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { rollTo(score) }
        .onChangeCompat(of: score) { v in rollTo(v) }
    }

    private func rollTo(_ v: Double?) {
        guard let v else { shown = 0; return }
        withAnimation(.easeOut(duration: 0.9)) { shown = v }   // counts up in step with the vessel filling
    }
}


// MARK: - Scene controls (LiveState-isolated leaves)

/// Quick-actions "+" button. Tap → the shell's quick-action menu.
private struct LiquidAddButton: View {
    @EnvironmentObject var router: NavRouter
    var body: some View {
        Button { router.requestQuickActions() } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(StrandPalette.surfaceRaised))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Quick actions")
    }
}

/// The live heart-rate readout leaf. Owns LiveState so the ~1 Hz HR notifies re-render ONLY this card,
/// never the whole Today (the isolation the classic Today depends on). Keeps its own rolling buffer of
/// live samples, shows the current bpm live with a beat-by-beat trace, and falls back to today's banked
/// 5-minute trace when the strap isn't streaming.
private struct LiquidLiveHR: View {
    var tint: Color
    var fallback: [Double]        // today's banked 5-minute buckets — shown when there's no live stream
    var points: [TrendPoint] = [] // the same buckets with their times, drawn as a scrubbable chart
    var allowLive = true          // false on a past day: show that day's chart, not the live strap
    var animated: Bool

    @EnvironmentObject private var live: LiveState
    @State private var samples: [Double] = []
    @State private var beat = false
    private let maxSamples = 90   // ~1.5 min of 1 Hz live HR, enough to read the shape

    private var isLive: Bool { allowLive && live.connected && samples.count >= 2 }
    private var series: [Double] { isLive ? samples : fallback }
    private var bigBpm: Int? {
        if allowLive, let hr = live.heartRate, hr > 0, live.connected { return hr }
        if let last = fallback.last { return Int(last.rounded()) }
        return nil
    }
    private var subtitle: String {
        if isLive { return "Live · beat by beat" }
        if fallback.count >= 2 { return allowLive ? "5-minute average · since midnight" : "5-minute average" }
        return live.connected ? "Waiting for the strap" : "Strap not connected"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BEATS PER MINUTE").font(StrandFont.overline).tracking(1.6)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer()
                if isLive {
                    // A gentle heartbeat dot that pulses with each incoming sample.
                    Circle().fill(tint).frame(width: 7, height: 7)
                        .scaleEffect(beat ? 1.35 : 0.85)
                        .opacity(beat ? 1 : 0.45)
                        .animation(.easeOut(duration: 0.28), value: beat)
                        .padding(.trailing, 2)
                }
                if let hr = bigBpm {
                    (Text("\(hr)").font(StrandFont.rounded(22)).monospacedDigit()
                        + Text(" bpm").font(StrandFont.caption))
                        .foregroundStyle(tint)
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.25), value: hr)
                }
            }
            if !isLive, points.count >= 2 {
                let lo = points.map(\.value).min() ?? 40, hi = points.map(\.value).max() ?? 120
                TrendChart(points: points, valueRange: (lo - 6)...(hi + 6), height: 120,
                           valueFormat: { "\(Int($0.rounded())) bpm" },
                           dateFormat: { Self.timeFormatter.string(from: $0) },
                           accessibilityLabel: String(localized: "Heart rate today"))
                HStack {
                    stat("Min", series.min())
                    Spacer()
                    stat("Avg", series.reduce(0, +) / Double(series.count))
                    Spacer()
                    stat("Max", series.max())
                }
            } else if series.count >= 2 {
                LiquidThread(bpm: series, tint: tint, height: 92, animated: animated)
                HStack {
                    stat("Min", series.min())
                    Spacer()
                    stat("Avg", series.reduce(0, +) / Double(series.count))
                    Spacer()
                    stat("Max", series.max())
                }
            } else {
                Text(live.connected ? "Waiting for a live heartbeat…" : "Connect your strap to see live heart rate")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
            }
        }
        .onAppear { if samples.isEmpty, let hr = live.heartRate, hr > 0 { samples = [Double(hr)] } }
        .onChangeCompat(of: live.heartRate) { hr in
            guard let hr, hr > 0 else { return }
            samples.append(Double(hr))
            if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
            beat.toggle()
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("HH:mm")
        return f
    }()

    private func stat(_ label: String, _ v: Double?) -> some View {
        HStack(spacing: 5) {
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            Text(v.map { String(Int($0.rounded())) } ?? "–")
                .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

/// Strap-battery ring. Owns LiveState. Tap → Devices.
private struct LiquidBatteryButton: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var router: NavRouter
    var body: some View {
        Button { router.openDevices() } label: {
            ZStack {
                Circle().fill(StrandPalette.surfaceRaised)
                if let pct = live.batteryPct {
                    Circle()
                        .trim(from: 0, to: max(0.02, min(1, pct / 100)))
                        .stroke(ringColor(pct), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2.5)
                    Text("\(Int(pct.rounded()))")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if live.charging == true {
                        // #972: the default Today never surfaced charging state — only the % ring. A small
                        // bolt over the ring gives the same signal as the "· Charging" text on Mac/Android.
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(StrandPalette.chargeColor)
                            .offset(y: -10)
                    }
                } else {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(width: 34, height: 34)
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel(batteryAccessibility)
    }
    private var batteryAccessibility: String {
        let base = live.batteryPct.map { "Strap battery \(Int($0.rounded())) percent" } ?? "Strap battery"
        return live.charging == true ? base + ", charging" : base
    }
    private func ringColor(_ p: Double) -> Color {
        p < 15 ? StrandPalette.statusCritical : p < 35 ? StrandPalette.statusWarning : StrandPalette.chargeColor
    }
}

/// The strap-battery readout inside the Data Sources card. Owns LiveState; display-only.
private struct LiquidStrapBatteryRow: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        if live.connected, let pct = live.batteryPct {
            HStack {
                Text("Strap battery").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                // #972: append "· Charging"; #992: append the "~X days left" runtime the v8 redesign dropped.
                Text(batteryText(pct: pct))
                    .font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    /// "87%" plus a trailing "· Charging" (#972) or "· ~9 days left" runtime (#992), matching the Settings /
    /// Mac / Android pill and the classic Today badge.
    private func batteryText(pct: Double) -> String {
        let base = "\(Int(pct.rounded()))%"
        if live.charging == true { return "\(base) · Charging" }
        if let est = estimateText { return "\(base) · \(est)" }
        return base
    }

    /// #992: the v8 Liquid redesign dropped the "~X days left" estimate the classic Today showed (#713).
    /// Reproduced verbatim from `TodayView.estimateText`: under 48 h show hours, at two days or more round to
    /// days; nil (no banked discharge yet, or charging) hides it, so the row only ever shows an estimate we trust.
    private var estimateText: String? {
        guard live.charging != true, let est = live.batteryEstimate else { return nil }
        let hours = est.hoursRemaining
        guard hours.isFinite, hours > 0 else { return nil }
        if hours < 48 {
            return String(localized: "~\(Int(hours.rounded()))h left")
        }
        let days = Int((hours / 24).rounded())
        return days == 1
            ? String(localized: "~1 day left")
            : String(localized: "~\(days) days left")
    }
}

// MARK: - Cross-platform chrome helpers
//
// The liquid Today is shared with the macOS target now (the mac split-view shell hosts it too). A few of
// its chrome modifiers are iOS-only, so they are wrapped here: `topBarTrailing` + `navigationBarTitleDisplayMode`
// don't exist on macOS, and `presentationCompactAdaptation` is an iOS phone-width concern. These keep the
// exact iOS behaviour while giving macOS the platform-correct equivalent.
private extension View {
    /// A sheet's trailing "Done" button (inline title on iOS; the confirmation-action toolbar slot on macOS).
    @ViewBuilder func liquidSheetDoneChrome(done: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: done).foregroundStyle(StrandPalette.accent)
                }
            }
        #else
        self.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done).foregroundStyle(StrandPalette.accent)
            }
        }
        #endif
    }

    /// Keep a popover a popover in compact width (iOS 16.4+); a no-op on macOS where popovers never adapt.
    @ViewBuilder func liquidPopoverAdaptation() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) } else { self }
        #else
        self
        #endif
    }

    /// Present the Live Session screen: fullScreenCover on iOS (the guardian owns the display mid-
    /// workout), a plain sheet on macOS where fullScreenCover doesn't exist. The session view calls
    /// `onClose` itself once the summary is dismissed.
    @ViewBuilder func liveSessionCover(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #else
        self.sheet(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #endif
    }
}

// MARK: - Minimal score cell + mini bars (2026-10-21 redesign)

/// A flat score ring with its number centred and the label below. Tap opens the scoring guide.
private struct MinimalScoreCell: View {
    let label: String
    let score: Double?
    let tint: Color
    /// The number to print when it differs from the 0–100 score (Effort on the 0–21 scale).
    var text: String? = nil
    let onGuide: () -> Void

    var body: some View {
        Button(action: onGuide) {
            VStack(spacing: 8) {
                ZStack {
                    MinimalRing(value: score.map { $0 / 100 }, tint: tint, lineWidthFraction: 0.075)
                    Text(text ?? score.map { String(Int($0.rounded())) } ?? "–")
                        .font(StrandFont.rounded(26, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .frame(width: 88, height: 88)
                Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) \(score.map { String(Int($0.rounded())) } ?? "no score"). Opens the scoring guide.")
    }
}

/// Seven small bars, the newest in the accent; the rest in a quiet grey.
private struct MiniBars: View {
    /// One slot per calendar day, oldest first; nil draws a short stub so a missing day reads as missing.
    let values: [Double?]

    var body: some View {
        GeometryReader { geo in
            let mx = max(1, values.compactMap { $0 }.max() ?? 1)
            let slots = max(7, values.count)
            let gap: CGFloat = 4
            let w = max(2, (geo.size.width - gap * CGFloat(slots - 1)) / CGFloat(slots))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(v == nil ? StrandPalette.hairline
                              : i == values.count - 1 ? StrandPalette.accent : StrandPalette.hairlineStrong)
                        .frame(width: w, height: v.map { max(3, geo.size.height * CGFloat($0 / mx)) } ?? 2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}

