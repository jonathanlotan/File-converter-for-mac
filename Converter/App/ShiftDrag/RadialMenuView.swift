import SwiftUI

/// Draws the radial menu: a ring of slices, a sub-ring for an open group,
/// and a caption in the middle (the file being dragged, the name the output
/// will get, or "Cancel"). Hit-testing lives in `RadialGeometry`; this view
/// only paints `RadialMenuModel`'s state.
struct RadialMenuView: View {
    @ObservedObject var model: RadialMenuModel

    private var geometry: RadialGeometry { model.geometry }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            drawRing(in: &context, center: center)
            drawSubRing(in: &context, center: center)
            drawCenter(in: &context, center: center)
        }
        .frame(width: geometry.panelSide, height: geometry.panelSide)
        .accessibilityElement()
        .accessibilityLabel("Conversion menu")
        .accessibilityValue(model.caption.title)
    }

    // MARK: - Colours

    private var surface: Color { Color(nsColor: .windowBackgroundColor).opacity(0.97) }
    private var divider: Color { Color.primary.opacity(0.10) }
    private var highlight: Color { Color.accentColor }

    // MARK: - Ring

    private func drawRing(in context: inout GraphicsContext, center: CGPoint) {
        let ring = Self.sector(center: center, inner: geometry.innerRadius, outer: geometry.outerRadius,
                               from: 0, to: 2 * .pi)
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.28), radius: 10, y: 3))
            layer.fill(ring, with: .color(surface))
        }
        guard model.phase == .ready else { return }

        let count = model.slices.count
        let span = geometry.span(count: count)
        let labelRadius = (geometry.innerRadius + geometry.outerRadius) / 2
        for slice in model.slices {
            let mid = geometry.centerAngle(ofSlice: slice.id, count: count)
            let isHit = model.hit == .slice(slice.id)
            let isOpen = model.openGroup == slice.id
            if isHit || isOpen {
                let path = Self.sector(center: center, inner: geometry.innerRadius, outer: geometry.outerRadius,
                                       from: mid - span / 2, to: mid + span / 2)
                context.fill(path, with: .color(isHit && !slice.isGroup ? highlight : highlight.opacity(0.35)))
            }
            if count > 1 {
                var line = Path()
                line.move(to: RadialGeometry.viewPoint(angle: mid - span / 2, radius: geometry.innerRadius, center: center))
                line.addLine(to: RadialGeometry.viewPoint(angle: mid - span / 2, radius: geometry.outerRadius, center: center))
                context.stroke(line, with: .color(divider), lineWidth: 1)
            }
            let onAccent = isHit && !slice.isGroup
            drawLabel(slice.title, symbol: slice.symbol, chevron: slice.isGroup,
                      at: RadialGeometry.viewPoint(angle: mid, radius: labelRadius, center: center),
                      width: min(92, CGFloat(span) * labelRadius - 4), onAccent: onAccent,
                      fontSize: count > 10 ? 11 : 11.5, in: &context)
        }
    }

    private func drawSubRing(in context: inout GraphicsContext, center: CGPoint) {
        guard let parent = model.openGroup else { return }
        let members = model.openGroupMembers
        let count = model.slices.count
        let span = geometry.subSpan(members: members.count)
        let labelRadius = (geometry.subInnerRadius + geometry.subOuterRadius) / 2
        let first = geometry.subCenterAngle(member: 0, members: members.count, parent: parent, count: count) - span / 2
        let arc = Self.sector(center: center, inner: geometry.subInnerRadius, outer: geometry.subOuterRadius,
                              from: first, to: first + span * Double(members.count))
        context.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.25), radius: 8, y: 2))
            layer.fill(arc, with: .color(surface))
        }
        for (index, member) in members.enumerated() {
            let mid = geometry.subCenterAngle(member: index, members: members.count, parent: parent, count: count)
            let isHit = model.hit == .subSlice(index)
            if isHit {
                context.fill(Self.sector(center: center, inner: geometry.subInnerRadius, outer: geometry.subOuterRadius,
                                         from: mid - span / 2, to: mid + span / 2), with: .color(highlight))
            }
            drawLabel(member.title, symbol: nil, chevron: false,
                      at: RadialGeometry.viewPoint(angle: mid, radius: labelRadius, center: center),
                      width: CGFloat(span) * labelRadius - 4, onAccent: isHit, fontSize: 11.5, in: &context)
        }
    }

    // MARK: - Centre

    private func drawCenter(in context: inout GraphicsContext, center: CGPoint) {
        let r = geometry.innerRadius - 4
        let disc = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        let cancelling = model.hit == .center && model.phase == .ready
        context.fill(disc, with: .color(cancelling ? Color.secondary.opacity(0.35) : surface))
        context.stroke(disc, with: .color(divider), lineWidth: 1)

        // Which ring this is, and dots showing where it sits among the three.
        let ringLabel = context.resolve(Text(model.mode.title.uppercased())
            .font(.system(size: 8.5, weight: .bold)).tracking(0.8).foregroundColor(.secondary))
        context.draw(ringLabel, at: CGPoint(x: center.x, y: center.y - r + 13))
        for (index, mode) in RingMode.allCases.enumerated() {
            let x = center.x + CGFloat(index - 1) * 9
            let dot = Path(ellipseIn: CGRect(x: x - 2.5, y: center.y + r - 15, width: 5, height: 5))
            context.fill(dot, with: .color(mode == model.mode ? highlight : Color.secondary.opacity(0.35)))
        }

        let caption = model.caption
        var text = Text(caption.title).font(.system(size: 12, weight: .semibold))
        if let detail = caption.detail {
            text = text + Text("\n" + detail).font(.system(size: 10)).foregroundColor(.secondary)
        }
        let box = CGRect(x: center.x - r + 8, y: center.y - r + 20, width: 2 * r - 16, height: 2 * r - 40)
        let resolved = context.resolve(text.foregroundColor(.primary))
        let size = resolved.measure(in: box.size)
        context.draw(resolved, in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                                          width: size.width, height: size.height))
    }

    // MARK: - Helpers

    /// Draws an optional symbol above a label, centred on `point`. Labels
    /// wrap between words to fit `width`, but never break inside a word.
    private func drawLabel(_ title: String, symbol: String?, chevron: Bool, at point: CGPoint, width: CGFloat,
                           onAccent: Bool, fontSize: CGFloat, in context: inout GraphicsContext) {
        let color: Color = onAccent ? .white : .primary
        let font = Font.system(size: fontSize, weight: .semibold)
        func styled(_ string: String) -> Text {
            var text = Text(string).font(font)
            if chevron { text = text + Text(" ›").font(font) }
            return text.foregroundColor(color)
        }
        let unbounded = CGSize(width: 1000, height: 60)
        let longestWord = title.split(separator: " ").map { word in
            context.resolve(styled(String(word))).measure(in: unbounded).width
        }.max() ?? 0
        let resolved = context.resolve(styled(title))
        let size = resolved.measure(in: CGSize(width: max(width, longestWord), height: 60))

        var top = point.y - size.height / 2
        if let symbol {
            var image = context.resolve(Image(systemName: symbol))
            image.shading = .color(color)
            let gap: CGFloat = 3
            top = point.y - (image.size.height + gap + size.height) / 2
            context.draw(image, at: CGPoint(x: point.x, y: top + image.size.height / 2))
            top += image.size.height + gap
        }
        context.draw(resolved, in: CGRect(x: point.x - size.width / 2, y: top, width: size.width, height: size.height))
    }

    /// An annular sector between two clockwise-from-top angles.
    static func sector(center: CGPoint, inner: CGFloat, outer: CGFloat, from start: Double, to end: Double) -> Path {
        var path = Path()
        let steps = max(2, Int(abs(end - start) / (.pi / 90)))
        for k in 0...steps {
            let angle = start + (end - start) * Double(k) / Double(steps)
            let point = RadialGeometry.viewPoint(angle: angle, radius: outer, center: center)
            k == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        for k in (0...steps).reversed() {
            let angle = start + (end - start) * Double(k) / Double(steps)
            path.addLine(to: RadialGeometry.viewPoint(angle: angle, radius: inner, center: center))
        }
        path.closeSubpath()
        return path
    }
}
