import SwiftUI

// MARK: - Minimal primitives (2026-10-21)
//
// Flat, static building blocks for the minimal redesign: a score ring, a capsule bar and a plain line.
// No animation, gradients, glows or shadows; each view redraws only when its inputs change.

/// A score ring: a full track plus an arc filled to `value` (0...1; nil draws the track only). The
/// stroke scales with the ring's size so a 28pt row gauge and a 160pt hero read the same.
/// Drawn as two shapes that size themselves in `path(in:)`: no GeometryReader, which cost a layout pass
/// per ring and was the largest app-side item when sampling Today's launch (2026-10-21).
public struct MinimalRing: View {
    public var value: Double?
    public var tint: Color
    public var lineWidthFraction: CGFloat

    public init(value: Double?, tint: Color = StrandPalette.accent, lineWidthFraction: CGFloat = 0.085) {
        self.value = value
        self.tint = tint
        self.lineWidthFraction = lineWidthFraction
    }

    public var body: some View {
        ZStack {
            RingArc(progress: 1, lineWidthFraction: lineWidthFraction).fill(StrandPalette.hairline)
            if let v = value, v > 0 {
                RingArc(progress: min(1, max(0, v)), lineWidthFraction: lineWidthFraction).fill(tint)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// A round-capped arc from 12 o'clock, stroked to a width proportional to the shape's size, returned as
/// a filled outline so it needs no geometry from outside.
struct RingArc: Shape {
    var progress: Double
    var lineWidthFraction: CGFloat

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let lw = max(2.5, side * lineWidthFraction)
        let r = (side - lw) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        if progress >= 1 {
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            return p.strokedPath(StrokeStyle(lineWidth: lw))
        }
        p.addArc(center: c, radius: r, startAngle: .degrees(-90),
                 endAngle: .degrees(-90 + 360 * progress), clockwise: false)
        return p.strokedPath(StrokeStyle(lineWidth: lw, lineCap: .round))
    }
}

/// A horizontal capsule filled to `frac` (0...1) over a hairline track.
public struct MinimalBar: View {
    public var frac: Double
    public var tint: Color
    public var height: CGFloat

    public init(frac: Double, tint: Color = StrandPalette.accent, height: CGFloat = 6) {
        self.frac = frac
        self.tint = tint
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(StrandPalette.hairline)
                Capsule().fill(tint)
                    .frame(width: max(height, geo.size.width * CGFloat(min(1, max(0, frac)))))
                    .opacity(frac > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
    }
}

/// A plain line through `values`, scaled to the view (min-max with a small floor on the span so a flat
/// series doesn't exaggerate noise), with an optional dot on the newest point.
public struct MinimalLine: View {
    public var values: [Double]
    public var tint: Color
    public var lineWidth: CGFloat
    public var showsEndDot: Bool
    public var minSpan: Double

    public init(values: [Double], tint: Color = StrandPalette.accent, lineWidth: CGFloat = 1.8,
                showsEndDot: Bool = true, minSpan: Double = 10) {
        self.values = values
        self.tint = tint
        self.lineWidth = lineWidth
        self.showsEndDot = showsEndDot
        self.minSpan = minSpan
    }

    /// Slots per calendar day (nil = no reading): points sit at their day's position and the line breaks
    /// over missing days, so a gap isn't drawn as a straight line across it.
    public init(slots: [Double?], tint: Color = StrandPalette.accent, lineWidth: CGFloat = 1.8,
                showsEndDot: Bool = true, minSpan: Double = 10) {
        self.values = slots.compactMap { $0 }
        self.slots = slots
        self.tint = tint
        self.lineWidth = lineWidth
        self.showsEndDot = showsEndDot
        self.minSpan = minSpan
    }

    private var slots: [Double?]? = nil

    public var body: some View {
        if let slots { slotted(slots) } else { packed }
    }

    private func slotted(_ slots: [Double?]) -> some View {
        Canvas { ctx, size in
            let present = slots.compactMap { $0 }
            guard present.count >= 2 || (present.count == 1 && slots.count > 1) else {
                var p = Path()
                p.move(to: CGPoint(x: 2, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
                ctx.stroke(p, with: .color(StrandPalette.hairlineStrong),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4]))
                return
            }
            let lo = present.min() ?? 0, hi = present.max() ?? 1
            let span = max(minSpan, hi - lo), mid = (hi + lo) / 2
            let pad = Double(lineWidth) + 2
            let w = Double(size.width) - 2 * pad, h = Double(size.height) - 2 * pad
            func pt(_ i: Int, _ v: Double) -> CGPoint {
                CGPoint(x: pad + Double(i) / Double(max(1, slots.count - 1)) * w,
                        y: pad + (0.5 - (v - mid) / span) * h)
            }
            var path = Path()
            var open = false
            for (i, v) in slots.enumerated() {
                guard let v else { open = false; continue }
                if open { path.addLine(to: pt(i, v)) } else { path.move(to: pt(i, v)); open = true }
            }
            ctx.stroke(path, with: .color(tint),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            // Days with no neighbour on either side would be invisible as a line: draw them as dots.
            for (i, v) in slots.enumerated() {
                guard let v else { continue }
                let prevNil = i == 0 || slots[i - 1] == nil
                let nextNil = i == slots.count - 1 || slots[i + 1] == nil
                let isLast = i == slots.lastIndex(where: { $0 != nil })
                if (prevNil && nextNil) || (showsEndDot && isLast) {
                    let e = pt(i, v), r = lineWidth * 1.6
                    ctx.fill(Path(ellipseIn: CGRect(x: e.x - r, y: e.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(tint))
                }
            }
        }
    }

    private var packed: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else {
                // Not enough points for a line: a faint dashed baseline so the tile doesn't look broken.
                var p = Path()
                p.move(to: CGPoint(x: 2, y: size.height / 2))
                p.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
                ctx.stroke(p, with: .color(StrandPalette.hairlineStrong),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 4]))
                return
            }
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            let span = max(minSpan, hi - lo), mid = (hi + lo) / 2
            let pad = Double(lineWidth) + 2
            let w = Double(size.width) - 2 * pad, h = Double(size.height) - 2 * pad
            func pt(_ i: Int) -> CGPoint {
                let x = pad + Double(i) / Double(values.count - 1) * w
                let y = pad + (0.5 - (values[i] - mid) / span) * h
                return CGPoint(x: x, y: y)
            }
            var path = Path()
            path.move(to: pt(0))
            for i in 1..<values.count { path.addLine(to: pt(i)) }
            ctx.stroke(path, with: .color(tint),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            if showsEndDot {
                let e = pt(values.count - 1), r = lineWidth * 1.6
                ctx.fill(Path(ellipseIn: CGRect(x: e.x - r, y: e.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(tint))
            }
        }
    }
}
