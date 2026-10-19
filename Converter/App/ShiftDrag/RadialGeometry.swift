import CoreGraphics
import Foundation

/// Sizes of the radial menu and the maths that maps a point to a slice.
///
/// Angles are in radians, measured clockwise from 12 o'clock; slice 0 is
/// centred at the top. Points are relative to the ring's centre with y up
/// (AppKit's convention). The SwiftUI view, which has y down, flips y.
struct RadialGeometry: Equatable {
    var innerRadius: CGFloat = 54
    var outerRadius: CGFloat = 148
    var subInnerRadius: CGFloat = 154
    var subOuterRadius: CGFloat = 220
    /// Widest a sub-ring slice may be (about 28°).
    var maxSubSpan: Double = .pi / 6.5
    /// Extra reach beyond the sub-ring that still counts as inside it.
    var subSlack: CGFloat = 16

    /// Side of the square window that holds the ring and its sub-ring.
    var panelSide: CGFloat { 2 * (subOuterRadius + subSlack) }

    enum Hit: Equatable {
        /// The hole in the middle: dropping there cancels.
        case center
        case slice(Int)
        case subSlice(Int)
        case outside
    }

    func span(count: Int) -> Double {
        2 * .pi / Double(max(count, 1))
    }

    func centerAngle(ofSlice index: Int, count: Int) -> Double {
        Double(index) * span(count: count)
    }

    func subSpan(members: Int) -> Double {
        min(maxSubSpan, 2 * .pi / Double(max(members, 1)))
    }

    /// Centre angle of member `index` of a sub-ring fanned out around the
    /// parent slice's centre.
    func subCenterAngle(member index: Int, members: Int, parent: Int, count: Int) -> Double {
        let s = subSpan(members: members)
        return centerAngle(ofSlice: parent, count: count) - s * Double(members) / 2 + s * (Double(index) + 0.5)
    }

    /// What's under `point`. `openGroup` is the slice whose sub-ring is open
    /// and how many members it has.
    func hit(_ point: CGPoint, count: Int, openGroup: (parent: Int, members: Int)? = nil) -> Hit {
        let radius = hypot(point.x, point.y)
        let angle = Self.clockwiseAngle(of: point)
        if radius < innerRadius { return .center }
        if radius < subInnerRadius {
            guard count > 0 else { return .outside }
            let s = span(count: count)
            return .slice(Int(((angle + s / 2) / s).rounded(.down)) % count)
        }
        if let group = openGroup, group.members > 0, radius <= subOuterRadius + subSlack {
            let s = subSpan(members: group.members)
            let offset = Self.signedDifference(angle, centerAngle(ofSlice: group.parent, count: count))
                + s * Double(group.members) / 2
            if offset >= 0 && offset < s * Double(group.members) {
                return .subSlice(min(Int(offset / s), group.members - 1))
            }
        }
        return .outside
    }

    /// Clockwise angle from 12 o'clock of a y-up point, in [0, 2π).
    static func clockwiseAngle(of point: CGPoint) -> Double {
        let angle = atan2(Double(point.x), Double(point.y))
        return angle < 0 ? angle + 2 * .pi : angle
    }

    /// `a - b`, wrapped into (-π, π].
    static func signedDifference(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d <= -.pi { d += 2 * .pi }
        return d
    }

    /// A point at `angle` and `radius` in y-down view coordinates around `center`.
    static func viewPoint(angle: Double, radius: CGFloat, center: CGPoint) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }
}
