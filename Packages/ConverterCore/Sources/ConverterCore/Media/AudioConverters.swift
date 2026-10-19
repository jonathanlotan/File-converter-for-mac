import AudioToolbox
import AVFoundation
import Foundation

/// An audio format Converter can write with AudioToolbox.
public struct AudioFormat: Sendable, Hashable {
    public let id: String
    public let title: String
    public let fileExtension: String
    let fileType: AudioFileTypeID
    let formatID: AudioFormatID
    /// Type of a file already in this format, for "same format" checks.
    let typeIdentifier: String
    public let isLossless: Bool
    public let isSecondary: Bool

    public static let m4a = AudioFormat(id: "m4a", title: "M4A", fileExtension: "m4a", fileType: kAudioFileM4AType,
                                        formatID: kAudioFormatMPEG4AAC, typeIdentifier: "com.apple.m4a-audio",
                                        isLossless: false, isSecondary: false)
    public static let alac = AudioFormat(id: "alac", title: "M4A Lossless", fileExtension: "m4a", fileType: kAudioFileM4AType,
                                         formatID: kAudioFormatAppleLossless, typeIdentifier: "com.apple.m4a-audio",
                                         isLossless: true, isSecondary: false)
    public static let wav = AudioFormat(id: "wav", title: "WAV", fileExtension: "wav", fileType: kAudioFileWAVEType,
                                        formatID: kAudioFormatLinearPCM, typeIdentifier: "com.microsoft.waveform-audio",
                                        isLossless: true, isSecondary: false)
    public static let aiff = AudioFormat(id: "aiff", title: "AIFF", fileExtension: "aiff", fileType: kAudioFileAIFFType,
                                         formatID: kAudioFormatLinearPCM, typeIdentifier: "public.aiff-audio",
                                         isLossless: true, isSecondary: false)
    public static let flac = AudioFormat(id: "flac", title: "FLAC", fileExtension: "flac", fileType: kAudioFileFLACType,
                                         formatID: kAudioFormatFLAC, typeIdentifier: "org.xiph.flac",
                                         isLossless: true, isSecondary: false)
    public static let aac = AudioFormat(id: "aac", title: "AAC", fileExtension: "aac", fileType: kAudioFileAAC_ADTSType,
                                        formatID: kAudioFormatMPEG4AAC, typeIdentifier: "public.aac-audio",
                                        isLossless: false, isSecondary: true)
    public static let caf = AudioFormat(id: "caf", title: "CAF", fileExtension: "caf", fileType: kAudioFileCAFType,
                                        formatID: kAudioFormatLinearPCM, typeIdentifier: "com.apple.coreaudio-format",
                                        isLossless: true, isSecondary: true)

    public static let all: [AudioFormat] = [m4a, alac, wav, aiff, flac, aac, caf]

    /// The encoder exists on this system.
    var isEncodable: Bool { AudioEncoders.available.contains(formatID) }

    /// File format description for `channels` at `sampleRate`, keeping up
    /// to 24 bits of the source's depth for lossless formats.
    func streamDescription(sampleRate: Double, channels: Int, sourceBits: Int) throws -> AudioStreamBasicDescription {
        let bits = UInt32(min(max(sourceBits, 16), 24))
        var format = AudioStreamBasicDescription()
        format.mFormatID = formatID
        format.mSampleRate = sampleRate
        format.mChannelsPerFrame = UInt32(channels)
        switch formatID {
        case kAudioFormatLinearPCM:
            format.mBitsPerChannel = bits
            format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                | (fileType == kAudioFileAIFFType ? kAudioFormatFlagIsBigEndian : 0)
            format.mBytesPerFrame = UInt32(channels) * bits / 8
            format.mBytesPerPacket = format.mBytesPerFrame
            format.mFramesPerPacket = 1
            return format
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            format.mFormatFlags = bits == 24 ? 3 : 1 // 24-bit or 16-bit source data
        default:
            break
        }
        // Let AudioToolbox fill in packet sizes for compressed formats.
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &size, &format)
        guard status == noErr else { throw ConversionError.encoderFailed("\(title) doesn't support this audio (\(status))") }
        return format
    }
}

enum AudioEncoders {
    /// Encoders this system has (checked once).
    static let available: Set<AudioFormatID> = {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        guard AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size, &ids) == noErr else { return [] }
        return Set(ids).union([kAudioFormatLinearPCM])
    }()
}

/// Audio file → another audio format, or a video's sound → an audio file.
public struct AudioConverter: Converter {
    public enum Source: String, Sendable {
        case audio
        case video
    }

    public let format: AudioFormat
    public let source: Source

    public init(_ format: AudioFormat, from source: Source) {
        self.format = format
        self.source = source
    }

    public var id: String { source == .audio ? "audio.\(format.id)" : "video.audio.\(format.id)" }
    public var title: String { format.title }
    public var role: ConverterRole { .format }
    public var isSecondary: Bool { format.isSecondary }
    /// A video's audio outputs sit together in an "Audio" submenu.
    public var menuGroup: String? { source == .video ? "Audio" : nil }
    public var isAvailable: Bool { format.isEncodable }

    public func accepts(_ input: InputFile) -> Bool {
        switch source {
        case .video:
            return MediaTypes.isMovie(input)
        case .audio:
            guard MediaTypes.isAudio(input) else { return false }
            // Skip a re-encode to the very same container and codec.
            if input.contentType.identifier == format.typeIdentifier, let info = input.audio,
               info.formatID == format.formatID {
                return false
            }
            return true
        }
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: format.fileExtension)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        try await AudioExport.run(from: input.url, to: destination, format: format,
                                  sourceBits: input.audio?.bitsPerSample ?? 16,
                                  exactLength: input.audio.flatMap { info in info.exactFrames.map { (info.sampleRate, $0) } },
                                  bitRate: options.audioBitRate, progress: progress)
    }
}

// MARK: - Compress

/// Re-encodes a sound file as AAC in M4A at the lower bit rate of
/// `ConversionOptions.compressionAudioBitRate`. Offered for lossless files
/// and for lossy ones recorded well above the lowest rate the setting
/// offers. Gives up rather than saving a file that isn't smaller.
public struct CompressAudioConverter: Converter {
    public init() {}

    public var id: String { "audio.compress" }
    public var title: String { "Compress" }
    public var role: ConverterRole { .tool }
    public var isAvailable: Bool { AudioFormat.m4a.isEncodable }

    static let losslessFormats: Set<AudioFormatID> = [kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatFLAC]

    /// Menus don't know the chosen rate, and `JobRunner` asks again before
    /// converting, so a file is offered when the lowest rate the setting
    /// offers would shrink it; `convert` checks the chosen one.
    public func accepts(_ input: InputFile) -> Bool {
        guard MediaTypes.isAudio(input), let info = input.audio else { return false }
        let lowest = ConversionOptions.compressionAudioBitRates.min() ?? ConversionOptions.default.compressionAudioBitRate
        return Self.shrinks(info, fileSize: Self.fileSize(input.url), to: lowest)
    }

    /// Estimates from the sound's own bytes, so cover art and tags don't
    /// make a file look like a higher rate than it is; from `fileSize` when
    /// the file doesn't say how many those are.
    static func shrinks(_ info: AudioInfo, fileSize: Int, to kbps: Int) -> Bool {
        let bytes = info.audioDataBytes.map { Int(clamping: $0) } ?? fileSize
        return shrinks(format: info.formatID, channels: info.channels, seconds: info.duration, bytes: bytes, to: kbps)
    }

    /// Whether AAC at `kbps` (stereo; mono gets half) should make the file
    /// smaller: always for lossless audio, otherwise when its bit rate,
    /// estimated from its bytes and length, is clearly above the target. A
    /// file at the target rate reads a little higher (encoder priming, or
    /// the container when only the file size is known), and one whose size
    /// or length isn't known is offered and checked afterwards.
    static func shrinks(format: AudioFormatID, channels: Int, seconds: Double, bytes: Int, to kbps: Int) -> Bool {
        if losslessFormats.contains(format) { return true }
        guard seconds > 0, bytes > 0 else { return true }
        let estimated = Double(bytes) * 8 / seconds / 1000
        let target = Double(channels == 1 ? kbps / 2 : kbps)
        return estimated > target * 1.1
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: AudioFormat.m4a.fileExtension, nameSuffix: " (compressed)")
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let info = input.audio else { throw ConversionError.unreadableInput(input.url) }
        let rate = options.compressionAudioBitRate
        let before = Self.fileSize(input.url)
        guard Self.shrinks(info, fileSize: before, to: rate) else {
            throw ConversionError.nothingToDo("\(input.url.lastPathComponent) is already at \(rate) kbit/s or less.")
        }
        try await AudioExport.run(from: input.url, to: destination, format: .m4a, sourceBits: info.bitsPerSample,
                                  exactLength: info.exactFrames.map { (info.sampleRate, $0) },
                                  bitRate: rate, progress: progress)
        let after = Self.fileSize(destination)
        if before > 0 && after >= before * 95 / 100 {
            throw ConversionError.nothingToDo("\(input.url.lastPathComponent) is already well compressed; the result wasn't smaller.")
        }
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

/// Decodes any AVFoundation-readable sound to PCM with AVAssetReader and
/// encodes it with ExtAudioFile, so one path serves every audio output.
enum AudioExport {
    /// `exactLength` is the source's sample rate and true frame count, when
    /// known. AVFoundation decodes FLAC in whole 4608-frame blocks, so
    /// without it the output would gain up to 0.1 s of silence at the end.
    static func run(from source: URL, to destination: URL, format: AudioFormat, sourceBits: Int,
                    exactLength: (sampleRate: Double, frames: Int64)? = nil,
                    bitRate: Int, progress: ProgressHandler) async throws {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let first = tracks.first else {
            throw ConversionError.unsupported("\(source.lastPathComponent) has no sound.")
        }
        let duration = try await asset.load(.duration).seconds
        guard let sourceFormat = try await first.load(.formatDescriptions).first
            .flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) else {
            throw ConversionError.unreadableInput(source)
        }

        // AAC tops out at 48 kHz; keep it to stereo.
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        if format.formatID == kAudioFormatMPEG4AAC {
            if sourceFormat.mSampleRate > 48_000 { settings[AVSampleRateKey] = 48_000 }
            if sourceFormat.mChannelsPerFrame > 2 {
                var layout = AudioChannelLayout()
                layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
                settings[AVNumberOfChannelsKey] = 2
                settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
            }
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ConversionError.encoderFailed("can't read this audio") }
        reader.add(output)
        guard reader.startReading() else {
            throw ConversionError.encoderFailed(reader.error?.localizedDescription ?? "can't read this audio")
        }

        var file: ExtAudioFileRef?
        defer {
            if let file { ExtAudioFileDispose(file) }
            if reader.status == .reading { reader.cancelReading() }
        }
        var framesWritten = 0.0
        var totalFrames = 1.0
        var frameLimit = Double.infinity
        var bytesPerFrame: UInt32 = 0

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            if file == nil {
                // Create the file once the decoded format is known.
                guard let pcm = CMSampleBufferGetFormatDescription(sample)
                    .flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) else {
                    throw ConversionError.encoderFailed("unknown decoded audio format")
                }
                file = try makeFile(at: destination, format: format, pcm: pcm, sourceBits: sourceBits, bitRate: bitRate,
                                    seconds: duration)
                bytesPerFrame = pcm.mBytesPerFrame
                totalFrames = max(1, duration * pcm.mSampleRate)
                if let exactLength {
                    frameLimit = (Double(exactLength.frames) * pcm.mSampleRate / exactLength.sampleRate).rounded()
                    totalFrames = max(1, frameLimit)
                }
            }
            var block: CMBlockBuffer?
            var buffers = AudioBufferList()
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample, bufferListSizeNeededOut: nil, bufferListOut: &buffers,
                bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
            guard status == noErr, let file else { throw ConversionError.encoderFailed("can't read audio samples (\(status))") }
            // Interleaved PCM: a shorter write uses the start of the buffer.
            // ExtAudioFile goes by the buffer's byte size, so trim that too.
            let frames = UInt32(min(Double(CMSampleBufferGetNumSamples(sample)), frameLimit - framesWritten))
            guard frames > 0 else { break }
            buffers.mBuffers.mDataByteSize = min(buffers.mBuffers.mDataByteSize, frames * bytesPerFrame)
            try check(ExtAudioFileWrite(file, frames, &buffers), "writing \(format.title)")
            framesWritten += Double(frames)
            progress(min(0.99, framesWritten / totalFrames))
        }
        try Task.checkCancellation()
        guard reader.status == .completed || framesWritten >= frameLimit else {
            throw ConversionError.encoderFailed(reader.error?.localizedDescription ?? "reading stopped early")
        }
        guard let finished = file else { throw ConversionError.unsupported("\(source.lastPathComponent) has no sound.") }
        file = nil
        // Disposing writes the file's final headers; its status matters.
        try check(ExtAudioFileDispose(finished), "finishing \(format.title)")
    }

    /// `seconds` is the length of the sound, so the file sets aside the
    /// right amount of room for its header: left to guess, an M4A keeps
    /// tens of kilobytes of padding, which dwarfs a short clip.
    private static func makeFile(at url: URL, format: AudioFormat, pcm: AudioStreamBasicDescription,
                                 sourceBits: Int, bitRate: Int, seconds: Double) throws -> ExtAudioFileRef {
        var fileFormat = try format.streamDescription(sampleRate: pcm.mSampleRate, channels: Int(pcm.mChannelsPerFrame),
                                                      sourceBits: sourceBits)
        var file: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(url as CFURL, format.fileType, &fileFormat, nil,
                                            AudioFileFlags.eraseFile.rawValue, &file), "creating \(format.title)")
        guard let file else { throw ConversionError.encoderFailed("creating \(format.title)") }
        var audioFile: AudioFileID?
        var fileSize = UInt32(MemoryLayout<AudioFileID?>.size)
        if seconds > 0, ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioFile, &fileSize, &audioFile) == noErr,
           let audioFile {
            var reserve = Float64(seconds)
            AudioFileSetProperty(audioFile, kAudioFilePropertyReserveDuration, UInt32(MemoryLayout<Float64>.size), &reserve)
        }
        var client = pcm
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client),
                  "setting up \(format.title)")
        if format.formatID == kAudioFormatMPEG4AAC {
            setBitRate(file, kbps: pcm.mChannelsPerFrame == 1 ? bitRate / 2 : bitRate)
        }
        return file
    }

    /// Best effort: if the encoder refuses the rate, its default stays.
    private static func setBitRate(_ file: ExtAudioFileRef, kbps: Int) {
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        guard ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &size, &converter) == noErr,
              let converter else { return }
        var rate = UInt32(kbps * 1000)
        guard AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &rate) == noErr
        else { return }
        // A nil config tells ExtAudioFile to re-read the converter's settings.
        var config: CFArray?
        withUnsafeMutablePointer(to: &config) { pointer in
            _ = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig,
                                        UInt32(MemoryLayout<CFArray?>.size), pointer)
        }
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw ConversionError.encoderFailed("\(step) (\(status))") }
    }
}
