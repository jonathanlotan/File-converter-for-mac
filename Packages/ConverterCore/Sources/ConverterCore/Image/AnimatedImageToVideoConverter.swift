import AVFoundation
import CoreVideo
import Foundation
import ImageIO

/// Animated GIF / APNG / WebP → H.264 video (MP4 or MOV). Each frame lasts
/// as long as its delay in the source. Transparent areas become white.
public struct AnimatedImageToVideoConverter: Converter {
    public enum Container: String, Sendable {
        case mp4, mov
    }

    public let container: Container

    public init(_ container: Container) {
        self.container = container
    }

    public var id: String { "image.video.\(container.rawValue)" }
    public var title: String { container == .mp4 ? "MP4" : "MOV" }
    public var role: ConverterRole { .format }
    public var isSecondary: Bool { container == .mov }
    public var isAvailable: Bool { true }

    private var fileType: AVFileType { container == .mp4 ? .mp4 : .mov }

    public func accepts(_ input: InputFile) -> Bool {
        input.image?.isAnimated == true
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: container.rawValue)
    }

    /// H.264 needs even dimensions.
    static func videoSize(for info: ImageInfo) -> (width: Int, height: Int) {
        (max(2, info.width & ~1), max(2, info.height & ~1))
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let info = input.image, info.isAnimated else { throw ConversionError.unreadableInput(input.url) }
        let source = try ImageCodec.openSource(input)
        let (width, height) = Self.videoSize(for: info)

        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(videoInput) else { throw ConversionError.encoderFailed("can't add a video track") }
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw ConversionError.encoderFailed(writer.error?.localizedDescription ?? "couldn't start writing")
        }
        writer.startSession(atSourceTime: .zero)

        // Time in 1/600 s, accumulated as an integer so it doesn't drift.
        var ticks: Int64 = 0
        do {
            for index in 0..<info.frameCount {
                try Task.checkCancellation()
                let frame = try ImageCodec.decode(source, index: index)
                let delay = ImageCodec.frameDelay(ImageCodec.properties(source, index))
                while !videoInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                let buffer = try Self.pixelBuffer(from: adaptor, drawing: frame, width: width, height: height)
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: ticks, timescale: 600)) else {
                    throw ConversionError.encoderFailed(writer.error?.localizedDescription ?? "couldn't add frame \(index + 1)")
                }
                ticks += max(1, Int64((delay * 600).rounded()))
                progress(Double(index + 1) / Double(info.frameCount) * 0.95)
            }
        } catch {
            writer.cancelWriting()
            throw error
        }

        videoInput.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: ticks, timescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ConversionError.encoderFailed(writer.error?.localizedDescription ?? "video writer stopped")
        }
    }

    private static func pixelBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor, drawing image: CGImage,
                                    width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        guard let buffer else { throw ConversionError.encoderFailed("couldn't allocate a video frame") }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: ImageCodec.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw ConversionError.encoderFailed("couldn't draw a video frame") }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return buffer
    }
}
