import SwiftUI
import StrandDesign

/// Settings → Recovery → Excluded days. Days on this list are not scored and stay out of every
/// baseline (someone else wore the strap, or the readings are junk). The raw data is kept, so removing
/// a day and letting NOOP rescore brings it back.
struct ExcludedDaysView: View {
    @EnvironmentObject var model: AppModel
    @State private var days: [String] = ExcludedDays.current().sorted(by: >)
    @State private var pick = Date()
    @State private var rescoring = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Text("Days on this list aren't scored and are left out of your baselines. Use it when someone else wore the strap or the readings are wrong. The raw data is kept, so you can bring a day back.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                NoopCard {
                    VStack(alignment: .leading, spacing: 12) {
                        DatePicker("Day", selection: $pick, in: ...Date(), displayedComponents: .date)
                            .font(StrandFont.subhead)
                        NoopButton("Exclude this day", systemImage: "minus.circle", kind: .secondary) {
                            change { ExcludedDays.add([Self.dayKey(pick)]) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    if days.isEmpty {
                        Text("No days excluded.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                            .padding(.vertical, 12)
                    }
                    ForEach(days, id: \.self) { day in
                        HStack {
                            Text(Self.label(day)).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Spacer()
                            Button("Bring back") { change { ExcludedDays.remove(day) } }
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.accent)
                        }
                        .padding(.vertical, 12)
                        if day != days.last { Divider().overlay(StrandPalette.hairline) }
                    }
                }
                .padding(.horizontal, 16)
                .frostedCardSurface()

                if rescoring {
                    Text("Rescoring…").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle("Excluded days")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Apply a list change, then rescore wide enough to reach the oldest affected day so the days after
    /// it are rescored against the corrected baseline.
    private func change(_ edit: () -> Bool) {
        let before = ExcludedDays.current()
        guard edit() else { return }
        let after = ExcludedDays.current()
        days = after.sorted(by: >)
        let span = ExcludedDays.rescoreSpan(touched: before.symmetricDifference(after))
        rescoring = true
        Task {
            await model.intelligence.analyzeRecent(maxDays: span)
            await model.repo.refresh()
            rescoring = false
        }
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func label(_ day: String) -> String {
        let p = DateFormatter()
        p.calendar = Calendar(identifier: .gregorian)
        p.locale = Locale(identifier: "en_US_POSIX")
        p.timeZone = TimeZone(identifier: "UTC")
        p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: day) else { return day }
        let out = DateFormatter()
        out.timeZone = TimeZone(identifier: "UTC")
        out.setLocalizedDateFormatFromTemplate("EEE d MMM yyyy")
        return out.string(from: d)
    }
}
