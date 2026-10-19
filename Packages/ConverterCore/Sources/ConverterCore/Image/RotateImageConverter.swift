import CoreGraphics
import Foundation

/// Turns an image a quarter or half turn, or mirrors it. The pixels are
/// turned and the result is saved upright (orientation 1), so it shows the
/// same way in every app. Every frame of an animation and every page of a
/// TIFF is turned the same way; metadata is kept when the settings say so.
public struct RotateImageConverter: Converter {
    public enum Turn: Sendable, Hashable, CaseIterable {
        /// 90° anticlockwise.
        case left
        /// 90° clockwise.
        case right
        case halfTurn
        /// Mirrored left to right.
        case flipHorizontal
        /// Mirrored top to bottom.
        case flipVertical

        /// A quarter turn swaps the width and height.
        var isQuarterTurn: Bool { self == .left || self == .right }
    }

    public let turn: Turn

    public init(_ turn: Turn) {
        self.turn = turn
    }

    public static let presets: [RotateImageConverter] = Turn.allCases.map { RotateImageConverter($0) }

    public var id: String {
        switch turn {
        case .left: return "image.rotate.left"
        case .right: return "image.rotate.right"
        case .halfTurn: return "image.rotate.180"
        case .flipHorizontal: return "image.flip.horizontal"
        case .flipVertical: return "image.flip.vertical"
        }
    }

    public var title: String {
        switch turn {
        case .left: return "Left"
        case .right: return "Right"
        case .halfTurn: return "180°"
        case .flipHorizontal: return "Flip Horizontal"
        case .flipVertical: return "Flip Vertical"
        }
    }

    public var role: ConverterRole { .tool }
    public var menuGroup: String? { "Rotate" }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        input.image != nil
    }

    public func output(for input: InputFile) -> OutputSpec {
        let format = input.image.map(toolOutputFormat) ?? .jpeg
        let suffix: String
        switch turn {
        case .left: suffix = " (rotated left)"
        case .right: suffix = " (rotated right)"
        case .halfTurn: suffix = " (rotated 180°)"
        case .flipHorizontal: suffix = " (flipped horizontally)"
        case .flipVertical: suffix = " (flipped vertically)"
        }
        return OutputSpec(fileExtension: format.fileExtension, nameSuffix: suffix)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let info = input.image else { throw ConversionError.unreadableInput(input.url) }
        let format = toolOutputFormat(for: info)
        let source = try ImageCodec.openSource(input)
        let turn = self.turn
        var request = ImageCodec.EncodeRequest(
            format: format,
            frames: ImageFormatConverter.frames(of: info, for: format),
            maxPixelSize: nil,
            quality: options.imageQuality,
            keepMetadata: options.keepMetadata)
        request.transform = { image in try ImageCodec.turned(image, turn) }
        try ImageCodec.encode(source, request, to: destination, progress: progress)
    }
}

extension ImageCodec {
    /// The image turned or mirrored. Each pixel moves to exactly one new
    /// place, so nothing is resampled.
    static func turned(_ image: CGImage, _ turn: RotateImageConverter.Turn) throws -> CGImage {
        let w = image.width, h = image.height
        let size = turn.isQuarterTurn ? PixelSize(width: h, height: w) : PixelSize(width: w, height: h)
        let info = (hasAlpha(image) ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: space, bitmapInfo: info)
        }
        let own = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        guard let context = own.flatMap(makeContext) ?? makeContext(sRGB)
        else { throw ConversionError.encoderFailed("couldn't allocate image buffer") }

        // Core Graphics measures y upwards. Each transform maps the image's
        // own rectangle onto the new canvas; exact values rather than
        // rotate(by:) so no pixel lands between two others.
        let fw = CGFloat(w), fh = CGFloat(h)
        let transform: CGAffineTransform
        switch turn {
        case .right: transform = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: fw)
        case .left: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: fh, ty: 0)
        case .halfTurn: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: fw, ty: fh)
        case .flipHorizontal: transform = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: fw, ty: 0)
        case .flipVertical: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: fh)
        }
        context.interpolationQuality = .none
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = context.makeImage() else { throw ConversionError.encoderFailed("couldn't turn the image") }
        return result
    }
}
