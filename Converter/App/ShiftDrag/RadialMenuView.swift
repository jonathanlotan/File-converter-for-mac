import SwiftUI

/// Draws the wheel: glass (or material) surfaces from `WheelBackground`,
/// then on top the selection pill, dividers, labels and the caption in the
/// middle (the ring's name and key, what a drop would do, or "Cancel").
/// Hit-testing lives in `RadialGeometry`; this view only paints
/// `RadialMenuModel`'s state.
struct RadialMenuView: View {
    @ObservedObject var model: RadialMenuModel
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Space between the ring's inner edge and the centre disc.
    static let centerGap: CGFloat = 6
    /// How far the selection pill sits inside its slice.
    static let selectionInset: CGFloat = 4

    private var geometry: RadialGeometry { model.geometry }

    var body: some View {
        ZStack {
            WheelBackground(model: model)
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                drawRing(in: &context, center: center)
                drawSubRing(in: &context, center: center)
                drawCenter(in: &context, center: center)
            }
            // Switching rings cross-fades the labels.
            .id(model.mode)
            .transition(.opacity)
        }
        .frame(width: geometry.panelSide, height: geometry.panelSide)
        .scaleEffect(model.isPresented || reduceMotion ? 1 : 0.86)
        .opacity(model.isPresented ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.3, bounce: 0.22), value: model.isPresented)
        .animation(.easeInOut(duration: 0.16), value: model.mode)
        .accessibilityElement()
        .accessibilityLabel("\(model.mode.title) wheel")
        .accessibilityValue(model.caption.title)
    }

    // MARK: - Colours

    private var highlight: Color { .accentColor }
    private var divider: Color { Color.primary.opacity(contrast == .increased ? 0.35 : 0.12) }
    private var edge: Color { Color.primary.opacity(contrast == .increased ? 0.5 : 0) }

    // MARK: - Ring

    private func drawRing(in context: inout GraphicsContext, center: CGPoint) {
        if contrast == .increased {
            let r = geometry.outerRadius
            context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(edge), lineWidth: 1)
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
                context.fill(selection(center: center, inner: geometry.innerRadius, outer: geometry.outerRadius,
                                       mid: mid, span: span),
                             with: .color(isHit && !slice.isGroup ? highlight : highlight.opacity(0.28)))
            }
            if count > 1 {
                let angle = mid - span / 2
                var line = Path()
                line.move(to: RadialGeometry.viewPoint(angle: angle, radius: geometry.innerRadius + 10, center: center))
                line.addLine(to: RadialGeometry.viewPoint(angle: angle, radius: geometry.outerRadius - 10, center: center))
                context.stroke(line, with: .color(divider), lineWidth: 1)
            }
            drawLabel(slice.title, symbol: slice.symbol, chevron: slice.isGroup,
                      at: RadialGeometry.viewPoint(angle: mid, radius: labelRadius, center: center),
                      width: min(92, CGFloat(span) * labelRadius - 4), onAccent: isHit && !slice.isGroup,
                      fontSize: count > 10 ? 11 : 11.5, in: &context)
        }
    }

    /// The rounded pill marking a slice, inset from its edges so its corners
    /// sit concentric with the ring.
    private func selection(center: CGPoint, inner: CGFloat, outer: CGFloat, mid: Double, span: Double) -> Path {
        let inset = Self.selectionInset
        let angularInset = Double(inset / ((inner + outer) / 2))
        return BandShape.path(center: center, inner: inner + inset, outer: outer - inset,
                              from: mid - span / 2 + angularInset, to: mid + span / 2 - angularInset, corner: 12)
    }

    private func drawSubRing(in context: inout GraphicsContext, center: CGPoint) {
        guard let parent = model.openGroup else { return }
        let members = model.openGroupMembers
        let count = model.slices.count
        let span = geometry.subSpan(members: members.count)
        let labelRadius = (geometry.subInnerRadius + geometry.subOuterRadius) / 2
        for (index, member) in members.enumerated() {
            let mid = geometry.subCenterAngle(member: index, members: members.count, parent: parent, count: count)
            let isHit = model.hit == .subSlice(index)
            if isHit {
                context.fill(selection(center: center, inner: geometry.subInnerRadius, outer: geometry.subOuterRadius,
                                       mid: mid, span: span), with: .color(highlight))
            }
            drawLabel(member.title, symbol: nil, chevron: false,
                      at: RadialGeometry.viewPoint(angle: mid, radius: labelRadius, center: center),
                      width: CGFloat(span) * labelRadius - 4, onAccent: isHit, fontSize: 11.5, in: &context)
        }
    }

    // MARK: - Centre

    private func drawCenter(in context: inout GraphicsContext, center: CGPoint) {
        let r = geometry.innerRadius - Self.centerGap
        let disc = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        // A quiet well on the glass (a fill, not more glass), darker when a
        // drop here would cancel.
        let cancelling = model.hit == .center && model.phase == .ready
        context.fill(disc, with: .color(Color.primary.opacity(cancelling ? 0.14 : 0.05)))
        context.stroke(disc, with: .color(contrast == .increased ? edge : divider), lineWidth: 1)

        // The ring's name with its key, and dots showing where it sits among the three.
        let keyGlyph = model.ringKeys().key(for: model.mode).map { "\($0.symbol) " } ?? ""
        let ringLabel = context.resolve(Text(keyGlyph + model.mode.title.uppercased())
            .font(.system(size: 8.5, weight: .bold)).tracking(0.8).foregroundColor(.secondary))
        context.draw(ringLabel, at: CGPoint(x: center.x, y: center.y - r + 13))
        for (index, mode) in RingMode.wheelOrder.enumerated() {
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

    // MARK: - Labels

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
}
