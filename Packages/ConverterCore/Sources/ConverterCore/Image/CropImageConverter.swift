import CoreGraphics
import Foundation

/// A size in pixels.
public struct PixelSize: Sendable, Hashable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A rectangle of an image in upright pixels (as displayed, after EXIF
/// orientation), measured from the top-left corner.
public struct CropRegion: Sendable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// The region shrunk and moved as needed to lie inside an image of `size`.
    public func clamped(to size: PixelSize) -> CropRegion {
        let width = min(max(self.width, 1), size.width)
        let height = min(max(self.height, 1), size.height)
        return CropRegion(x: min(max(x, 0), size.width - width), y: min(max(y, 0), size.height - height),
                          width: width, height: height)
    }

    /// The largest region with a `ratioWidth`:`ratioHeight` shape, centred in
    /// an image of `size`.
    public static func centred(ratioWidth: Int, ratioHeight: Int, in size: PixelSize) -> CropRegion {
        let ratio = Double(ratioWidth) / Double(max(ratioHeight, 1))
        if Double(size.width) / Double(max(size.height, 1)) > ratio {
            let width = min(size.width, max(1, Int((Double(size.height) * ratio).rounded())))
            return CropRegion(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
        let height = min(size.height, max(1, Int((Double(size.width) / ratio).rounded())))
        return CropRegion(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
    }
}

/// Crops an image: to an aspect ratio, centred (the presets), or to a region
/// chosen in the crop editor, optionally scaled to exact pixel dimensions.
/// Every frame of an animation is cropped the same way; metadata is kept
/// when the settings say so.
public struct CropImageConverter: Converter {
    public enum Mode: Sendable, Hashable {
        /// The largest centred part with this width:height shape.
        case aspect(width: Int, height: Int)
        /// This part of the image; `size` scales the result to exactly that.
        case region(CropRegion, size: PixelSize?)
    }

    public let mode: Mode

    public init(_ mode: Mode) {
        self.mode = mode
    }

    public static let presets: [CropImageConverter] = [
        .init(.aspect(width: 1, height: 1)), .init(.aspect(width: 4, height: 3)), .init(.aspect(width: 3, height: 2)),
        .init(.aspect(width: 16, height: 9)), .init(.aspect(width: 3, height: 4)), .init(.aspect(width: 2, height: 3)),
        .init(.aspect(width: 9, height: 16)),
    ]

    public var id: String {
        switch mode {
        case .aspect(let w, let h): return "image.crop.\(w)x\(h)"
        case .region: return "image.crop.region"
        }
    }

    public var title: String {
        switch mode {
        case .aspect(1, 1): return "Square"
        case .aspect(let w, let h): return "\(w):\(h)"
        case .region(_, let size?): return "\(size.width) × \(size.height)"
        case .region: return "Crop"
        }
    }

    public var role: ConverterRole { .tool }
    public var menuGroup: String? { "Crop" }
    public var isAvailable: Bool { true }

    /// The part of an image this crop keeps.
    public func region(for info: ImageInfo) -> CropRegion {
        let size = PixelSize(width: info.width, height: info.height)
        switch mode {
        case .aspect(let w, let h): return .centred(ratioWidth: w, ratioHeight: h, in: size)
        case .region(let region, _): return region.clamped(to: size)
        }
    }

    public func accepts(_ input: InputFile) -> Bool {
        guard let info = input.image else { return false }
        switch mode {
        case .aspect:
            // Not offered when the image already has that shape.
            let region = region(for: info)
            return region.width < info.width || region.height < info.height
        case .region:
            return true
        }
    }

    public func output(for input: InputFile) -> OutputSpec {
        let format = input.image.map(toolOutputFormat) ?? .jpeg
        let suffix: String
        switch mode {
        case .aspect(1, 1): suffix = " (square)"
        case .aspect(let w, let h): suffix = " (\(w)x\(h))"
        case .region(_, let size?): suffix = " (\(size.width)x\(size.height))"
        case .region: suffix = " (cropped)"
        }
        return OutputSpec(fileExtension: format.fileExtension, nameSuffix: suffix)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let info = input.image else { throw ConversionError.unreadableInput(input.url) }
        let region = region(for: info)
        let reference = PixelSize(width: info.width, height: info.height)
        var size: PixelSize?
        if case .region(_, let target?) = mode { size = target }
        let format = toolOutputFormat(for: info)
        let source = try ImageCodec.openSource(input)
        var request = ImageCodec.EncodeRequest(
            format: format,
            frames: ImageFormatConverter.frames(of: info, for: format),
            maxPixelSize: nil,
            quality: options.imageQuality,
            keepMetadata: options.keepMetadata)
        request.transform = { image in
            try ImageCodec.crop(image, to: region, reference: reference, scaledTo: size)
        }
        try ImageCodec.encode(source, request, to: destination, progress: progress)
    }
}
