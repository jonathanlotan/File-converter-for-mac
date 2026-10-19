import AudioToolbox
import AVFoundation
import Foundation

// MARK: - Compress

/// Re-encodes a video as HEVC at a bit rate chosen from its size and frame
/// rate (see `ConversionOptions.videoCompression`), with AAC sound. Keeps
/// the orientation. Gives up rather than saving a file that isn't smaller.
public struct CompressVideoConverter: Converter {
    public init() {}

    public var id: String { "video.compress" }
    public var title: String { "Compress" }
    public var role: ConverterRole { .tool }
    public var isAvailable: Bool { AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetHEVCHighestQuality) }

    public func accepts(_ input: InputFile) -> Bool {
        MediaTypes.isMovie(input)
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: "mp4", nameSuffix: " (compressed)")
    }

    /// Average bit rate for HEVC at this size and frame rate.
    static func bitRate(width: Int, height: Int, fps: Double, level: ConversionOptions.VideoCompression) -> Int {
        let raw = Double(width * height) * max(fps, 1) * level.bitsPerPixel
        return Int(min(40_000_000, max(250_000, raw)))
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        let asset = AVURLAsset(url: input.url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.unsupported("\(input.url.lastPathComponent) has no picture.")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let (size, transform, nominalRate) = try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = max(try await asset.load(.duration).seconds, 0.001)
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        let fps = nominalRate > 0 ? Double(nominalRate) : 30

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        var stereo = AudioChannelLayout()
        stereo.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let stereoData = Data(bytes: &stereo, count: MemoryLayout<AudioChannelLayout>.size)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVChannelLayoutKey: stereoData,
            ])
            reader.add(output)
            audioOutput = output
        }

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Self.bitRate(width: width, height: height, fps: fps, level: options.videoCompression),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ])
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48_000,
                AVEncoderBitRateKey: 128_000, AVChannelLayoutKey: stereoData,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else {
            throw ConversionError.encoderFailed(reader.error?.localizedDescription ?? "can't read this video")
        }
        guard writer.startWriting() else {
            throw ConversionError.encoderFailed(writer.error?.localizedDescription ?? "can't write HEVC")
        }
        writer.startSession(atSourceTime: .zero)

        // One loop feeds both tracks, whichever the writer is ready for, so
        // neither starves the other.
        var videoDone = false
        var audioDone = audioInput == nil
        do {
            while !(videoDone && audioDone) {
                try Task.checkCancellation()
                var moved = false
                if !videoDone && videoInput.isReadyForMoreMediaData {
                    if let sample = videoOutput.copyNextSampleBuffer() {
                        guard videoInput.append(sample) else { throw Self.failure(writer, reader) }
                        progress(min(0.99, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration))
                    } else {
                        videoInput.markAsFinished()
                        videoDone = true
                    }
                    moved = true
                }
                if !audioDone, let audioInput, let audioOutput, audioInput.isReadyForMoreMediaData {
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        guard audioInput.append(sample) else { throw Self.failure(writer, reader) }
                    } else {
                        audioInput.markAsFinished()
                        audioDone = true
                    }
                    moved = true
                }
                if !moved { try await Task.sleep(nanoseconds: 2_000_000) }
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        await writer.finishWriting()
        guard writer.status == .completed, reader.status == .completed else { throw Self.failure(writer, reader) }

        let before = (try? input.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if before > 0 && after >= before * 95 / 100 {
            throw ConversionError.nothingToDo("\(input.url.lastPathComponent) is already well compressed; the result wasn't smaller.")
        }
    }

    private static func failure(_ writer: AVAssetWriter, _ reader: AVAssetReader) -> ConversionError {
        .encoderFailed(writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "compression stopped")
    }
}

// MARK: - Resize

/// Scales a video down to fit 4K, 1080p, 720p or 540p (H.264 MP4). Never enlarges.
public struct ResizeVideoConverter: Converter {
    public let height: Int

    public init(height: Int) {
        self.height = height
    }

    public static let presets: [ResizeVideoConverter] = [2160, 1080, 720, 540].map(ResizeVideoConverter.init)

    private var preset: String {
        switch height {
        case 2160: return AVAssetExportPreset3840x2160
        case 1080: return AVAssetExportPreset1920x1080
        case 720: return AVAssetExportPreset1280x720
        default: return AVAssetExportPreset960x540
        }
    }

    public var id: String { "video.resize.\(height)" }
    public var title: String { height == 2160 ? "4K" : "\(height)p" }
    public var role: ConverterRole { .tool }
    public var menuGroup: String? { "Resize" }
    public var isAvailable: Bool { AVAssetExportSession.allExportPresets().contains(preset) }

    public func accepts(_ input: InputFile) -> Bool {
        MediaTypes.isMovie(input) && Self.shrinks(shortSide: MediaTypes.shortSide(ofMovieAt: input.url), to: height)
    }

    /// Whether to offer this size: only below the picture's short side, or
    /// every size while that isn't known (`convert` checks again).
    static func shrinks(shortSide: Int?, to height: Int) -> Bool {
        shortSide.map { $0 > height } ?? true
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: "mp4", nameSuffix: " (\(title))")
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        let asset = AVURLAsset(url: input.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.unsupported("\(input.url.lastPathComponent) has no picture.")
        }
        // The frame's short side as displayed (portrait clips are rotated).
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = size.applying(transform)
        guard min(abs(shown.width), abs(shown.height)) > CGFloat(height) else {
            throw ConversionError.nothingToDo("\(input.url.lastPathComponent) is already \(title) or smaller.")
        }
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: .mp4),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.unsupported("This Mac can't resize \(input.url.lastPathComponent) to \(title).")
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        try await ExportSessionRunner(session).run(progress: progress)
    }
}

// MARK: - Remove audio

/// Copies a video without its sound. The picture isn't re-encoded.
public struct RemoveAudioConverter: Converter {
    public init() {}

    public var id: String { "video.removeAudio" }
    public var title: String { "Remove Audio" }
    public var role: ConverterRole { .tool }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        MediaTypes.isMovie(input)
    }

    /// Same container when it's one passthrough can write, otherwise MOV.
    private func container(for input: InputFile) -> (fileExtension: String, type: AVFileType) {
        switch input.url.pathExtension.lowercased() {
        case "mp4": return ("mp4", .mp4)
        case "m4v": return ("m4v", .m4v)
        default: return ("mov", .mov)
        }
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: container(for: input).fileExtension, nameSuffix: " (no audio)")
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        let asset = AVURLAsset(url: input.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ConversionError.unsupported("\(input.url.lastPathComponent) has no picture.") }
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw ConversionError.nothingToDo("\(input.url.lastPathComponent) has no sound to remove.")
        }
        let range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        let composition = AVMutableComposition()
        for track in videoTracks {
            guard let copy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try copy.insertTimeRange(range, of: track, at: .zero)
            copy.preferredTransform = try await track.load(.preferredTransform)
        }
        let type = container(for: input).type
        guard await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: composition, outputFileType: type),
              let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ConversionError.unsupported("This video's picture can't be copied into \(type == .mov ? "MOV" : "MP4").")
        }
        session.outputURL = destination
        session.outputFileType = type
        try await ExportSessionRunner(session).run(progress: progress)
    }
}
