import Foundation
import UniformTypeIdentifiers

/// Reports progress of a single conversion as a fraction from 0 to 1.
public typealias ProgressHandler = @Sendable (Double) -> Void

/// Whether a converter produces another format of the same content, or
/// applies a tool (resize, compress, ...) to it.
public enum ConverterRole: String, Sendable, Codable {
    case format
    case tool
}

/// What a converter will write for a given input. The job runner turns this
/// into a final name beside the original, e.g. `photo (1920px).jpg`.
public struct OutputSpec: Sendable, Hashable {
    /// Extension of the output, without the dot (`"jpg"`).
    public var fileExtension: String
    /// Text appended to the base name before the extension, e.g. `" (compressed)"`.
    public var nameSuffix: String
    /// True when the output is a folder (for example one image per PDF page).
    public var isDirectory: Bool
    /// Replaces the input's base name, e.g. `photos` for `photos.tar.gz`,
    /// or `Archive` for a ZIP of several files.
    public var baseName: String?

    public init(fileExtension: String, nameSuffix: String = "", isDirectory: Bool = false, baseName: String? = nil) {
        self.fileExtension = fileExtension
        self.nameSuffix = nameSuffix
        self.isDirectory = isDirectory
        self.baseName = baseName
    }
}

/// One conversion the app can offer, such as "HEIC → JPEG" or "Resize to 1920 px".
///
/// Converters write only to the `destination` they are given, which lives in
/// a temporary folder. `JobRunner` moves the result beside the original once
/// the converter returns, and deletes it if the converter throws or is
/// cancelled, so a converter never has to clean up after itself.
public protocol Converter: Sendable {
    /// Stable identifier, e.g. `"image.jpeg"` or `"image.resize.1920"`.
    var id: String { get }
    /// Short label for menus, e.g. `"JPEG"` or `"1920 px"`.
    var title: String { get }
    var role: ConverterRole { get }
    /// Shown in the outer ring or "More" rather than the main ring.
    var isSecondary: Bool { get }
    /// Name of the submenu (or sub-ring) this converter is grouped under,
    /// e.g. `"Resize"`; nil for a top-level entry.
    var menuGroup: String? { get }
    /// False when this system lacks the encoder (checked once at launch).
    var isAvailable: Bool { get }

    func accepts(_ input: InputFile) -> Bool
    func output(for input: InputFile) -> OutputSpec
    func convert(
        _ input: InputFile,
        to destination: URL,
        options: ConversionOptions,
        progress: ProgressHandler
    ) async throws

    /// True when several dropped files make one output (a ZIP of a
    /// selection, merged PDFs) instead of one output each.
    var combinesInputs: Bool { get }
    /// Fewest files this converter makes sense for (2 for "Merge PDFs").
    var minimumInputs: Int { get }
    /// Output for several inputs combined. Only used when `combinesInputs`.
    func output(for inputs: [InputFile]) -> OutputSpec
    /// Converts several inputs into one output. Only used when `combinesInputs`.
    func convert(
        _ inputs: [InputFile],
        to destination: URL,
        options: ConversionOptions,
        progress: ProgressHandler
    ) async throws
}

extension Converter {
    public var isSecondary: Bool { false }
    public var menuGroup: String? { nil }
    public var combinesInputs: Bool { false }
    public var minimumInputs: Int { 1 }

    public func output(for inputs: [InputFile]) -> OutputSpec {
        output(for: inputs[0])
    }

    public func convert(_ inputs: [InputFile], to destination: URL, options: ConversionOptions,
                        progress: ProgressHandler) async throws {
        try await convert(inputs[0], to: destination, options: options, progress: progress)
    }
}
