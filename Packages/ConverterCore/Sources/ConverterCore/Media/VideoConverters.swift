import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import os

/// A video format written with an AVAssetExportSession preset.
public struct VideoFormat: Sendable, Hashable {
    public let id: String
    public let title: String
    let preset: String
    let fileTypeRaw: String
    public let fileExtension: String
    public let isSecondary: Bool

    var fileType: AVFileType { AVFileType(rawValue: fileTypeRaw) }

    public static let mp4 = VideoFormat(id: "mp4", title: "MP4", preset: AVAssetExportPresetHighestQuality,
                                        fileTypeRaw: AVFileType.mp4.rawValue, fileExtension: "mp4", isSecondary: false)
    public static let mp4HEVC = VideoFormat(id: "mp4-hevc", title: "MP4 (HEVC)", preset: AVAssetExportPresetHEVCHighestQuality,
                                            fileTypeRaw: AVFileType.mp4.rawValue, fileExtension: "mp4", isSecondary: false)
    public static let mov = VideoFormat(id: "mov", title: "MOV", preset: AVAssetExportPresetHighestQuality,
                                        fileTypeRaw: AVFileType.mov.rawValue, fileExtension: "mov", isSecondary: false)
    public static let proRes = VideoFormat(id: "mov-prores", title: "MOV (ProRes)", preset: AVAssetExportPresetAppleProRes422LPCM,
                                           fileTypeRaw: AVFileType.mov.rawValue, fileExtension: "mov", isSecondary: true)
    public static let m4v = VideoFormat(id: "m4v", title: "M4V", preset: AVAssetExportPresetHighestQuality,
                                        fileTypeRaw: AVFileType.m4v.rawValue, fileExtension: "m4v", isSecondary: true)

    public static let all: [VideoFormat] = [mp4, mp4HEVC, mov, proRes, m4v]

    var isAvailable: Bool { AVAssetExportSession.allExportPresets().contains(preset) }
}

/// Video → another container or codec, re-encoded with VideoToolbox through
/// AVAssetExportSession (hardware H.264, HEVC and ProRes on Apple silicon).
public struct VideoConverter: Converter {
    public let format: VideoFormat

    public init(_ format: VideoFormat) {
        self.format = format
    }

    public var id: String { "video.\(format.id)" }
    public var title: String { format.title }
    public var role: ConverterRole { .format }
    public var isSecondary: Bool { format.isSecondary }
    public var isAvailable: Bool { format.isAvailable }

    public func accepts(_ input: InputFile) -> Bool {
        MediaTypes.isMovie(input)
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: format.fileExtension)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        let asset = AVURLAsset(url: input.url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw ConversionError.unsupported("\(input.url.lastPathComponent) has no picture.")
        }
        guard await AVAssetExportSession.compatibility(ofExportPreset: format.preset, with: asset,
                                                       outputFileType: format.fileType) else {
            throw ConversionError.unsupported("This Mac can't save \(input.url.lastPathComponent) as \(format.title).")
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: format.preset) else {
            throw ConversionError.encoderFailed("couldn't set up \(format.title) export")
        }
        session.outputURL = destination
        session.outputFileType = format.fileType
        session.shouldOptimizeForNetworkUse = true
        try await ExportSessionRunner(session).run(progress: progress)
    }
}

/// Runs an export session from the calling task: reports progress every
/// 0.1 s and cancels the export when the task is cancelled.
struct ExportSessionRunner: @unchecked Sendable {
    private let session: AVAssetExportSession
    private let finished = OSAllocatedUnfairLock(initialState: false)

    init(_ session: AVAssetExportSession) {
        self.session = session
    }

    func run(progress: ProgressHandler) async throws {
        let finished = finished
        session.exportAsynchronously { finished.withLock { $0 = true } }
        while !finished.withLock({ $0 }) {
            if Task.isCancelled { session.cancelExport() }
            progress(Double(session.progress) * 0.99)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        switch session.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        default:
            throw ConversionError.encoderFailed(session.error?.localizedDescription ?? "export stopped")
        }
    }
}

// MARK: - Video → GIF

/// Video → animated GIF at a modest frame rate and size.
public struct VideoToGIFConverter: Converter {
    public init() {}

    public var id: String { "video.gif" }
    public var title: String { "GIF" }
    public var role: ConverterRole { .format }
    public var isAvailable: Bool { ImageCodec.writableTypes.contains("com.compuserve.gif") }

    public func accepts(_ input: InputFile) -> Bool {
        MediaTypes.isMovie(input)
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: "gif")
    }

    /// Frame times for a clip of `duration` seconds at `fps`.
    static func frameCount(duration: Double, fps: Double) -> Int {
        max(1, Int((duration * fps).rounded(.down)))
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        let asset = AVURLAsset(url: input.url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw ConversionError.unsupported("\(input.url.lastPathComponent) has no picture.")
        }
        let duration = try await asset.load(.duration).seconds
        let fps = max(1, options.gifFrameRate)
        let count = Self.frameCount(duration: duration, fps: fps)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: options.gifMaxSide, height: options.gifMaxSide)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let gif = CGImageDestinationCreateWithURL(destination as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            throw ConversionError.encoderFailed("couldn't create the GIF")
        }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let delay = 1 / fps
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                                               kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        for index in 0..<count {
            try Task.checkCancellation()
            let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
            let frame = try await generator.image(at: time).image
            CGImageDestinationAddImage(gif, frame, frameProperties)
            progress(Double(index + 1) / Double(count) * 0.95)
        }
        guard CGImageDestinationFinalize(gif) else { throw ConversionError.encoderFailed("couldn't write the GIF") }
    }
}

// MARK: - Save a frame

/// Saves one frame of a video as a PNG: one second in, or the middle of
/// clips shorter than two seconds (the very first frame is often black).
public struct VideoFrameConverter: Converter {
    public init() {}

    public var id: String { "video.frame" }
    public var title: String { "Save Frame" }
    public var role: ConverterRole { .tool }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        MediaTypes.isMovie(input)
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: "png", nameSuffix: " (frame)")
    }

    static func frameTime(duration: Double) -> Double {
        min(1, duration / 2)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        let asset = AVURLAsset(url: input.url)
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw ConversionError.unsupported("\(input.url.lastPathComponent) has no picture.")
        }
        let duration = try await asset.load(.duration).seconds
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: Self.frameTime(duration: duration), preferredTimescale: 600)).image
        guard let png = CGImageDestinationCreateWithURL(destination as CFURL, "public.png" as CFString, 1, nil) else {
            throw ConversionError.encoderFailed("couldn't create the PNG")
        }
        CGImageDestinationAddImage(png, frame, nil)
        guard CGImageDestinationFinalize(png) else { throw ConversionError.encoderFailed("couldn't write the PNG") }
    }
}

/// Every video and audio converter, in menu order.
public enum MediaConverters {
    public static let all: [any Converter] =
        VideoFormat.all.map { VideoConverter($0) as any Converter }
        + [VideoToGIFConverter() as any Converter]
        + [AudioFormat.m4a, .wav, .aiff, .flac].map { AudioConverter($0, from: .video) as any Converter }
        + [VideoFrameConverter() as any Converter, CompressVideoConverter() as any Converter]
        + ResizeVideoConverter.presets.map { $0 as any Converter }
        + [RemoveAudioConverter() as any Converter, RemoveVideoMetadataConverter() as any Converter]
        + AudioFormat.all.map { AudioConverter($0, from: .audio) as any Converter }
        + [CompressAudioConverter() as any Converter]
}
