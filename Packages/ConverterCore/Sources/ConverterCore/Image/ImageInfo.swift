import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Header-level facts about an image file, read without decoding pixels.
public struct ImageInfo: Sendable, Hashable {
    /// Type ImageIO detected from the file contents, e.g. `public.heic`.
    public let typeIdentifier: String
    public let frameCount: Int
    /// The frame that represents the file: ImageIO's primary image, or the
    /// largest image for icon files (ICO/ICNS hold one image per size).
    public let primaryIndex: Int
    /// Stored pixel size of the primary frame, before EXIF orientation.
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// EXIF orientation, 1...8 (1 = upright).
    public let orientation: Int
    public let hasAlpha: Bool
    /// More than one frame in a format that animates (GIF, APNG, WebP, HEICS, AVIS).
    public let isAnimated: Bool

    /// Width as displayed, after applying orientation.
    public var width: Int { orientation >= 5 ? pixelHeight : pixelWidth }
    /// Height as displayed, after applying orientation.
    public var height: Int { orientation >= 5 ? pixelWidth : pixelHeight }

    static let animatedTypes: Set<String> = [
        "com.compuserve.gif", "public.png", "org.webmproject.webp", "public.heics", "public.avis",
    ]
    static let iconTypes: Set<String> = ["com.microsoft.ico", "com.apple.icns", "com.microsoft.cur"]

    /// Reads the header of `url`. Types ImageIO can't read go through a
    /// registered `ImageRasterizer`; they keep their own type identifier
    /// (e.g. `public.svg-image`) so "same format" checks still work.
    init?(url: URL, contentType: UTType) {
        guard let source = ImageCodec.makeSource(url: url, contentType: contentType),
              let detected = CGImageSourceGetType(source) as String?
        else { return nil }
        let type = ImageRasterizers.rasterizer(for: contentType) == nil ? detected : contentType.identifier
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var index = CGImageSourceGetPrimaryImageIndex(source)
        if Self.iconTypes.contains(type) {
            index = (0..<count).max { a, b in
                Self.pixelSize(source, a).width < Self.pixelSize(source, b).width
            } ?? index
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let size = Self.pixelSize(source, index)
        guard size.width > 0, size.height > 0 else { return nil }

        self.typeIdentifier = type
        self.frameCount = count
        self.primaryIndex = index
        self.pixelWidth = size.width
        self.pixelHeight = size.height
        let rawOrientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        self.orientation = (1...8).contains(rawOrientation) ? rawOrientation : 1
        self.hasAlpha = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        self.isAnimated = count > 1 && Self.animatedTypes.contains(type)
    }

    private static func pixelSize(_ source: CGImageSource, _ index: Int) -> (width: Int, height: Int) {
        let p = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let w = (p[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (p[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return (w, h)
    }
}
