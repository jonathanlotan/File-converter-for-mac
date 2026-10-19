import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// Keeps the subject of a picture (people, pets, objects) and makes the
/// rest transparent, with Vision's on-device foreground mask. The same mask
/// as "Remove Background" in Finder; it needs macOS 14 or later. The result
/// is a PNG, upright, with metadata kept when the settings say so.
public struct RemoveBackgroundConverter: Converter {
    public init() {}

    public var id: String { "image.removeBackground" }
    public var title: String { "Remove Background" }
    public var role: ConverterRole { .tool }

    public var isAvailable: Bool {
        if #available(macOS 14, *) { return true }
        return false
    }

    /// Below this, there's too little to find a subject in.
    static let minimumSide = 64

    public func accepts(_ input: InputFile) -> Bool {
        guard let info = input.image, !info.isAnimated else { return false }
        return min(info.width, info.height) >= Self.minimumSide
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: ImageFormat.png.fileExtension, nameSuffix: " (no background)")
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard #available(macOS 14, *) else {
            throw ConversionError.unsupported("Remove Background needs macOS 14 or later.")
        }
        guard let info = input.image else { throw ConversionError.unreadableInput(input.url) }
        let source = try ImageCodec.openSource(input)
        let name = input.url.lastPathComponent
        var request = ImageCodec.EncodeRequest(
            format: .png, frames: [info.primaryIndex], maxPixelSize: nil,
            quality: options.imageQuality, keepMetadata: options.keepMetadata)
        request.transform = { image in try Self.subject(of: image, name: name) }
        try ImageCodec.encode(source, request, to: destination, progress: progress)
    }

    /// `image` with everything but its subjects made transparent.
    @available(macOS 14, *)
    static func subject(of image: CGImage, name: String) throws -> CGImage {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let buffer: CVPixelBuffer
        do {
            try handler.perform([request])
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                throw ConversionError.nothingToDo("Couldn't find a subject to keep in \(name).")
            }
            buffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances, from: handler, croppedToInstancesExtent: false)
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.encoderFailed("couldn't find the subject: \(error.localizedDescription)")
        }
        return try makeImage(buffer, colorSpace: image.colorSpace)
    }

    /// The masked picture as a `CGImage`. Vision returns premultiplied BGRA
    /// with the source's own colour values (probed: Display P3 stays P3), so
    /// it's tagged with the source's colour space rather than converted.
    static func makeImage(_ buffer: CVPixelBuffer, colorSpace: CGColorSpace?) throws -> CGImage {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            throw ConversionError.encoderFailed("Vision returned an unexpected pixel format")
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw ConversionError.encoderFailed("couldn't read the masked image")
        }
        // Copied, so the image outlives the buffer.
        let data = Data(bytes: base, count: bytesPerRow * height) as CFData
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? ImageCodec.sRGB
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                  space: space, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                                  shouldInterpolate: true, intent: .defaultIntent)
        else { throw ConversionError.encoderFailed("couldn't read the masked image") }
        return image
    }
}
