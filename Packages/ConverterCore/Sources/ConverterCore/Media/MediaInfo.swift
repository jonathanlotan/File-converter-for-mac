import AudioToolbox
import AVFoundation
import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Header facts about an audio file, read synchronously with AudioFile.
public struct AudioInfo: Sendable, Hashable {
    public let formatID: AudioFormatID
    public let sampleRate: Double
    public let channels: Int
    /// Bits per sample of the source, or 16 for lossy formats.
    public let bitsPerSample: Int
    public let duration: Double
    /// Exact length in frames when the file records it (PCM, or a packet
    /// table as in FLAC and M4A); nil when it's only an estimate (MP3, ADTS).
    public let exactFrames: Int64?

    init?(url: URL) {
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &format) == noErr else { return nil }
        var duration: Double = 0
        size = UInt32(MemoryLayout<Double>.size)
        AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)

        var table = AudioFilePacketTableInfo()
        size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
        var packets: UInt64 = 0
        var packetsSize = UInt32(MemoryLayout<UInt64>.size)
        if AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &table) == noErr, table.mNumberValidFrames > 0 {
            exactFrames = table.mNumberValidFrames
        } else if format.mFormatID == kAudioFormatLinearPCM,
                  AudioFileGetProperty(file, kAudioFilePropertyAudioDataPacketCount, &packetsSize, &packets) == noErr {
            exactFrames = Int64(packets)
        } else {
            exactFrames = nil
        }

        formatID = format.mFormatID
        sampleRate = format.mSampleRate
        channels = Int(format.mChannelsPerFrame)
        self.duration = duration
        switch format.mFormatID {
        case kAudioFormatLinearPCM:
            bitsPerSample = Int(format.mBitsPerChannel)
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            // These formats record the source depth in their flags.
            bitsPerSample = [1: 16, 2: 20, 3: 24, 4: 32][format.mFormatFlags] ?? 16
        default:
            bitsPerSample = 16
        }
    }
}

/// Which inputs AVFoundation can play, by type.
enum MediaTypes {
    static let readable: Set<String> = Set(AVURLAsset.audiovisualTypes().map(\.rawValue))

    static func isReadable(_ type: UTType) -> Bool {
        readable.contains(type.identifier)
    }

    static func isMovie(_ input: InputFile) -> Bool {
        !input.isDirectory && input.contentType.conforms(to: .movie) && isReadable(input.contentType)
    }

    static func isAudio(_ input: InputFile) -> Bool {
        !input.isDirectory && input.contentType.conforms(to: .audio) && isReadable(input.contentType)
    }

    /// The short side of a video's picture from Spotlight's metadata, read
    /// synchronously so menus can use it; nil when the file isn't indexed
    /// (yet). Rotation only swaps the sides, so it doesn't matter here.
    static func shortSide(ofMovieAt url: URL) -> Int? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let width = MDItemCopyAttribute(item, kMDItemPixelWidth) as? Int,
              let height = MDItemCopyAttribute(item, kMDItemPixelHeight) as? Int,
              width > 0, height > 0 else { return nil }
        return min(width, height)
    }
}
