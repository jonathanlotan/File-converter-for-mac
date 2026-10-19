import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// One labelled value, e.g. "Aperture: f/2.8".
public struct MetadataField: Sendable, Hashable, Identifiable {
    public let label: String
    public let value: String
    public var id: String { label }

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// A titled group of fields, e.g. "Camera".
public struct MetadataSection: Sendable, Hashable, Identifiable {
    public let title: String
    public let fields: [MetadataField]
    public var id: String { title }

    public init(_ title: String, _ fields: [MetadataField]) {
        self.title = title
        self.fields = fields
    }

    public subscript(label: String) -> String? {
        fields.first { $0.label == label }?.value
    }
}

/// What a file records about itself, for the metadata window: file facts,
/// then image (EXIF, GPS, IPTC), audio and video, or PDF details. Only file
/// headers are read, and nothing leaves the Mac.
public enum FileMetadata {
    public static func sections(for url: URL) async -> [MetadataSection] {
        var sections = [fileSection(url)]
        if let input = try? InputFile(url: url), !input.isDirectory {
            if PDFFiles.isPDF(input) {
                sections += pdfSections(url)
            } else if let info = input.image, let source = ImageCodec.makeSource(url: url, contentType: input.contentType) {
                sections += imageSections(source, info: info)
            } else if MediaTypes.isMovie(input) || MediaTypes.isAudio(input) {
                sections += await mediaSections(url)
            }
        }
        return sections.filter { !$0.fields.isEmpty }
    }

    /// The sections as plain text, for copying.
    public static func text(_ sections: [MetadataSection]) -> String {
        sections.map { section in
            ([section.title] + section.fields.map { "\($0.label): \($0.value)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: - File

    static func fileSection(_ url: URL) -> MetadataSection {
        let keys: Set<URLResourceKey> = [.localizedTypeDescriptionKey, .fileSizeKey, .creationDateKey,
                                         .contentModificationDateKey, .isDirectoryKey, .tagNamesKey]
        let values = try? url.resourceValues(forKeys: keys)
        var list = Fields()
        list.add("Kind", values?.localizedTypeDescription)
        if values?.isDirectory == true {
            let count = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
            list.add("Contents", count == 1 ? "1 item" : "\(count) items")
        } else if let size = values?.fileSize {
            let bytes = NumberFormatter.localizedString(from: NSNumber(value: size), number: .decimal)
            list.add("Size", "\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) (\(bytes) bytes)")
        }
        list.add("Created", values?.creationDate.map(format))
        list.add("Modified", values?.contentModificationDate.map(format))
        list.add("Where", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        list.add("Tags", values?.tagNames?.joined(separator: ", "))
        list.add("Downloaded From", whereFroms(url).joined(separator: "\n"))
        return MetadataSection("File", list.fields)
    }

    /// The web pages a downloaded file came from, as recorded by the browser.
    static func whereFroms(_ url: URL) -> [String] {
        let name = "com.apple.metadata:kMDItemWhereFroms"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return [] }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, 0) }
        guard read == length else { return [] }
        let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        return (list ?? []).filter { !$0.isEmpty }
    }

    // MARK: - Images

    static func imageSections(_ source: CGImageSource, info: ImageInfo) -> [MetadataSection] {
        let props = ImageCodec.properties(source, info.primaryIndex)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        var image = Fields()
        image.add("Dimensions", "\(info.width) × \(info.height) pixels")
        if info.orientation != 1 { image.add("Orientation", orientationNames[info.orientation]) }
        if info.frameCount > 1 { image.add(info.isAnimated ? "Frames" : "Images", "\(info.frameCount)") }
        image.add("Colour Model", props[kCGImagePropertyColorModel] as? String)
        image.add("Colour Profile", props[kCGImagePropertyProfileName] as? String)
        image.add("Depth", number(props[kCGImagePropertyDepth]).map { "\(Int($0)) bits per channel" })
        image.add("Transparency", info.hasAlpha ? "Yes" : "No")
        if let x = number(props[kCGImagePropertyDPIWidth]), let y = number(props[kCGImagePropertyDPIHeight]) {
            image.add("Resolution", x == y ? "\(trimmed(x)) dpi" : "\(trimmed(x)) × \(trimmed(y)) dpi")
        }

        var camera = Fields()
        camera.add("Make", tiff[kCGImagePropertyTIFFMake] as? String)
        camera.add("Model", tiff[kCGImagePropertyTIFFModel] as? String)
        camera.add("Lens", (exif[kCGImagePropertyExifLensModel] ?? aux[kCGImagePropertyExifAuxLensModel]) as? String)
        if let focal = number(exif[kCGImagePropertyExifFocalLength]) {
            let film = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]).map { " (\(Int($0)) mm in 35 mm terms)" } ?? ""
            camera.add("Focal Length", "\(trimmed(focal)) mm" + film)
        }
        camera.add("Aperture", number(exif[kCGImagePropertyExifFNumber]).map { "f/\(trimmed($0))" })
        camera.add("Exposure", number(exif[kCGImagePropertyExifExposureTime]).map(exposure))
        camera.add("ISO", ((exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first).map { "ISO \($0.intValue)" })
        if let bias = number(exif[kCGImagePropertyExifExposureBiasValue]), bias != 0 {
            camera.add("Exposure Bias", String(format: "%+.1f EV", bias))
        }
        camera.add("Flash", number(exif[kCGImagePropertyExifFlash]).map { Int($0) & 1 == 1 ? "Fired" : "Did not fire" })
        camera.add("Taken", (exif[kCGImagePropertyExifDateTimeOriginal] as? String).map {
            exifDate($0, offset: exif[kCGImagePropertyExifOffsetTimeOriginal] as? String)
        })
        camera.add("Software", tiff[kCGImagePropertyTIFFSoftware] as? String)

        var location = Fields()
        if let lat = number(gps[kCGImagePropertyGPSLatitude]), let lon = number(gps[kCGImagePropertyGPSLongitude]) {
            let north = (gps[kCGImagePropertyGPSLatitudeRef] as? String)?.uppercased() != "S"
            let east = (gps[kCGImagePropertyGPSLongitudeRef] as? String)?.uppercased() != "W"
            location.add("Latitude", String(format: "%.6f° %@", lat, north ? "N" : "S"))
            location.add("Longitude", String(format: "%.6f° %@", lon, east ? "E" : "W"))
            // Signed decimal degrees, the form maps and search boxes accept.
            location.add("Coordinates", String(format: "%.6f, %.6f", north ? lat : -lat, east ? lon : -lon))
        }
        if let altitude = number(gps[kCGImagePropertyGPSAltitude]) {
            let below = number(gps[kCGImagePropertyGPSAltitudeRef]) == 1
            location.add("Altitude", String(format: "%.0f m", below ? -altitude : altitude))
        }
        location.add("Direction", number(gps[kCGImagePropertyGPSImgDirection]).map { String(format: "%.0f°", $0) })

        var description = Fields()
        description.add("Title", iptc[kCGImagePropertyIPTCObjectName] as? String)
        description.add("Caption", (iptc[kCGImagePropertyIPTCCaptionAbstract] ?? tiff[kCGImagePropertyTIFFImageDescription]) as? String)
        description.add("Creator", strings(iptc[kCGImagePropertyIPTCByline]) ?? tiff[kCGImagePropertyTIFFArtist] as? String)
        description.add("Copyright", (tiff[kCGImagePropertyTIFFCopyright] ?? iptc[kCGImagePropertyIPTCCopyrightNotice]) as? String)
        description.add("Keywords", strings(iptc[kCGImagePropertyIPTCKeywords]))

        return [MetadataSection("Image", image.fields), MetadataSection("Camera", camera.fields),
                MetadataSection("Location", location.fields), MetadataSection("Description", description.fields)]
    }

    static let orientationNames: [Int: String] = [
        2: "Mirrored", 3: "Rotated 180°", 4: "Mirrored, rotated 180°",
        5: "Mirrored, rotated 90° anticlockwise", 6: "Rotated 90° clockwise",
        7: "Mirrored, rotated 90° clockwise", 8: "Rotated 90° anticlockwise",
    ]

    /// "1/250 s" for short exposures, "2 s" for long ones.
    static func exposure(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        return seconds < 1 ? "1/\(Int((1 / seconds).rounded())) s" : "\(trimmed(seconds)) s"
    }

    /// EXIF's "2024:05:01 10:00:00" (with its offset, when recorded) as a date.
    static func exifDate(_ text: String, offset: String?) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = offset == nil ? "yyyy:MM:dd HH:mm:ss" : "yyyy:MM:dd HH:mm:ssxxx"
        return parser.date(from: offset.map { text + $0 } ?? text).map(format) ?? text
    }

    // MARK: - Audio and video

    static func mediaSections(_ url: URL) async -> [MetadataSection] {
        let asset = AVURLAsset(url: url)
        guard let loaded = try? await asset.load(.duration, .tracks, .commonMetadata) else { return [] }
        let (duration, tracks, metadata) = loaded
        let seconds = duration.seconds.isFinite ? duration.seconds : 0
        var sections: [MetadataSection] = []

        var media = Fields()
        media.add("Duration", seconds > 0 ? self.duration(seconds) : nil)
        if seconds > 0, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            media.add("Bit Rate", bitRate(Double(size) * 8 / seconds))
        }
        sections.append(MetadataSection("Media", media.fields))

        if let track = tracks.first(where: { $0.mediaType == .video }),
           let loaded = try? await track.load(
               .naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions) {
            let (size, transform, fps, rate, formats) = loaded
            var video = Fields()
            let shown = CGRect(origin: .zero, size: size).applying(transform)
            video.add("Dimensions", "\(Int(abs(shown.width).rounded())) × \(Int(abs(shown.height).rounded())) pixels")
            video.add("Codec", formats.first.map { codecName(CMFormatDescriptionGetMediaSubType($0)) })
            video.add("Frame Rate", fps > 0 ? "\(trimmed(Double(fps))) fps" : nil)
            video.add("Bit Rate", rate > 0 ? bitRate(Double(rate)) : nil)
            sections.append(MetadataSection("Video", video.fields))
        }

        if let track = tracks.first(where: { $0.mediaType == .audio }),
           let loaded = try? await track.load(.estimatedDataRate, .formatDescriptions) {
            let (rate, formats) = loaded
            var audio = Fields()
            if let format = formats.first {
                audio.add("Codec", codecName(CMFormatDescriptionGetMediaSubType(format)))
                if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    audio.add("Sample Rate", basic.mSampleRate > 0 ? "\(trimmed(basic.mSampleRate / 1000)) kHz" : nil)
                    let channels = Int(basic.mChannelsPerFrame)
                    audio.add("Channels", channels == 1 ? "Mono" : channels == 2 ? "Stereo" : channels > 0 ? "\(channels)" : nil)
                }
            }
            audio.add("Bit Rate", rate > 0 ? bitRate(Double(rate)) : nil)
            sections.append(MetadataSection("Audio", audio.fields))
        }

        var details = Fields()
        let labels: [(AVMetadataKey, String)] = [
            (.commonKeyTitle, "Title"), (.commonKeyArtist, "Artist"), (.commonKeyAlbumName, "Album"),
            (.commonKeyCreator, "Creator"), (.commonKeyDescription, "Description"), (.commonKeyCopyrights, "Copyright"),
            (.commonKeyCreationDate, "Recorded"), (.commonKeyMake, "Make"), (.commonKeyModel, "Model"),
            (.commonKeySoftware, "Software"), (.commonKeyLocation, "Location"),
        ]
        for (key, label) in labels {
            guard let item = metadata.first(where: { $0.commonKey == key }) else { continue }
            details.add(label, try? await item.load(.stringValue))
        }
        sections.append(MetadataSection("Details", details.fields))
        return sections
    }

    static func codecName(_ code: FourCharCode) -> String {
        let names: [String: String] = [
            "avc1": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "av01": "AV1", "vp09": "VP9", "mp4v": "MPEG-4",
            "jpeg": "Motion JPEG", "apch": "ProRes 422 HQ", "apcn": "ProRes 422", "apcs": "ProRes 422 LT",
            "apco": "ProRes 422 Proxy", "ap4h": "ProRes 4444", "ap4x": "ProRes 4444 XQ",
            "aac ": "AAC", "lpcm": "PCM", "alac": "Apple Lossless", "fLaC": "FLAC", ".mp3": "MP3",
            "opus": "Opus", "ac-3": "Dolby Digital", "ec-3": "Dolby Digital Plus",
        ]
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .macOSRoman) ?? "\(code)"
        return names[fourCC] ?? fourCC.trimmingCharacters(in: .whitespaces)
    }

    /// "0:05", "3:07" or "1:02:03".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func bitRate(_ bitsPerSecond: Double) -> String {
        bitsPerSecond >= 1_000_000 ? String(format: "%.1f Mbit/s", bitsPerSecond / 1_000_000)
                                   : String(format: "%.0f kbit/s", bitsPerSecond / 1000)
    }

    // MARK: - PDF

    static func pdfSections(_ url: URL) -> [MetadataSection] {
        guard let document = PDFDocument(url: url) else { return [] }
        let attributes = document.documentAttributes ?? [:]
        func text(_ key: PDFDocumentAttribute) -> String? {
            strings(attributes[key]) ?? (attributes[key] as? String)
        }
        var pdf = Fields()
        pdf.add("Pages", "\(document.pageCount)")
        if let page = document.page(at: 0) {
            let box = page.bounds(for: .mediaBox)
            let metric = Locale.current.measurementSystem != .us
            let (w, h) = metric ? (box.width / 72 * 25.4, box.height / 72 * 25.4) : (box.width / 72, box.height / 72)
            pdf.add("Page Size", String(format: metric ? "%.0f × %.0f mm" : "%.2f × %.2f in", w, h))
        }
        pdf.add("PDF Version", "\(document.majorVersion).\(document.minorVersion)")
        pdf.add("Title", text(.titleAttribute))
        pdf.add("Author", text(.authorAttribute))
        pdf.add("Subject", text(.subjectAttribute))
        pdf.add("Keywords", text(.keywordsAttribute))
        pdf.add("Application", text(.creatorAttribute))
        pdf.add("PDF Producer", text(.producerAttribute))
        pdf.add("Created", (attributes[PDFDocumentAttribute.creationDateAttribute] as? Date).map(format))
        pdf.add("Modified", (attributes[PDFDocumentAttribute.modificationDateAttribute] as? Date).map(format))
        pdf.add("Security", document.isLocked ? "Needs a password to open"
                                              : document.isEncrypted ? "Encrypted" : "None")
        if !document.isLocked {
            var limits: [String] = []
            if !document.allowsPrinting { limits.append("printing") }
            if !document.allowsCopying { limits.append("copying") }
            if !limits.isEmpty { pdf.add("Restrictions", "No " + limits.joined(separator: " or ")) }
        }
        return [MetadataSection("PDF", pdf.fields)]
    }

    // MARK: - Helpers

    private struct Fields {
        var fields: [MetadataField] = []

        mutating func add(_ label: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            fields.append(MetadataField(label, value))
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// A list of strings (IPTC keywords, PDF keywords) joined with commas.
    private static func strings(_ value: Any?) -> String? {
        guard let list = value as? [Any] else { return nil }
        let joined = list.compactMap { $0 as? String }.joined(separator: ", ")
        return joined.isEmpty ? nil : joined
    }

    /// "2.8" rather than "2.80", "50" rather than "50.0".
    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }

    private static func format(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
