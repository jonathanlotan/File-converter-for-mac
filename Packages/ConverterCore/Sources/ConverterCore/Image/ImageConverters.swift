import Foundation

/// Every image converter, in menu order: formats first, then tools.
public enum ImageConverters {
    public static let all: [any Converter] =
        ImageFormat.all.map { ImageFormatConverter(format: $0) as any Converter }
        + [AnimatedImageToVideoConverter(.mp4), AnimatedImageToVideoConverter(.mov)]
        + ResizeImageConverter.presets.map { $0 as any Converter }
        + CropImageConverter.presets.map { $0 as any Converter }
        + [CompressImageConverter(), StripImageMetadataConverter(), CombineImagesToPDFConverter()]
}
