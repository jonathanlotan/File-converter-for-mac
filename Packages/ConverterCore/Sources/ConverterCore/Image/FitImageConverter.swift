import CoreGraphics
import Foundation
import ImageIO

/// Makes an image small enough to send: a file of at most `limit` bytes,
/// at the best quality that fits. It lowers the quality first, but not below
/// a floor that still looks right, and only then the pixel size, down to a
/// smallest size that's still useful. When even that doesn't fit, it saves
/// nothing and says so, rather than saving a result too poor to use.
///
/// Lossy images keep their format. Others become JPEG, or PNG when they're
/// transparent (then only the pixel size can shrink).
public struct FitImageConverter: Converter {
    /// Largest result, in bytes. Megabytes are Finder's: 1 MB = 1,000,000 bytes.
    public let limit: Int

    public init(bytes: Int) {
        limit = bytes
    }

    public init(megabytes: Int) {
        self.init(bytes: megabytes * 1_000_000)
    }

    public static let presets: [FitImageConverter] = [1, 5, 8, 25].map { FitImageConverter(megabytes: $0) }

    /// Lowest lossy quality tried, before the pixel size goes down.
    static let qualityFloor = 0.5
    /// Longest side below which the result is too small to be worth saving.
    static let smallestSide = 640

    public var id: String {
        limit % 1_000_000 == 0 ? "image.fit.\(limit / 1_000_000)mb" : "image.fit.\(limit)b"
    }

    public var title: String { Self.size(limit) }

    public var role: ConverterRole { .tool }
    public var menuGroup: String? { "Fit to Size" }
    public var isAvailable: Bool { true }

    /// "1 MB", "500 KB", in Finder's decimal units.
    static func size(_ bytes: Int) -> String {
        if bytes % 1_000_000 == 0 { return "\(bytes / 1_000_000) MB" }
        if bytes % 1_000 == 0 { return "\(bytes / 1_000) KB" }
        return "\(bytes) bytes"
    }

    /// The format the result is saved in.
    static func outputFormat(for info: ImageInfo) -> ImageFormat {
        if let same = ImageFormat.existing(for: info.typeIdentifier), same.isLossy { return same }
        return info.hasAlpha ? .png : .jpeg
    }

    static func fileSize(_ url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    /// Offered for still images larger than the limit.
    public func accepts(_ input: InputFile) -> Bool {
        guard let info = input.image, !info.isAnimated, let size = Self.fileSize(input.url) else { return false }
        return size > limit
    }

    public func output(for input: InputFile) -> OutputSpec {
        let format = input.image.map(Self.outputFormat) ?? .jpeg
        return OutputSpec(fileExtension: format.fileExtension, nameSuffix: " (under \(title))")
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let info = input.image, let original = Self.fileSize(input.url) else {
            throw ConversionError.unreadableInput(input.url)
        }
        let name = input.url.lastPathComponent
        guard original > limit else {
            throw ConversionError.nothingToDo("\(name) is already under \(title).")
        }
        let format = Self.outputFormat(for: info)
        let source = try ImageCodec.openSource(input)
        var image = try ImageCodec.decode(source, index: info.primaryIndex)
        if !format.supportsAlpha { image = try ImageCodec.flattenedOnWhite(image) }
        let metadata: [CFString: Any] = options.keepMetadata && format.carriesMetadata
            ? ImageCodec.carriedMetadata(ImageCodec.properties(source, info.primaryIndex))
            : [kCGImagePropertyOrientation: 1]
        let encoder = Encoder(format: format, metadata: metadata, limit: limit,
                              ceiling: max(options.imageQuality, Self.qualityFloor))

        // Full size first, then smaller, each at the best quality that fits.
        var attempt = try encoder.best(image)
        var current = image
        var tries = 1
        while attempt.fitting == nil {
            try Task.checkCancellation()
            // File size grows roughly with the pixel count; aim a little under.
            let ratio = (Double(limit) / Double(attempt.smallest)).squareRoot() * 0.95
            let scale = min(max(ratio, 0.5), 0.9)
            let size = PixelSize(width: max(1, Int((Double(current.width) * scale).rounded())),
                                 height: max(1, Int((Double(current.height) * scale).rounded())))
            guard max(size.width, size.height) >= min(Self.smallestSide, max(image.width, image.height)) else {
                throw ConversionError.nothingToDo(
                    "Couldn't fit \(name) under \(title) without making it too small or too blurry to use.")
            }
            current = try ImageCodec.scaled(image, to: size)
            attempt = try encoder.best(current)
            tries += 1
            progress(min(0.9, Double(tries) / 8))
        }

        guard let data = attempt.fitting, data.count <= limit, data.count < original,
              let written = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(written) > 0, CGImageSourceCreateImageAtIndex(written, 0, nil) != nil
        else {
            throw ConversionError.encoderFailed("this Mac couldn't make a readable \(format.title) of this image")
        }
        try Task.checkCancellation()
        try data.write(to: destination)
        progress(1)
    }

    /// Encodes one image in memory at several qualities.
    struct Encoder {
        let format: ImageFormat
        let metadata: [CFString: Any]
        let limit: Int
        /// Highest lossy quality tried: the user's image quality setting.
        let ceiling: Double

        /// The best encoding of `image` that fits, and the smallest size
        /// reached, which says how much further there is to go.
        func best(_ image: CGImage) throws -> (fitting: Data?, smallest: Int) {
            let top = try encode(image, quality: ceiling)
            guard format.isLossy, top.count > limit else {
                return (top.count <= limit ? top : nil, top.count)
            }
            let bottom = try encode(image, quality: FitImageConverter.qualityFloor)
            guard bottom.count <= limit else { return (nil, bottom.count) }
            // The highest quality between the two that still fits.
            var fitting = bottom
            var low = FitImageConverter.qualityFloor, high = ceiling
            for _ in 0..<5 {
                try Task.checkCancellation()
                let middle = (low + high) / 2
                let data = try encode(image, quality: middle)
                if data.count <= limit {
                    fitting = data
                    low = middle
                } else {
                    high = middle
                }
            }
            return (fitting, bottom.count)
        }

        func encode(_ image: CGImage, quality: Double) throws -> Data {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, format.typeIdentifier as CFString, 1, nil) else {
                throw ConversionError.encoderFailed("this Mac can't write \(format.title)")
            }
            var properties = metadata
            if format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = quality }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ConversionError.encoderFailed("ImageIO couldn't write \(format.title)")
            }
            return data as Data
        }
    }
}
