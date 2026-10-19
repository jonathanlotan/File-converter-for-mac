import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Shared ImageIO plumbing for every image converter: decode frames upright,
/// carry metadata across, and write ImageIO, PDF and icon outputs.
enum ImageCodec {
    /// Type identifiers ImageIO can encode on this system (checked once).
    static let writableTypes: Set<String> = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func openSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw ConversionError.unreadableInput(url)
        }
        return source
    }

    /// The input's image source, rendered through a registered
    /// `ImageRasterizer` when ImageIO can't read the type itself.
    static func openSource(_ input: InputFile) throws -> CGImageSource {
        guard let source = makeSource(url: input.url, contentType: input.contentType) else {
            throw ConversionError.unreadableInput(input.url)
        }
        return source
    }

    static func makeSource(url: URL, contentType: UTType) -> CGImageSource? {
        if let rasterizer = ImageRasterizers.rasterizer(for: contentType) {
            guard let data = try? rasterizer.rasterize(url) else { return nil }
            return CGImageSourceCreateWithData(data as CFData, nil)
        }
        return CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    static func properties(_ source: CGImageSource, _ index: Int) -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
    }

    static func orientation(_ properties: [CFString: Any]) -> Int {
        let value = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (1...8).contains(value) ? value : 1
    }

    // MARK: - Decoding

    /// Decodes frame `index` upright (EXIF orientation applied). When
    /// `maxPixelSize` is given, scales so the longest side is that size.
    static func decode(_ source: CGImageSource, index: Int, maxPixelSize: Int? = nil) throws -> CGImage {
        let props = properties(source, index)
        let upright = orientation(props) == 1
        if upright && maxPixelSize == nil {
            if let image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
                return image
            }
            throw ConversionError.encoderFailed("couldn't decode image \(index + 1)")
        }
        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let longest = maxPixelSize ?? max(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(longest, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ConversionError.encoderFailed("couldn't decode image \(index + 1)")
        }
        return image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Composites transparent pixels onto white, for formats without alpha.
    static func flattenedOnWhite(_ image: CGImage) throws -> CGImage {
        guard hasAlpha(image) else { return image }
        // Keep the image's RGB colour space when an 8-bit buffer supports it;
        // extended-range spaces (EXR, HDR) don't, so those go to sRGB.
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        }
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let context = own.flatMap(makeContext) ?? makeContext(sRGB)
        else { throw ConversionError.encoderFailed("couldn't allocate image buffer") }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let flat = context.makeImage() else { throw ConversionError.encoderFailed("couldn't flatten image") }
        return flat
    }

    /// The image scaled to fit a transparent `side`×`side` square, centred.
    static func squareIcon(_ image: CGImage, side: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError.encoderFailed("couldn't allocate icon buffer") }
        context.interpolationQuality = .high
        let scale = Double(side) / Double(max(image.width, image.height))
        let w = Double(image.width) * scale, h = Double(image.height) * scale
        context.draw(image, in: CGRect(x: (Double(side) - w) / 2, y: (Double(side) - h) / 2, width: w, height: h))
        guard let icon = context.makeImage() else { throw ConversionError.encoderFailed("couldn't draw icon") }
        return icon
    }

    /// `region` of `image`, scaled to `size` when one is given. The region
    /// is in the upright pixels of an image `reference` in size; a frame of
    /// another size (a smaller icon image) gets the same part of itself.
    static func crop(_ image: CGImage, to region: CropRegion, reference: PixelSize, scaledTo size: PixelSize?) throws -> CGImage {
        var rect = region.rect
        if image.width != reference.width || image.height != reference.height {
            let sx = Double(image.width) / Double(max(reference.width, 1))
            let sy = Double(image.height) / Double(max(reference.height, 1))
            rect = CGRect(x: rect.minX * sx, y: rect.minY * sy, width: rect.width * sx, height: rect.height * sy).integral
        }
        // CGImage crops measure from the top-left, like the region.
        rect = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isEmpty, let cropped = image.cropping(to: rect) else {
            throw ConversionError.encoderFailed("couldn't crop the image")
        }
        guard let size, size.width != cropped.width || size.height != cropped.height else { return cropped }
        return try scaled(cropped, to: size)
    }

    /// The image redrawn at exactly `size` (no aspect fitting).
    static func scaled(_ image: CGImage, to size: PixelSize) throws -> CGImage {
        let alpha = hasAlpha(image)
        let info = (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: space, bitmapInfo: info)
        }
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard size.width > 0, size.height > 0, let context = own.flatMap(makeContext) ?? makeContext(sRGB)
        else { throw ConversionError.encoderFailed("couldn't allocate image buffer") }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let result = context.makeImage() else { throw ConversionError.encoderFailed("couldn't scale the image") }
        return result
    }

    // MARK: - Metadata and animation

    /// EXIF/GPS/IPTC/TIFF properties of a frame, rewritten for an upright,
    /// possibly resized copy (orientation 1, no stale pixel dimensions).
    static func carriedMetadata(_ props: [CFString: Any]) -> [CFString: Any] {
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary, kCGImagePropertyExifAuxDictionary,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let value = props[key] { out[key] = value }
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            out[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        out[kCGImagePropertyOrientation] = 1
        return out
    }

    // Computed because CFString isn't Sendable, so it can't be a static let.
    private static var animationKeys: [(dictionary: CFString, unclamped: CFString, clamped: CFString)] {
        [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
    }

    /// How long a frame shows, in seconds. Very short delays are treated the
    /// way browsers treat them (0.1 s).
    static func frameDelay(_ props: [CFString: Any]) -> Double {
        for keys in animationKeys {
            guard let dict = props[keys.dictionary] as? [CFString: Any] else { continue }
            let value = (dict[keys.unclamped] as? NSNumber)?.doubleValue ?? (dict[keys.clamped] as? NSNumber)?.doubleValue
            if let value { return value < 0.011 ? 0.1 : value }
        }
        return 0.1
    }

    /// Loop count of an animated source (0 = forever).
    static func loopCount(_ source: CGImageSource) -> Int {
        let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any] ?? [:]
        let pairs: [(CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSLoopCount),
        ]
        for (dictionary, key) in pairs {
            if let dict = props[dictionary] as? [CFString: Any], let n = dict[key] as? NSNumber { return n.intValue }
        }
        return 0
    }

    // MARK: - Encoding

    struct EncodeRequest {
        var format: ImageFormat
        /// Frames to write, in order.
        var frames: [Int]
        /// Longest side of the output; nil keeps the original size.
        var maxPixelSize: Int?
        /// Lossy quality 0...1, used when the format is lossy.
        var quality: Double
        var keepMetadata: Bool
        /// Applied to each decoded (upright) frame before it's written, e.g.
        /// a crop.
        var transform: ((CGImage) throws -> CGImage)? = nil

        /// Frame `index` decoded upright, resized and transformed as requested.
        func image(from source: CGImageSource, index: Int) throws -> CGImage {
            let image = try ImageCodec.decode(source, index: index, maxPixelSize: maxPixelSize)
            return try transform?(image) ?? image
        }
    }

    /// Decodes the requested frames from `source` and writes `request.format`
    /// to `url`, reporting progress per frame.
    static func encode(_ source: CGImageSource, _ request: EncodeRequest, to url: URL, progress: ProgressHandler) throws {
        switch request.format.writer {
        case .imageIO: try writeImageIO(source, request, to: url, progress: progress)
        case .pdf: try writePDF(source, request, to: url, progress: progress)
        case .icon(let sizes): try writeIcon(source, request, sizes: sizes, to: url)
        }
    }

    private static func writeImageIO(_ source: CGImageSource, _ request: EncodeRequest, to url: URL, progress: ProgressHandler) throws {
        let format = request.format
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.typeIdentifier as CFString, request.frames.count, nil) else {
            throw ConversionError.encoderFailed("this Mac can't write \(format.title)")
        }
        let animated = format.supportsAnimation && request.frames.count > 1
        if animated {
            let fileProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount(source)]]
            CGImageDestinationSetProperties(destination, fileProps as CFDictionary)
        }
        for (n, index) in request.frames.enumerated() {
            try Task.checkCancellation()
            let sourceProps = properties(source, index)
            var image = try request.image(from: source, index: index)
            if !format.supportsAlpha { image = try flattenedOnWhite(image) }

            var props: [CFString: Any] = request.keepMetadata && format.carriesMetadata
                ? carriedMetadata(sourceProps)
                : [kCGImagePropertyOrientation: 1]
            if format.isLossy {
                props[kCGImageDestinationLossyCompressionQuality] = request.quality
            }
            if format == .tiff {
                var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                tiff[kCGImagePropertyTIFFCompression] = 5 // LZW
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
            if animated {
                let delay = frameDelay(sourceProps)
                props[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: delay,
                                                        kCGImagePropertyGIFUnclampedDelayTime: delay]
            }
            CGImageDestinationAddImage(destination, image, props as CFDictionary)
            progress(Double(n + 1) / Double(request.frames.count) * 0.95)
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.encoderFailed("ImageIO couldn't write \(format.title)")
        }
        // An encoder can report success and still write a file nothing can
        // open (macOS 15's PSD writer, for a 1×1 image). Fail instead, so the
        // job leaves no broken file behind.
        guard let written = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(written) > 0,
              CGImageSourceCreateImageAtIndex(written, 0, nil) != nil else {
            throw ConversionError.encoderFailed("this Mac couldn't make a readable \(format.title) of this image")
        }
    }

    /// One page per frame. Page size comes from the image's DPI, so a
    /// 300 dpi scan becomes a page of its real printed size.
    private static func writePDF(_ source: CGImageSource, _ request: EncodeRequest, to url: URL, progress: ProgressHandler) throws {
        let info: [CFString: Any] = [kCGPDFContextCreator: "Converter"]
        guard let context = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw ConversionError.encoderFailed("couldn't create PDF")
        }
        for (n, index) in request.frames.enumerated() {
            try Task.checkCancellation()
            let props = properties(source, index)
            let image = try request.image(from: source, index: index)
            let dpiX = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
            let dpiY = (props[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 72
            var box = CGRect(x: 0, y: 0,
                             width: Double(image.width) * 72 / (dpiX > 0 ? dpiX : 72),
                             height: Double(image.height) * 72 / (dpiY > 0 ? dpiY : 72))
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            context.endPage()
            progress(Double(n + 1) / Double(request.frames.count) * 0.95)
        }
        context.closePDF()
        try Task.checkCancellation()
    }

    /// Standard icon sizes up to the source's size (at least the smallest).
    static func iconSizes(_ sizes: [Int], forLongestSide longest: Int) -> [Int] {
        let fitting = sizes.filter { $0 <= longest }
        return fitting.isEmpty ? [sizes[0]] : fitting
    }

    private static func writeIcon(_ source: CGImageSource, _ request: EncodeRequest, sizes: [Int], to url: URL) throws {
        let index = request.frames.first ?? CGImageSourceGetPrimaryImageIndex(source)
        let image = try request.image(from: source, index: index)
        let chosen = iconSizes(sizes, forLongestSide: max(image.width, image.height))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, request.format.typeIdentifier as CFString, chosen.count, nil) else {
            throw ConversionError.encoderFailed("this Mac can't write \(request.format.title)")
        }
        for side in chosen {
            try Task.checkCancellation()
            CGImageDestinationAddImage(destination, try squareIcon(image, side: side), nil)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.encoderFailed("ImageIO couldn't write \(request.format.title)")
        }
    }
}
