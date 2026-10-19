import Foundation

/// Every image converter, in menu order: formats first, then tools.
public enum ImageConverters {
    // Typed in pieces: as one `+` chain of mixed literals, Swift 6.2's type
    // checker (Xcode 26) gives up on it.
    public static let all: [any Converter] = {
        let formats: [any Converter] = ImageFormat.all.map { ImageFormatConverter(format: $0) }
        let animations: [any Converter] = [AnimatedImageToVideoConverter(.mp4), AnimatedImageToVideoConverter(.mov)]
        let resizes: [any Converter] = ResizeImageConverter.presets
        let crops: [any Converter] = CropImageConverter.presets
        let tools: [any Converter] = [CompressImageConverter(), StripImageMetadataConverter(), CombineImagesToPDFConverter()]
        return formats + animations + resizes + crops + tools
    }()
}
