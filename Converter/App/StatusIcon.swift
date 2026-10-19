import AppKit

/// The menu bar icon: the app symbol, a progress ring while converting, and
/// a brief badge when a batch finishes. Template images, so they follow the
/// menu bar's light or dark appearance.
enum StatusIcon {
    enum Badge {
        case none
        case done
        case failed
    }

    private static let size = NSSize(width: 18, height: 18)

    static func image(progress: Double?, badge: Badge = .none) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            switch badge {
            case .done:
                drawSymbol("checkmark.circle", pointSize: 14, in: rect)
            case .failed:
                drawSymbol("exclamationmark.triangle", pointSize: 13, in: rect)
            case .none:
                if let progress {
                    drawRing(progress: progress, in: rect)
                    drawSymbol("arrow.2.squarepath", pointSize: 8, in: rect)
                } else {
                    drawSymbol("arrow.2.squarepath", pointSize: 13, in: rect)
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Swivel"
        return image
    }

    private static func drawSymbol(_ name: String, pointSize: CGFloat, in rect: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let s = symbol.size
        symbol.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
    }

    private static func drawRing(progress: Double, in rect: NSRect) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1.5

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.3).setStroke()
        track.stroke()

        // Clockwise from 12 o'clock.
        let clamped = max(0.02, min(progress, 1))
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * clamped, clockwise: true)
        arc.lineWidth = 2
        arc.lineCapStyle = .round
        NSColor.black.setStroke()
        arc.stroke()
    }
}
