import Foundation

/// Every image converter, in menu order: formats first, then tools.
public enum ImageConverters {
    // Typed in pieces: as one `+` chain of mixed literals, Xcode 26's type
    // checker (Swift 6.3) gives up on it.
    public static let all: [any Converter] = {
        let formats: [any Converter] = ImageFormat.all.map { ImageFormatConverter(format: $0) }
        let animations: [any Converter] = [AnimatedImageToVideoConverter(.mp4), AnimatedImageToVideoConverter(.mov)]
        let resizes: [any Converter] = ResizeImageConverter.presets
        let crops: [any Converter] = CropImageConverter.presets
        let turns: [any Converter] = RotateImageConverter.presets
        let fits: [any Converter] = FitImageConverter.presets
        let tools: [any Converter] = [CompressImageConverter(), RemoveBackgroundConverter(), StripImageMetadataConverter(),
                                      CombineImagesToPDFConverter()]
        let edits: [any Converter] = resizes + crops + turns + fits
        return formats + animations + edits + tools
    }()
}
