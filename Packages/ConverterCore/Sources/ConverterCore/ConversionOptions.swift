import Foundation

/// User-adjustable settings that converters read. The app stores these in
/// its settings window; the CLI fills them from flags.
public struct ConversionOptions: Sendable, Hashable, Codable {
    /// Quality for lossy image formats (JPEG, HEIC, AVIF), 0...1.
    public var imageQuality: Double
    /// Quality used by the "Compress image" tool, 0...1.
    public var compressionQuality: Double
    /// Keep EXIF, GPS, IPTC and XMP metadata when converting images.
    public var keepMetadata: Bool
    /// AAC bit rate for stereo, in kbit/s (mono uses half).
    public var audioBitRate: Int
    /// AAC bit rate used by the "Compress audio" tool, in kbit/s for stereo.
    public var compressionAudioBitRate: Int
    /// Frames per second and longest side, in pixels, of GIFs made from video.
    public var gifFrameRate: Double
    public var gifMaxSide: Int
    /// Resolution used when rendering PDF pages to images.
    public var pdfRenderDPI: Double
    /// How hard "Compress video" squeezes: smaller file, balanced, or better quality.
    public var videoCompression: VideoCompression

    public enum VideoCompression: String, Sendable, Hashable, Codable, CaseIterable {
        case smaller, balanced, better

        /// HEVC bits per pixel per frame.
        var bitsPerPixel: Double {
            switch self {
            case .smaller: return 0.03
            case .balanced: return 0.05
            case .better: return 0.08
            }
        }
    }

    public init(imageQuality: Double = 0.85, compressionQuality: Double = 0.6, keepMetadata: Bool = true,
                audioBitRate: Int = 256, compressionAudioBitRate: Int = 128, gifFrameRate: Double = 10, gifMaxSide: Int = 480,
                pdfRenderDPI: Double = 150, videoCompression: VideoCompression = .balanced) {
        self.imageQuality = imageQuality
        self.compressionQuality = compressionQuality
        self.keepMetadata = keepMetadata
        self.audioBitRate = audioBitRate
        self.compressionAudioBitRate = compressionAudioBitRate
        self.gifFrameRate = gifFrameRate
        self.gifMaxSide = gifMaxSide
        self.pdfRenderDPI = pdfRenderDPI
        self.videoCompression = videoCompression
    }

    public static let `default` = ConversionOptions()

    /// Settings saved by an earlier version lack the options added since;
    /// those take their defaults rather than resetting everything.
    public init(from decoder: any Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        let standard = ConversionOptions()
        imageQuality = try saved.decodeIfPresent(Double.self, forKey: .imageQuality) ?? standard.imageQuality
        compressionQuality = try saved.decodeIfPresent(Double.self, forKey: .compressionQuality) ?? standard.compressionQuality
        keepMetadata = try saved.decodeIfPresent(Bool.self, forKey: .keepMetadata) ?? standard.keepMetadata
        audioBitRate = try saved.decodeIfPresent(Int.self, forKey: .audioBitRate) ?? standard.audioBitRate
        compressionAudioBitRate = try saved.decodeIfPresent(Int.self, forKey: .compressionAudioBitRate) ?? standard.compressionAudioBitRate
        gifFrameRate = try saved.decodeIfPresent(Double.self, forKey: .gifFrameRate) ?? standard.gifFrameRate
        gifMaxSide = try saved.decodeIfPresent(Int.self, forKey: .gifMaxSide) ?? standard.gifMaxSide
        pdfRenderDPI = try saved.decodeIfPresent(Double.self, forKey: .pdfRenderDPI) ?? standard.pdfRenderDPI
        videoCompression = try saved.decodeIfPresent(VideoCompression.self, forKey: .videoCompression) ?? standard.videoCompression
    }
}
