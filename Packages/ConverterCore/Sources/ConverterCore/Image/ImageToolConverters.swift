import Foundation
import ImageIO

/// The format an image tool writes: the input's own format when this Mac can
/// encode it, otherwise PNG (if transparent) or JPEG.
private func toolOutputFormat(for info: ImageInfo) -> ImageFormat {
    if let same = ImageFormat.existing(for: info.typeIdentifier) { return same }
    return info.hasAlpha ? .png : .jpeg
}

// MARK: - Resize

/// Scales an image down by a percentage or to a longest side. Never enlarges.
public struct ResizeImageConverter: Converter {
    public enum Mode: Sendable, Hashable {
        case percent(Int)
        case longestSide(Int)
    }

    public let mode: Mode

    public init(_ mode: Mode) {
        self.mode = mode
    }

    public static let presets: [ResizeImageConverter] = [
        .init(.percent(50)), .init(.percent(25)),
        .init(.longestSide(3840)), .init(.longestSide(1920)), .init(.longestSide(1280)), .init(.longestSide(640)),
    ]

    public var id: String {
        switch mode {
        case .percent(let p): return "image.resize.\(p)pct"
        case .longestSide(let n): return "image.resize.\(n)"
        }
    }

    public var title: String {
        switch mode {
        case .percent(let p): return "\(p)%"
        case .longestSide(let n): return "\(n) px"
        }
    }

    public var role: ConverterRole { .tool }
    public var menuGroup: String? { "Resize" }
    public var isAvailable: Bool { true }

    /// Longest side of the result, or nil when the image is already small enough.
    func targetLongestSide(for info: ImageInfo) -> Int? {
        let longest = max(info.width, info.height)
        switch mode {
        case .percent(let p):
            let target = Int((Double(longest) * Double(p) / 100).rounded())
            return target >= 1 && target < longest ? target : nil
        case .longestSide(let n):
            return n < longest ? n : nil
        }
    }

    public func accepts(_ input: InputFile) -> Bool {
        guard let info = input.image else { return false }
        return targetLongestSide(for: info) != nil
    }

    public func output(for input: InputFile) -> OutputSpec {
        let format = input.image.map(toolOutputFormat) ?? .jpeg
        let suffix: String
        switch mode {
        case .percent(let p): suffix = " (\(p)%)"
        case .longestSide(let n): suffix = " (\(n)px)"
        }
        return OutputSpec(fileExtension: format.fileExtension, nameSuffix: suffix)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let info = input.image else { throw ConversionError.unreadableInput(input.url) }
        guard let target = targetLongestSide(for: info) else {
            throw ConversionError.nothingToDo("\(input.url.lastPathComponent) is already smaller than that.")
        }
        let format = toolOutputFormat(for: info)
        let source = try ImageCodec.openSource(input)
        let request = ImageCodec.EncodeRequest(
            format: format,
            frames: ImageFormatConverter.frames(of: info, for: format),
            maxPixelSize: target,
            quality: options.imageQuality,
            keepMetadata: options.keepMetadata)
        try ImageCodec.encode(source, request, to: destination, progress: progress)
    }
}

// MARK: - Compress

/// Re-encodes a lossy image (JPEG, HEIC, AVIF, JPEG 2000) at a lower quality.
public struct CompressImageConverter: Converter {
    public init() {}

    public var id: String { "image.compress" }
    public var title: String { "Compress" }
    public var role: ConverterRole { .tool }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        guard let info = input.image, !info.isAnimated,
              let format = ImageFormat.existing(for: info.typeIdentifier) else { return false }
        return format.isLossy
    }

    public func output(for input: InputFile) -> OutputSpec {
        let format = input.image.flatMap { ImageFormat.existing(for: $0.typeIdentifier) } ?? .jpeg
        return OutputSpec(fileExtension: format.fileExtension, nameSuffix: " (compressed)")
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let info = input.image, let format = ImageFormat.existing(for: info.typeIdentifier) else {
            throw ConversionError.unreadableInput(input.url)
        }
        let source = try ImageCodec.openSource(input)
        let request = ImageCodec.EncodeRequest(
            format: format, frames: [info.primaryIndex], maxPixelSize: nil,
            quality: options.compressionQuality, keepMetadata: options.keepMetadata)
        try ImageCodec.encode(source, request, to: destination, progress: progress)
    }
}

// MARK: - Strip metadata

/// Removes EXIF, GPS, IPTC and XMP metadata. Keeps the orientation so the
/// image still displays upright. JPEG, PNG, TIFF and PSD are rewritten
/// without re-encoding the pixels; other formats are re-encoded.
public struct StripImageMetadataConverter: Converter {
    public init() {}

    public var id: String { "image.stripMetadata" }
    public var title: String { "Remove Metadata" }
    public var role: ConverterRole { .tool }
    public var isAvailable: Bool { true }

    static let losslessTypes: Set<String> = ["public.jpeg", "public.png", "public.tiff", "com.adobe.photoshop-image"]

    public func accepts(_ input: InputFile) -> Bool {
        guard let info = input.image else { return false }
        return ImageFormat.existing(for: info.typeIdentifier) != nil
    }

    public func output(for input: InputFile) -> OutputSpec {
        let format = input.image.flatMap { ImageFormat.existing(for: $0.typeIdentifier) } ?? .jpeg
        return OutputSpec(fileExtension: format.fileExtension, nameSuffix: " (no metadata)")
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let info = input.image, let format = ImageFormat.existing(for: info.typeIdentifier) else {
            throw ConversionError.unreadableInput(input.url)
        }
        let source = try ImageCodec.openSource(input)

        if Self.losslessTypes.contains(info.typeIdentifier) && info.frameCount == 1 {
            guard let output = CGImageDestinationCreateWithURL(destination as CFURL, info.typeIdentifier as CFString, 1, nil) else {
                throw ConversionError.encoderFailed("this Mac can't write \(format.title)")
            }
            let metadata = CGImageMetadataCreateMutable()
            if info.orientation != 1 {
                CGImageMetadataSetValueMatchingImageProperty(
                    metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, info.orientation as CFNumber)
            }
            let copyOptions: [CFString: Any] = [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageMetadataShouldExcludeXMP: true,
            ]
            var error: Unmanaged<CFError>?
            // Writes the file itself; Finalize must not be called afterwards.
            guard CGImageDestinationCopyImageSource(output, source, copyOptions as CFDictionary, &error) else {
                let reason = error?.takeRetainedValue().localizedDescription ?? "unknown error"
                throw ConversionError.encoderFailed(reason)
            }
            return
        }

        let request = ImageCodec.EncodeRequest(
            format: format,
            frames: ImageFormatConverter.frames(of: info, for: format),
            maxPixelSize: nil,
            quality: options.imageQuality,
            keepMetadata: false)
        try ImageCodec.encode(source, request, to: destination, progress: progress)
    }
}
