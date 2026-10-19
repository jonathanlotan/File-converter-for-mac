import AppKit
import SwiftUI

/// The wheel's surfaces: one disc holding the ring and its centre, and
/// (when a group is open) the sub-ring.
///
/// - macOS 26 and later: Liquid Glass, used sparingly as Apple's guidance
///   asks. The wheel is one control, so it's one regular glass disc; the
///   centre caption is drawn on it, not given glass of its own (no glass on
///   glass). The sub-ring is the only other glass shape, in the same
///   container so it grows out of the disc. Only the disc gets the
///   interactive response.
/// - macOS 13–25: the system's popover material, blurred from behind the
///   window like a menu.
///
/// Both follow Reduce Transparency and Increase Contrast by themselves.
struct WheelBackground: View {
    @ObservedObject var model: RadialMenuModel
    @Namespace private var glassSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var g: RadialGeometry { model.geometry }

    /// The open sub-ring's angles, or nil.
    private var subRing: (start: Double, end: Double)? {
        guard let parent = model.openGroup else { return nil }
        let members = model.openGroupMembers.count
        let span = g.subSpan(members: members)
        let first = g.subCenterAngle(member: 0, members: members, parent: parent, count: model.slices.count) - span / 2
        return (first, first + span * Double(members))
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                glass
            } else {
                material
            }
        }
        .frame(width: g.panelSide, height: g.panelSide)
        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.18), value: model.openGroup)
    }

    @available(macOS 26.0, *)
    private var glass: some View {
        GlassEffectContainer(spacing: 4) {
            ZStack {
                Color.clear
                    .frame(width: 2 * g.outerRadius, height: 2 * g.outerRadius)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .glassEffectID("wheel", in: glassSpace)
                if let subRing {
                    Color.clear
                        .glassEffect(.regular, in: BandShape(
                            innerRadius: g.subInnerRadius, outerRadius: g.subOuterRadius,
                            startAngle: subRing.start, endAngle: subRing.end, cornerRadius: 16))
                        .glassEffectID("subring", in: glassSpace)
                        .glassEffectTransition(.matchedGeometry)
                }
            }
        }
    }

    private var material: some View {
        ZStack {
            // Menus and popovers cast a soft shadow; so does the wheel.
            Canvas { context, size in
                context.drawLayer { layer in
                    layer.addFilter(.shadow(color: .black.opacity(0.3), radius: 12, y: 4))
                    layer.fill(wheelDisc(in: size), with: .color(.black.opacity(0.25)))
                }
            }
            VisualEffectShape(shape: wheelDisc(in: CGSize(width: g.panelSide, height: g.panelSide)))
            if let subRing {
                VisualEffectShape(shape: BandShape(innerRadius: g.subInnerRadius, outerRadius: g.subOuterRadius,
                                                   startAngle: subRing.start, endAngle: subRing.end, cornerRadius: 16))
                    .transition(.opacity)
            }
        }
    }

    private func wheelDisc(in size: CGSize) -> Path {
        Path(ellipseIn: CGRect(x: size.width / 2 - g.outerRadius, y: size.height / 2 - g.outerRadius,
                               width: 2 * g.outerRadius, height: 2 * g.outerRadius))
    }
}

/// An `NSVisualEffectView` cut to a shape with its mask image: the
/// supported way to give a non-rectangular surface real vibrancy.
private struct VisualEffectShape<S: Shape>: NSViewRepresentable {
    let shape: S

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let size = view.bounds.size == .zero ? CGSize(width: 1, height: 1) : view.bounds.size
        let path = shape.path(in: CGRect(origin: .zero, size: size))
        // NSImage draws y-up; SwiftUI paths are y-down.
        view.maskImage = NSImage(size: size, flipped: true) { _ in
            NSColor.black.setFill()
            NSBezierPath(converting: path.cgPath).fill()
            return true
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSVisualEffectView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

private extension NSBezierPath {
    // NSBezierPath(cgPath:) exists only from macOS 14.
    convenience init(converting cgPath: CGPath) {
        self.init()
        cgPath.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: move(to: points[0])
            case .addLineToPoint: line(to: points[0])
            case .addQuadCurveToPoint:
                let start = currentPoint
                // Quadratic → cubic control points.
                curve(to: points[1],
                      controlPoint1: CGPoint(x: start.x + 2 / 3 * (points[0].x - start.x), y: start.y + 2 / 3 * (points[0].y - start.y)),
                      controlPoint2: CGPoint(x: points[1].x + 2 / 3 * (points[0].x - points[1].x), y: points[1].y + 2 / 3 * (points[0].y - points[1].y)))
            case .addCurveToPoint: curve(to: points[2], controlPoint1: points[0], controlPoint2: points[1])
            case .closeSubpath: close()
            @unknown default: break
            }
        }
    }
}
