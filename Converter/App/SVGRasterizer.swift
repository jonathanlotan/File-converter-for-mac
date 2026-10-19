import AppKit
import ConverterCore
import ImageIO
import UniformTypeIdentifiers

/// Renders SVG files with AppKit's built-in SVG support so ConverterCore can
/// convert them like any bitmap. Registered with `ImageRasterizers` at launch.
struct SVGRasterizer: ImageRasterizer {
    /// Longest side of the bitmap: twice the SVG's own size, but at least
    /// this many pixels so small icons come out usable.
    static let minimumLongestSide: CGFloat = 1024
    static let maximumLongestSide: CGFloat = 8192

    var supportedTypes: [UTType] { [.svg] }

    func rasterize(_ url: URL) throws -> Data {
        guard let image = NSImage(contentsOf: url), image.isValid else {
            throw ConversionError.unreadableInput(url)
        }
        var size = image.size
        if size.width <= 0 || size.height <= 0 { size = NSSize(width: 512, height: 512) }
        let longest = max(size.width, size.height)
        let scale = min(max(2, Self.minimumLongestSide / longest), Self.maximumLongestSide / longest)
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError.encoderFailed("couldn't allocate \(width)×\(height) for the SVG") }

        // NSGraphicsContext.current is per thread, so this is safe off the main thread.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        let data = NSMutableData()
        guard let bitmap = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw ConversionError.encoderFailed("couldn't render the SVG") }
        CGImageDestinationAddImage(destination, bitmap, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encoderFailed("couldn't render the SVG") }
        return data as Data
    }
}
