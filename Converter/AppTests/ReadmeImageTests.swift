import AppKit
import ConverterCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import ConverterApp

/// Renders the pictures in README.md from the app's own views: the wheel
/// (stills and an animation of a whole drag) and the crop, metadata and
/// settings windows, in light and dark mode. Skipped unless
/// TEST_RUNNER_README_IMAGES names the output folder (`make readme-images`).
@MainActor
final class ReadmeImageTests: XCTestCase {
    private var out: URL!
    /// Sample files. In /tmp so the metadata window's "Where" row is short.
    private let samples = URL(fileURLWithPath: "/tmp/Pictures", isDirectory: true)

    override func setUp() async throws {
        guard let path = ProcessInfo.processInfo.environment["README_IMAGES"] else {
            throw XCTSkip("Set TEST_RUNNER_README_IMAGES to render the README images")
        }
        out = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: samples)
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: samples)
    }

    // MARK: - The wheel

    func testWheel() async throws {
        let photo = try await Self.writeScene(samples.appendingPathComponent("IMG_2041.heic"), type: "public.heic")
        let registry = ConverterRegistry(ConverterRegistry.standard.everything + [CustomCropTool { _ in }])
        let icon = try Self.thumbnail(of: photo)

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let model = wheel(for: photo, registry: registry)

            // Stills: one per ring.
            model.setMode(.formats)
            let jpeg = ringPoint(0, of: model)
            model.hover(at: jpeg)
            try writePNG(render(WheelScene(model: model, pointer: jpeg, icon: icon, dark: dark)),
                         to: "wheel-convert.\(suffix).png")

            model.setMode(.tools)
            let square = try openGroup("Crop", member: 0, of: model)
            try writePNG(render(WheelScene(model: model, pointer: square, icon: icon, dark: dark)),
                         to: "wheel-tools.\(suffix).png")

            model.setMode(.actions)
            let mail = try openGroup("Share", member: 1, of: model)
            try writePNG(render(WheelScene(model: model, pointer: mail, icon: icon, dark: dark)),
                         to: "wheel-actions.\(suffix).png")

            try writeGIF(story(model: wheel(for: photo, registry: registry), icon: icon, dark: dark),
                         to: "wheel-demo.\(suffix).gif")
        }
    }

    private func wheel(for photo: URL, registry: ConverterRegistry) -> RadialMenuModel {
        let model = RadialMenuModel(registry: registry)
        model.availableActions = { _ in FileAction.all }
        model.isPresented = true
        model.load([photo])
        return model
    }

    /// A whole drag: the wheel appears, a format is pointed at, scrolling
    /// goes to Actions and then Tools, Crop › Square is dropped on, and the
    /// result is saved.
    private func story(model: RadialMenuModel, icon: NSImage, dark: Bool) throws -> [(CGImage, Double)] {
        var frames: [(CGImage, Double)] = []
        var pointer = CGPoint(x: 0, y: 0)

        func shot(_ caption: String, delay: Double = 0.05, hover: Bool = true, scale: CGFloat = 1,
                  opacity: Double = 1, toast: String? = nil) throws {
            if hover { model.hover(at: pointer) }
            let scene = WheelScene(model: model, pointer: pointer, icon: icon, dark: dark, caption: caption,
                                   wheelScale: scale, wheelOpacity: opacity, toast: toast)
            frames.append((try render(scene), delay))
        }
        func hold(_ seconds: Double) {
            if let last = frames.popLast() { frames.append((last.0, seconds)) }
        }
        func move(to target: CGPoint, steps: Int = 6, caption: String) throws {
            let start = pointer
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let eased = t * t * (3 - 2 * t)
                pointer = CGPoint(x: start.x + (target.x - start.x) * eased, y: start.y + (target.y - start.y) * eased)
                try shot(caption)
            }
        }
        /// Out of a group's slice into its sub-ring, then along the sub-ring
        /// to a member, the way a hand would (cutting across would cross
        /// other slices and close the group).
        func moveIntoGroup(_ parent: Int, member: Int, caption: String) throws {
            let g = model.geometry
            let radius = Self.subRadius(g)
            let parentAngle = g.centerAngle(ofSlice: parent, count: model.slices.count)
            try move(to: Self.point(angle: parentAngle, radius: radius), steps: 3, caption: caption)
            let target = g.subCenterAngle(member: member, members: model.openGroupMembers.count, parent: parent,
                                          count: model.slices.count)
            let steps = 6
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let eased = t * t * (3 - 2 * t)
                pointer = Self.point(angle: parentAngle + (target - parentAngle) * eased, radius: radius)
                try shot(caption)
            }
        }

        model.setMode(.formats)
        try shot("Drag a file…", hover: false, opacity: 0)
        hold(0.8)
        for (scale, opacity) in [(0.86, 0.3), (0.93, 0.7), (0.98, 0.95), (1.0, 1.0)] {
            try shot("…and tap ⇧ Shift", hover: false, scale: scale, opacity: opacity)
        }
        hold(0.9)
        try move(to: ringPoint(0, of: model), caption: "Point at a format")
        hold(1.1)
        try move(to: ringPoint(1, of: model), steps: 4, caption: "Point at a format")
        hold(0.9)

        model.setMode(model.mode.advanced(by: 1))
        try shot("Scroll up for Actions")
        hold(0.9)
        let share = try XCTUnwrap(model.slices.firstIndex { $0.title == "Share" })
        try move(to: ringPoint(share, of: model), caption: "Scroll up for Actions")
        model.openGroup(share)
        try shot("Share, get info, copy, move…")
        hold(0.4)
        try moveIntoGroup(share, member: 1, caption: "Share, get info, copy, move…")
        hold(1.1)

        model.setMode(model.mode.advanced(by: 1))
        try shot("Scroll up again for Tools")
        hold(0.9)
        let crop = try XCTUnwrap(model.slices.firstIndex { $0.title == "Crop" })
        try move(to: ringPoint(crop, of: model), caption: "Resize, crop, compress…")
        model.openGroup(crop)
        try shot("Resize, crop, compress…")
        hold(0.4)
        try moveIntoGroup(crop, member: 0, caption: "Drop on Square")
        hold(1.2)

        let saved = "Saved “IMG_2041 (square).heic”"
        for opacity in [0.6, 0.25, 0.0] {
            try shot("Saved next to the original", hover: false, scale: 0.94 + 0.06 * opacity, opacity: opacity,
                     toast: opacity == 0 ? saved : nil)
        }
        hold(2.2)
        return frames
    }

    /// Points sit on the outer part of a slice, past its label, so the
    /// pointer and the dragged picture don't hide what's being pointed at.
    private func ringPoint(_ index: Int, of model: RadialMenuModel) -> CGPoint {
        let g = model.geometry
        return Self.point(angle: g.centerAngle(ofSlice: index, count: model.slices.count), radius: g.outerRadius - 14)
    }

    private func subPoint(_ member: Int, of parent: Int, in model: RadialMenuModel) -> CGPoint {
        let g = model.geometry
        let angle = g.subCenterAngle(member: member, members: model.openGroupMembers.count, parent: parent,
                                     count: model.slices.count)
        return Self.point(angle: angle, radius: Self.subRadius(g))
    }

    private static func subRadius(_ g: RadialGeometry) -> CGFloat {
        g.subOuterRadius - 4
    }

    private static func point(angle: Double, radius: CGFloat) -> CGPoint {
        CGPoint(x: radius * CGFloat(sin(angle)), y: radius * CGFloat(cos(angle)))
    }

    /// Opens a group and hovers one of its members; returns the pointer.
    private func openGroup(_ title: String, member: Int, of model: RadialMenuModel) throws -> CGPoint {
        let index = try XCTUnwrap(model.slices.firstIndex { $0.title == title })
        model.hover(at: ringPoint(index, of: model))
        model.openGroup(index)
        let point = subPoint(member, of: index, in: model)
        model.hover(at: point)
        return point
    }

    // MARK: - Windows

    func testWindows() async throws {
        let scene = try await Self.writeScene(samples.appendingPathComponent("IMG_2041.heic"), type: "public.heic")
        let second = try await Self.writeScene(samples.appendingPathComponent("IMG_2042.heic"), type: "public.heic")
        let tagged = try await Self.writeScene(samples.appendingPathComponent("IMG_2043.jpg"), type: "public.jpeg",
                                               properties: Self.cameraTags)

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"

            let crop = CropEditorModel(inputs: [try InputFile(url: scene), try InputFile(url: second)])
            crop.setAspect(.ratio(4, 3))
            crop.drag(.bottomRight, by: CGSize(width: -1100, height: 0))
            crop.endDrag()
            crop.drag(.move, by: CGSize(width: 420, height: 0))
            crop.endDrag()
            try writePNG(window(NSHostingView(rootView: CropEditorView(model: crop)),
                                size: NSSize(width: 860, height: 560), title: "Crop “IMG_2041.heic”", dark: dark),
                         to: "crop-editor.\(suffix).png")

            let metadata = MetadataModel(urls: [tagged])
            await metadata.loaded()
            try await Task.sleep(nanoseconds: 1_500_000_000) // the Quick Look thumbnail
            let info = MetadataView(model: metadata, onCopy: {}, onRemoveMetadata: {})
            // Scrolled past the file details to the camera and location.
            try writePNG(window(NSHostingView(rootView: info), size: NSSize(width: 440, height: 760),
                                title: "IMG_2043.jpg", dark: dark, scrolledBy: 500),
                         to: "metadata.\(suffix).png")

            let suite = "ReadmeImages-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults, loginItem: FakeLoginItem())
            let shiftDrag = ShiftDragController(queue: JobQueue(), environment: FakeDragEnvironment(), defaults: defaults)
            defer { shiftDrag.watcher.stop() }
            let host = NSHostingView(rootView: SettingsView(settings: settings, shiftDrag: shiftDrag,
                                                            registry: .standard, tab: .general))
            let size = host.fittingSize
            try writePNG(window(host, size: NSSize(width: max(size.width, 520), height: size.height),
                                title: "General", dark: dark),
                         to: "settings.\(suffix).png")
        }
    }

    // MARK: - Rendering

    private func render(_ scene: WheelScene) throws -> CGImage {
        let appearance = try XCTUnwrap(NSAppearance(named: scene.dark ? .darkAqua : .aqua))
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 2
            image = renderer.cgImage
        }
        return try XCTUnwrap(image, "rendering failed")
    }

    /// The view in a window, with a title bar, rounded corners and a shadow
    /// drawn around it, like a screenshot of a window.
    private func window(_ content: NSView, size: NSSize, title: String, dark: Bool,
                        scrolledBy: CGFloat? = nil) throws -> CGImage {
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                            backing: .buffered, defer: false)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.contentView = content
        content.frame = NSRect(origin: .zero, size: size)
        content.layoutSubtreeIfNeeded()
        if let offset = scrolledBy {
            let scrollView = try XCTUnwrap(Self.firstScrollView(in: content), "nothing to scroll")
            let clip = scrollView.contentView
            let flipped = clip.documentView?.isFlipped ?? true
            let height = clip.documentView?.bounds.height ?? 0
            clip.scroll(to: NSPoint(x: 0, y: flipped ? offset : height - offset - clip.bounds.height))
            scrollView.reflectScrolledClipView(clip)
            content.layoutSubtreeIfNeeded()
        }
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        let body = NSImage(size: size)
        body.addRepresentation(rep)

        let margin: CGFloat = 36, bar: CGFloat = 32, radius: CGFloat = 14
        let canvas = NSSize(width: size.width + 2 * margin, height: size.height + bar + 2 * margin)
        let output = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        output.size = canvas
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let frame = NSRect(x: margin, y: margin + 6, width: size.width, height: size.height + bar)
        let shape = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28)
        shadow.set()
        NSColor(white: dark ? 0.16 : 0.98, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let barRect = NSRect(x: frame.minX, y: frame.maxY - bar, width: frame.width, height: bar)
        NSColor(white: dark ? 0.19 : 0.94, alpha: 1).setFill()
        barRect.fill()
        let lights = [(1.0, 0.373, 0.341), (0.996, 0.737, 0.180), (0.157, 0.784, 0.251)]
        for (index, rgb) in lights.enumerated() {
            NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: barRect.minX + 14 + CGFloat(index) * 20, y: barRect.midY - 6,
                                        width: 12, height: 12)).fill()
        }
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor(white: dark ? 0.88 : 0.15, alpha: 1),
        ])
        let textSize = text.size()
        text.draw(at: NSPoint(x: barRect.midX - textSize.width / 2, y: barRect.midY - textSize.height / 2))
        body.draw(in: NSRect(x: frame.minX, y: frame.minY, width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()

        NSColor(white: dark ? 1 : 0, alpha: dark ? 0.16 : 0.14).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        return try XCTUnwrap(output.cgImage)
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(firstScrollView).first
    }

    private func writePNG(_ image: CGImage, to name: String) throws {
        let url = out.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func writeGIF(_ frames: [(CGImage, Double)], to name: String) throws {
        let url = out.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil))
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for (image, delay) in frames {
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                kCGImagePropertyGIFUnclampedDelayTime: delay],
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    // MARK: - Samples

    /// A small picture of the photo, for the file being dragged.
    static func thumbnail(of url: URL) throws -> NSImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 160]
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary))
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    nonisolated static var cameraTags: [CFString: Any] {
        [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensModel: "iPhone 17 Pro back triple camera 6.86mm f/1.78",
                kCGImagePropertyExifFNumber: 1.78, kCGImagePropertyExifExposureTime: 1.0 / 120,
                kCGImagePropertyExifISOSpeedRatings: [80], kCGImagePropertyExifFocalLength: 6.86,
                kCGImagePropertyExifFocalLenIn35mmFilm: 24, kCGImagePropertyExifFlash: 16,
                kCGImagePropertyExifDateTimeOriginal: "2026:06:14 19:42:08",
                kCGImagePropertyExifOffsetTimeOriginal: "+01:00",
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.500729, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.124625, kCGImagePropertyGPSLongitudeRef: "W",
                kCGImagePropertyGPSAltitude: 12, kCGImagePropertyGPSAltitudeRef: 0,
            ],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "Evening by the river"],
        ]
    }

    /// A 4032 × 3024 sky, sun and hills: something worth cropping. Written
    /// off the main thread, where encoding a large image belongs.
    nonisolated static func writeScene(_ url: URL, type: String, properties: [CFString: Any] = [:]) async throws -> URL {
        // Only read by the detached task.
        nonisolated(unsafe) let properties = properties
        return try await Task.detached {
            let (w, h) = (4032, 3024)
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw ConversionError.encoderFailed("scene")
            }
            let sky = CGGradient(colorsSpace: space, colors: [
                CGColor(srgbRed: 0.98, green: 0.62, blue: 0.42, alpha: 1),
                CGColor(srgbRed: 0.55, green: 0.55, blue: 0.85, alpha: 1),
                CGColor(srgbRed: 0.23, green: 0.32, blue: 0.62, alpha: 1),
            ] as CFArray, locations: [0, 0.45, 1])!
            context.drawLinearGradient(sky, start: CGPoint(x: 0, y: h / 3), end: CGPoint(x: 0, y: h), options: [])
            context.setFillColor(CGColor(srgbRed: 1, green: 0.86, blue: 0.55, alpha: 1))
            context.fillEllipse(in: CGRect(x: 2500, y: 1250, width: 520, height: 520))
            for (index, shade) in [(0, 0.30), (1, 0.22), (2, 0.15)] {
                context.setFillColor(CGColor(srgbRed: shade * 0.6, green: shade + 0.18, blue: shade * 0.9, alpha: 1))
                let base = CGFloat(1500 - index * 420)
                context.move(to: CGPoint(x: 0, y: 0))
                context.addLine(to: CGPoint(x: 0, y: base))
                context.addCurve(to: CGPoint(x: CGFloat(w), y: base - 300),
                                 control1: CGPoint(x: CGFloat(w) * 0.3, y: base + 520 - CGFloat(index) * 120),
                                 control2: CGPoint(x: CGFloat(w) * 0.7, y: base - 500))
                context.addLine(to: CGPoint(x: CGFloat(w), y: 0))
                context.closePath()
                context.fillPath()
            }
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
                throw ConversionError.encoderFailed("scene")
            }
            var props = properties
            props[kCGImageDestinationLossyCompressionQuality] = 0.8
            CGImageDestinationAddImage(destination, image, props as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ConversionError.encoderFailed("scene") }
            return url
        }.value
    }
}

/// The wheel over a wallpaper, with the pointer and the dragged file, and a
/// caption strip for the animation.
private struct WheelScene: View {
    @ObservedObject var model: RadialMenuModel
    var pointer: CGPoint?
    let icon: NSImage
    let dark: Bool
    var caption: String?
    var wheelScale: CGFloat = 1
    var wheelOpacity: Double = 1
    var toast: String?

    static let captionHeight: CGFloat = 58
    /// Room around the wheel for the dragged picture.
    static let margin: CGFloat = 24

    var body: some View {
        let side = model.geometry.panelSide + 2 * Self.margin
        VStack(spacing: 0) {
            ZStack {
                RadialMenuView(model: model)
                    .scaleEffect(wheelScale)
                    .opacity(wheelOpacity)
                if let toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(dark ? Color(white: 0.2) : Color.white)
                            .shadow(color: .black.opacity(0.25), radius: 10, y: 4))
                }
                if let pointer {
                    let p = CGPoint(x: side / 2 + pointer.x, y: side / 2 - pointer.y)
                    // Away from the middle, so it covers neither labels nor the caption.
                    let length = max(hypot(pointer.x, pointer.y), 1)
                    let away = length < 10 ? CGPoint(x: 0.6, y: 0.8)
                                           : CGPoint(x: pointer.x / length, y: -pointer.y / length)
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.white, lineWidth: 2))
                        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                        .opacity(0.88)
                        .position(x: p.x + away.x * 38, y: p.y + away.y * 34)
                    PointerArrow()
                        .frame(width: 16, height: 24)
                        .position(x: p.x + 8, y: p.y + 12)
                }
            }
            .frame(width: side, height: side)
            if let caption {
                Text(caption)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(dark ? Color.white : Color(white: 0.12))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(dark ? Color.white.opacity(0.12) : Color.white.opacity(0.75)))
                    .frame(height: Self.captionHeight)
            }
        }
        .frame(width: side, height: side + (caption == nil ? 0 : Self.captionHeight))
        .background(Wallpaper(dark: dark))
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

private struct Wallpaper: View {
    let dark: Bool

    var body: some View {
        // Flat, so the animation's 256-colour frames don't band.
        dark ? Color(red: 0.15, green: 0.14, blue: 0.23) : Color(red: 0.88, green: 0.88, blue: 0.97)
    }
}

/// The system's arrow pointer: black with a white outline.
private struct PointerArrow: View {
    var body: some View {
        Canvas { context, _ in
            let points: [(CGFloat, CGFloat)] = [(1, 1), (1, 18.5), (5.3, 14.3), (8.4, 21.5), (11.3, 20.3),
                                                (8.3, 13.2), (14.2, 13.2)]
            var path = Path()
            path.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            path.closeSubpath()
            context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: 2.4, lineJoin: .round))
            context.fill(path, with: .color(.black))
        }
    }
}
