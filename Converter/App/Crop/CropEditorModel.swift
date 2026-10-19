import ConverterCore
import CoreGraphics
import Foundation
import ImageIO

/// Crop › Custom…: opens the crop editor rather than cropping straight away.
struct CustomCropTool: InteractiveTool {
    let open: @MainActor @Sendable ([InputFile]) -> Void

    var id: String { "image.crop.custom" }
    var title: String { "Custom…" }
    var role: ConverterRole { .tool }
    var menuGroup: String? { "Crop" }
    var isAvailable: Bool { true }

    func accepts(_ input: InputFile) -> Bool { input.image != nil }

    func output(for input: InputFile) -> OutputSpec {
        CropImageConverter(.region(CropRegion(x: 0, y: 0, width: 1, height: 1), size: nil)).output(for: input)
    }

    func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        throw ConversionError.unsupported("Choose the crop in the crop editor first.")
    }

    @MainActor func begin(with inputs: [InputFile]) { open(inputs) }
}

/// The crop editor's state: which image is showing, the part to keep (in
/// the image's upright pixels, from the top-left), the shape it's held to,
/// and an optional exact size for the result. Plain geometry, so tests can
/// drive it without a window.
@MainActor
final class CropEditorModel: ObservableObject {
    enum Aspect: Hashable, Identifiable {
        case free
        case original
        case ratio(Int, Int)

        var id: String { title }

        var title: String {
            switch self {
            case .free: return "Freeform"
            case .original: return "Original"
            case .ratio(1, 1): return "Square"
            case .ratio(let w, let h): return "\(w):\(h)"
            }
        }
    }

    /// What a drag moves: one of the eight handles, or the whole region.
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move
    }

    static let aspects: [Aspect] = [.free, .original, .ratio(1, 1), .ratio(4, 3), .ratio(3, 2), .ratio(16, 9),
                                    .ratio(3, 4), .ratio(2, 3), .ratio(9, 16)]
    /// Smallest side a region can be dragged down to.
    static let minimumSide = 16
    /// Largest exact size that can be typed in.
    static let maximumSide = 30_000

    let inputs: [InputFile]
    @Published private(set) var index = 0
    @Published private(set) var region: CropRegion
    @Published private(set) var aspect: Aspect = .free
    /// Exact pixel size for the result; nil keeps the region's own size.
    @Published private(set) var outputSize: PixelSize?
    /// The image on show, upright and at most 2048 px.
    @Published private(set) var preview: CGImage?

    /// Called with the crop for each image the user crops.
    var onCrop: (CropImageConverter, InputFile) -> Void = { _, _ in }
    /// Called when the last image is done, or the editor is cancelled.
    var onFinish: () -> Void = {}

    private var dragStart: CropRegion?

    /// `inputs` must be images (the editor only offers itself for them).
    init(inputs: [InputFile], loadsPreviews: Bool = true) {
        self.inputs = inputs
        self.loadsPreviews = loadsPreviews
        region = CropRegion(x: 0, y: 0, width: 1, height: 1)
        show(0)
    }

    private let loadsPreviews: Bool

    var input: InputFile { inputs[index] }
    var imageSize: PixelSize { PixelSize(width: input.image?.width ?? 1, height: input.image?.height ?? 1) }
    var fullRegion: CropRegion { CropRegion(x: 0, y: 0, width: imageSize.width, height: imageSize.height) }
    /// Size of the file the crop will save.
    var resultSize: PixelSize { outputSize ?? PixelSize(width: region.width, height: region.height) }
    var hasMore: Bool { index + 1 < inputs.count }
    var isUnchanged: Bool { region == fullRegion && outputSize == nil }
    var converter: CropImageConverter { CropImageConverter(.region(region, size: outputSize)) }

    /// The shape choices, plus the one typed in as an exact size.
    var aspectChoices: [Aspect] { Self.aspects.contains(aspect) ? Self.aspects : Self.aspects + [aspect] }

    /// Width ÷ height that regions are held to; nil when free.
    var ratio: Double? {
        switch aspect {
        case .free: return nil
        case .original: return Double(imageSize.width) / Double(imageSize.height)
        case .ratio(let w, let h): return Double(w) / Double(h)
        }
    }

    // MARK: - Shape and size

    /// Holds the region to a shape: as large as the image allows, around
    /// the region's current centre. Clears an exact size.
    func setAspect(_ aspect: Aspect) {
        self.aspect = aspect
        outputSize = nil
        if let ratio { region = Self.fitted(region, ratio: ratio, inside: fullRegion, aroundCentreOf: region) }
    }

    /// Typing a width asks for an exact result size. The height follows the
    /// current shape (or stays, if it was typed already), the region takes
    /// that shape, and the crop is scaled to fit. nil goes back to the
    /// region's own size.
    func setOutputWidth(_ width: Int?) {
        guard let width = width.map(Self.side) else { return setOutputSize(nil) }
        let height = outputSize?.height ?? max(1, Int((Double(width) * Double(region.height) / Double(region.width)).rounded()))
        setOutputSize(PixelSize(width: width, height: Self.side(height)))
    }

    func setOutputHeight(_ height: Int?) {
        guard let height = height.map(Self.side) else { return setOutputSize(nil) }
        let width = outputSize?.width ?? max(1, Int((Double(height) * Double(region.width) / Double(region.height)).rounded()))
        setOutputSize(PixelSize(width: Self.side(width), height: height))
    }

    func setOutputSize(_ size: PixelSize?) {
        outputSize = size
        guard let size else { return }
        let divisor = Self.gcd(size.width, size.height)
        aspect = .ratio(size.width / divisor, size.height / divisor)
        // Within the part already chosen, so typing a size doesn't undo a drag.
        region = Self.fitted(region, ratio: Double(size.width) / Double(size.height), inside: region, aroundCentreOf: region)
    }

    func reset() {
        aspect = .free
        outputSize = nil
        region = fullRegion
    }

    // MARK: - Dragging

    /// Moves a handle (or the region) by `translation` image pixels from
    /// where the drag began, y down.
    func drag(_ handle: Handle, by translation: CGSize) {
        let start = dragStart ?? region
        dragStart = start
        region = Self.dragged(start, handle: handle, by: translation, ratio: ratio, in: imageSize)
    }

    func endDrag() {
        dragStart = nil
    }

    // MARK: - Finishing

    func crop() {
        onCrop(converter, input)
        advance()
    }

    func skip() {
        advance()
    }

    func cancel() {
        onFinish()
    }

    /// The next image keeps the shape and exact size, so a batch comes out alike.
    private func advance() {
        guard hasMore else { return onFinish() }
        show(index + 1)
    }

    private func show(_ newIndex: Int) {
        index = newIndex
        dragStart = nil
        region = fullRegion
        if let ratio { region = Self.fitted(region, ratio: ratio, inside: fullRegion, aroundCentreOf: fullRegion) }
        preview = loadsPreviews ? Self.preview(of: input) : nil
    }

    // MARK: - Geometry

    /// The largest region of shape `ratio` inside `bounds`, centred on
    /// `centre`'s middle as far as `bounds` allows.
    static func fitted(_ region: CropRegion, ratio: Double, inside bounds: CropRegion,
                       aroundCentreOf centre: CropRegion) -> CropRegion {
        var w = Double(bounds.width), h = w / ratio
        if h > Double(bounds.height) { h = Double(bounds.height); w = h * ratio }
        let cx = Double(centre.x) + Double(centre.width) / 2, cy = Double(centre.y) + Double(centre.height) / 2
        let x = min(max(cx - w / 2, Double(bounds.x)), Double(bounds.x + bounds.width) - w)
        let y = min(max(cy - h / 2, Double(bounds.y)), Double(bounds.y + bounds.height) - h)
        return CropRegion(x: Int(x.rounded()), y: Int(y.rounded()),
                          width: max(1, Int(w.rounded())), height: max(1, Int(h.rounded())))
    }

    /// `start` with `handle` moved by `t`. The opposite edge or corner stays
    /// put; with a shape, an edge handle grows the other way around the
    /// middle. Never leaves the image or gets smaller than `minimumSide`.
    static func dragged(_ start: CropRegion, handle: Handle, by t: CGSize, ratio: Double?, in size: PixelSize) -> CropRegion {
        let width = Double(size.width), height = Double(size.height)
        var x = Double(start.x), y = Double(start.y), w = Double(start.width), h = Double(start.height)
        let dx = Double(t.width), dy = Double(t.height)
        let minSide = Double(min(minimumSide, size.width, size.height))
        func result() -> CropRegion {
            CropRegion(x: Int(x.rounded()), y: Int(y.rounded()), width: Int(w.rounded()), height: Int(h.rounded()))
                .clamped(to: size)
        }

        if handle == .move {
            x = min(max(x + dx, 0), width - w)
            y = min(max(y + dy, 0), height - h)
            return result()
        }
        let left = [.topLeft, .left, .bottomLeft].contains(handle)
        let right = [.topRight, .right, .bottomRight].contains(handle)
        let top = [.topLeft, .top, .topRight].contains(handle)
        let bottom = [.bottomLeft, .bottom, .bottomRight].contains(handle)
        let maxX = x + w, maxY = y + h

        guard let r = ratio else {
            if left { x = min(max(x + dx, 0), maxX - minSide); w = maxX - x }
            if right { w = min(max(w + dx, minSide), width - x) }
            if top { y = min(max(y + dy, 0), maxY - minSide); h = maxY - y }
            if bottom { h = min(max(h + dy, minSide), height - y) }
            return result()
        }

        let horizontal = left || right, vertical = top || bottom
        let fromX = w + (right ? dx : -dx)
        let fromY = (h + (bottom ? dy : -dy)) * r
        var newW: Double
        if horizontal && vertical {
            // A corner follows whichever way the pointer moved further.
            newW = abs(dx) >= abs(dy) * r ? fromX : fromY
        } else {
            newW = horizontal ? fromX : fromY
        }
        let cx = x + w / 2, cy = y + h / 2
        let maxW = horizontal ? (right ? width - x : maxX) : 2 * min(cx, width - cx)
        let maxH = vertical ? (bottom ? height - y : maxY) : 2 * min(cy, height - cy)
        let limit = min(maxW, maxH * r)
        newW = min(max(newW, minSide, minSide * r), limit)
        let newH = newW / r
        x = horizontal ? (right ? x : maxX - newW) : cx - newW / 2
        y = vertical ? (bottom ? y : maxY - newH) : cy - newH / 2
        w = newW
        h = newH
        return result()
    }

    private static func side(_ value: Int) -> Int {
        min(max(value, 1), maximumSide)
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? max(a, 1) : gcd(b, a % b)
    }

    /// The image upright, small enough to draw quickly.
    static func preview(of input: InputFile) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
        ]
        if let source = CGImageSourceCreateWithURL(input.url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, input.image?.primaryIndex ?? 0, options as CFDictionary) {
            return image
        }
        return nil
    }
}
