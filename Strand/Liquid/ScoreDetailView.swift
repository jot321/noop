import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Score detail (minimal redesign, 2026-10-21)
//
// The page behind a Today ring: one large ring with the number, the verdict sentence, then "What
// shaped it" when the engine has driver rows for the score, and a link to the scoring method. Every
// value arrives from the caller (the same row the ring shows); nothing here recomputes a score.

struct ScoreDetailView: View {
    let title: String
    let score: Double?
    let tint: Color
    let verdict: String
    var note: String? = nil
    var drivers: [ChargeDriver] = []
    var confidence: ScoreConfidence? = nil
    var skinTempRel: SkinTempRelative? = nil
    let guide: ScoreSection
    let onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                VStack(spacing: 14) {
                    ZStack {
                        MinimalRing(value: score.map { $0 / 100 }, tint: tint, lineWidthFraction: 0.06)
                        VStack(spacing: 2) {
                            Text(score.map { String(Int($0.rounded())) } ?? "–")
                                .font(StrandFont.rounded(56, weight: .semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(title).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .frame(width: 190, height: 190)
                    Text(verdict)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Text(note).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .accessibilityElement(children: .combine)

                if !drivers.isEmpty, let confidence {
                    NoopCard(padding: 18) {
                        ChargeBreakdownSection(drivers: drivers, confidence: confidence, skinTempRel: skinTempRel)
                    }
                }

                NavigationLink {
                    ScoringGuideView(initialSection: guide, onClose: onClose)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("How \(title) is calculated")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            Text("The method behind the score, not today's values.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(14)
                    .frostedCardSurface()
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(NoopMetrics.screenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onClose).foregroundStyle(StrandPalette.accent)
            }
        }
    }
}
