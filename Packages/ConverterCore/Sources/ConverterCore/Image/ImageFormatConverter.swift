import Foundation
import ImageIO

/// Any readable image → one image format (JPEG, PNG, HEIC, ...).
public struct ImageFormatConverter: Converter {
    public let format: ImageFormat

    public init(format: ImageFormat) {
        self.format = format
    }

    public var id: String { "image.\(format.id)" }
    public var title: String { format.title }
    public var role: ConverterRole { .format }
    public var isSecondary: Bool { format.isSecondary }
    public var isAvailable: Bool { format.isWritable }

    public func accepts(_ input: InputFile) -> Bool {
        guard let image = input.image else { return false }
        return !format.matches(image.typeIdentifier)
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: format.fileExtension)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let info = input.image else { throw ConversionError.unreadableInput(input.url) }
        let source = try ImageCodec.openSource(input)
        let request = ImageCodec.EncodeRequest(
            format: format,
            frames: Self.frames(of: info, for: format),
            maxPixelSize: nil,
            quality: options.imageQuality,
            keepMetadata: options.keepMetadata)
        try ImageCodec.encode(source, request, to: destination, progress: progress)
    }

    /// Which frames of the source go into the output: every frame when both
    /// sides animate, every page for multi-page TIFF → TIFF/PDF, otherwise
    /// the representative frame.
    static func frames(of info: ImageInfo, for format: ImageFormat) -> [Int] {
        if info.isAnimated && format.supportsAnimation {
            return Array(0..<info.frameCount)
        }
        if info.typeIdentifier == ImageFormat.tiff.typeIdentifier && info.frameCount > 1 && format.supportsMultiplePages {
            return Array(0..<info.frameCount)
        }
        return [info.primaryIndex]
    }
}
