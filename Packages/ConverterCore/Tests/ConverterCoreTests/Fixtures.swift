import CoreGraphics
import Foundation
import ImageIO
@testable import ConverterCore

/// A generated sample file and what a converter should find in it.
struct Fixture: CustomStringConvertible {
    let url: URL
    /// Displayed size (after EXIF orientation).
    let width: Int
    let height: Int
    let frames: Int
    let animated: Bool
    let dpi: Double
    /// Total animation length in seconds.
    let duration: Double

    var name: String { url.lastPathComponent }
    var description: String { name }
}

/// Builds sample images in code so the tests don't depend on downloaded files.
enum Samples {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    static let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

    /// Blue card with a red top-left quadrant. With `alpha`, the bottom-right
    /// quadrant is fully transparent.
    static func testCard(width: Int = 320, height: Int = 200, alpha: Bool = false) -> CGImage {
        let info = alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: sRGB, bitmapInfo: info.rawValue)!
        context.setFillColor(blue)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red)
        // Core Graphics' origin is bottom-left, so the top-left quadrant starts at height/2.
        context.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height - height / 2))
        if alpha {
            context.clear(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height / 2))
        }
        return context.makeImage()!
    }

    static func solid(_ color: CGColor, width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func write(_ images: [CGImage], type: String, to url: URL,
                      fileProperties: [CFString: Any] = [:], frameProperties: [CFString: Any] = [:]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil) else {
            throw ConversionError.encoderFailed("can't create \(type) fixture")
        }
        if !fileProperties.isEmpty { CGImageDestinationSetProperties(destination, fileProperties as CFDictionary) }
        for image in images { CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary) }
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.encoderFailed("can't write \(type) fixture") }
    }

    /// EXIF, GPS and camera fields used to check that metadata is kept or removed.
    static var cameraMetadata: [CFString: Any] { [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00",
                                         kCGImagePropertyExifLensModel: "Test Lens 50mm"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 32.08, kCGImagePropertyGPSLatitudeRef: "N",
                                        kCGImagePropertyGPSLongitude: 34.78, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "TestCam", kCGImagePropertyTIFFModel: "One"],
    ] }

    // Public WebP test vectors (1×1 px): lossy, and lossy with alpha.
    static let webpLossy = "UklGRiIAAABXRUJQVlA4IBYAAAAwAQCdASoBAAEADsD+JaQAA3AAAAAA"
    static let webpAlpha = "UklGRkoAAABXRUJQVlA4WAoAAAAQAAAAAAAAAAAAQUxQSAwAAAARBxAR/Q9ERP8DAABWUDggGAAAABQBAJ0BKgEAAQAAAP4AAA3AAP7mtQAAAA=="

    /// Writes one sample of every readable image kind we can produce here.
    static func makeAll(in folder: URL) throws -> [Fixture] {
        var fixtures: [Fixture] = []
        func add(_ name: String, width: Int = 320, height: Int = 200, frames: Int = 1, animated: Bool = false,
                 dpi: Double = 72, duration: Double = 0, _ make: (URL) throws -> Void) rethrows {
            let url = folder.appendingPathComponent(name)
            try make(url)
            fixtures.append(Fixture(url: url, width: width, height: height, frames: frames, animated: animated,
                                    dpi: dpi, duration: duration))
        }
        let card = testCard()
        let alphaCard = testCard(alpha: true)
        let writable = ImageCodec.writableTypes

        try add("photo.jpg") {
            var props = cameraMetadata
            props[kCGImageDestinationLossyCompressionQuality] = 0.95
            try write([card], type: "public.jpeg", to: $0, frameProperties: props)
        }
        // Stored 320×200 but tagged "rotate 90° clockwise", so it displays as 200×320.
        try add("rotated.jpg", width: 200, height: 320) {
            try write([card], type: "public.jpeg", to: $0, frameProperties: [kCGImagePropertyOrientation: 6])
        }
        try add("alpha.png") { try write([alphaCard], type: "public.png", to: $0) }
        try add("photo.heic") { try write([alphaCard], type: "public.heic", to: $0) }
        if writable.contains("public.avif") {
            try add("photo.avif") { try write([card], type: "public.avif", to: $0) }
        }
        try add("image.bmp") { try write([card], type: "com.microsoft.bmp", to: $0) }
        try add("image.jp2") { try write([alphaCard], type: "public.jpeg-2000", to: $0) }
        try add("image.psd") { try write([alphaCard], type: "com.adobe.photoshop-image", to: $0) }
        try add("image.tga") { try write([card], type: "com.truevision.tga-image", to: $0) }
        if writable.contains("com.ilm.openexr-image") {
            try add("image.exr") { try write([card], type: "com.ilm.openexr-image", to: $0) }
        }
        try add("static.gif") { try write([card], type: "com.compuserve.gif", to: $0) }
        let colors = [red, blue, CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1), CGColor(gray: 0.5, alpha: 1)]
        try add("anim.gif", width: 120, height: 80, frames: 4, animated: true, duration: 0.4) {
            try write(colors.map { solid($0, width: 120, height: 80) }, type: "com.compuserve.gif", to: $0,
                      fileProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]],
                      frameProperties: [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]])
        }
        try add("scan.tiff", frames: 3, dpi: 144) {
            try write([card, alphaCard, card], type: "public.tiff", to: $0,
                      frameProperties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
        }
        try add("icon.ico", width: 64, height: 64, frames: 2) {
            try write([testCard(width: 16, height: 16, alpha: true), testCard(width: 64, height: 64, alpha: true)],
                      type: "com.microsoft.ico", to: $0)
        }
        try add("icon.icns", width: 128, height: 128, frames: 2) {
            try write([testCard(width: 32, height: 32, alpha: true), testCard(width: 128, height: 128, alpha: true)],
                      type: "com.apple.icns", to: $0)
        }
        try add("tiny.webp", width: 1, height: 1) { try Data(base64Encoded: webpLossy)!.write(to: $0) }
        try add("alpha.webp", width: 1, height: 1) { try Data(base64Encoded: webpAlpha)!.write(to: $0) }
        return fixtures
    }
}

/// Reads back RGBA pixels of an output for colour checks.
struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(url: URL) throws {
        let source = try ImageCodec.openSource(url)
        guard let image = CGImageSourceCreateImageAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil) else {
            throw ConversionError.unreadableInput(url)
        }
        try self.init(image: image)
    }

    init(image: CGImage) throws {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        try buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: Samples.sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw ConversionError.encoderFailed("pixel buffer") }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w
        height = h
        bytes = buffer
    }

    /// RGBA at (x, y) measured from the top-left corner.
    func rgba(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3]))
    }

    func isRed(_ x: Int, _ y: Int) -> Bool { let p = rgba(x, y); return p.r > 200 && p.g < 60 && p.b < 60 }
    func isBlue(_ x: Int, _ y: Int) -> Bool { let p = rgba(x, y); return p.b > 200 && p.r < 60 && p.g < 60 }
    func isWhite(_ x: Int, _ y: Int) -> Bool { let p = rgba(x, y); return p.r > 245 && p.g > 245 && p.b > 245 }

    static func == (a: Pixels, b: Pixels) -> Bool { a.width == b.width && a.height == b.height && a.bytes == b.bytes }
}

/// A fresh folder per test, removed afterwards.
func makeTemporaryFolder(_ label: String = "ConverterCoreTests") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Copies `fixture` into its own empty folder so outputs don't collide.
func isolatedCopy(of fixture: Fixture, in root: URL) throws -> InputFile {
    let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let copy = folder.appendingPathComponent(fixture.name)
    try FileManager.default.copyItem(at: fixture.url, to: copy)
    return try InputFile(url: copy)
}

func folderContents(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}
