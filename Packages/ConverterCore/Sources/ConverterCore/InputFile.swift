import Foundation
import UniformTypeIdentifiers

/// A file (or folder) the user wants to convert, with the facts converters
/// need to decide whether they apply. Creating one reads only file headers.
public struct InputFile: Sendable, Hashable {
    public let url: URL
    public let contentType: UTType
    public let isDirectory: Bool
    /// Present when ImageIO can decode the file.
    public let image: ImageInfo?
    /// Present for audio files AudioToolbox can open (not for videos).
    public let audio: AudioInfo?

    public init(url: URL) throws {
        let url = url.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw ConversionError.unreadableInput(url)
        }
        self.url = url
        self.isDirectory = isDir.boolValue
        let declared = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        self.contentType = declared ?? UTType(filenameExtension: url.pathExtension) ?? .data
        self.image = isDir.boolValue ? nil : ImageInfo(url: url, contentType: contentType)
        let isAudio = !isDir.boolValue && contentType.conforms(to: .audio)
        self.audio = isAudio ? AudioInfo(url: url) : nil
    }

    /// File name without its extension: `photo` for `photo.heic`.
    public var baseName: String {
        url.deletingPathExtension().lastPathComponent
    }
}
