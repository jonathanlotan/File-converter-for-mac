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
            var image = try decode(source, index: index, maxPixelSize: request.maxPixelSize)
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
            let image = try decode(source, index: index, maxPixelSize: request.maxPixelSize)
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
        let image = try decode(source, index: index, maxPixelSize: request.maxPixelSize)
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
