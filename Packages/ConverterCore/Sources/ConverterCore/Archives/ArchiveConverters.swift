import Foundation

/// Archive types Converter recognises, by file name (several have no
/// system type identifier, and `.tar.gz` needs both suffixes).
public enum ArchiveKind: String, Sendable, Hashable {
    case zip, tar, tarGz, tarBz2, tarXz, sevenZip, rar, aar, cpio, xar
    /// A single compressed file (`report.pdf.gz`), not an archive of several.
    case gzip, bzip2

    private static let suffixes: [(String, ArchiveKind)] = [
        (".tar.gz", .tarGz), (".tgz", .tarGz), (".tar.bz2", .tarBz2), (".tbz2", .tarBz2), (".tbz", .tarBz2),
        (".tar.xz", .tarXz), (".txz", .tarXz), (".tar", .tar), (".zip", .zip), (".7z", .sevenZip),
        (".rar", .rar), (".aar", .aar), (".cpio", .cpio), (".xar", .xar), (".gz", .gzip), (".bz2", .bzip2),
    ]

    /// The archive kind and the name without archive suffixes
    /// (`photos.tar.gz` → `.tarGz`, `photos`).
    public static func detect(_ input: InputFile) -> (kind: ArchiveKind, baseName: String)? {
        guard !input.isDirectory else { return nil }
        let name = input.url.lastPathComponent
        let lower = name.lowercased()
        for (suffix, kind) in suffixes where lower.hasSuffix(suffix) && lower.count > suffix.count {
            return (kind, String(name.dropLast(suffix.count)))
        }
        return nil
    }

    var isSingleFile: Bool { self == .gzip || self == .bzip2 }
}

/// An archive format Converter can create.
public struct ArchiveFormat: Sendable, Hashable {
    public let id: String
    public let title: String
    public let fileExtension: String
    let kind: ArchiveKind

    public static let zip = ArchiveFormat(id: "zip", title: "ZIP", fileExtension: "zip", kind: .zip)
    public static let tarGz = ArchiveFormat(id: "tar.gz", title: "TAR.GZ", fileExtension: "tar.gz", kind: .tarGz)
    public static let tarXz = ArchiveFormat(id: "tar.xz", title: "TAR.XZ", fileExtension: "tar.xz", kind: .tarXz)
    public static let sevenZip = ArchiveFormat(id: "7z", title: "7Z", fileExtension: "7z", kind: .sevenZip)
    public static let aar = ArchiveFormat(id: "aar", title: "Apple Archive", fileExtension: "aar", kind: .aar)

    public static let all: [ArchiveFormat] = [zip, tarGz, tarXz, sevenZip, aar]
}

// MARK: - Converters

/// Archive → folder (or a single compressed file → that file).
public struct ExtractArchiveConverter: Converter {
    public init() {}

    public var id: String { "archive.extract" }
    public var title: String { "Extract" }
    public var role: ConverterRole { .format }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        ArchiveKind.detect(input) != nil
    }

    public func output(for input: InputFile) -> OutputSpec {
        guard let (kind, base) = ArchiveKind.detect(input) else { return OutputSpec(fileExtension: "", isDirectory: true) }
        return OutputSpec(fileExtension: "", isDirectory: !kind.isSingleFile, baseName: base)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let (kind, base) = ArchiveKind.detect(input) else { throw ConversionError.unreadableInput(input.url) }
        if kind.isSingleFile {
            let tool = kind == .gzip ? "/usr/bin/gzip" : "/usr/bin/bzip2"
            try await Subprocess.run(tool, ["-dc", input.url.path], standardOutput: destination)
            return
        }
        try await Archives.extract(kind, from: input.url, into: destination)
        try Archives.flattenSingleFolder(named: base, in: destination)
    }
}

/// Files or folders → one archive (`photos.zip`, or `Archive.zip` for several).
public struct CreateArchiveConverter: Converter {
    public let format: ArchiveFormat

    public init(_ format: ArchiveFormat) {
        self.format = format
    }

    public var id: String { "archive.create.\(format.id)" }
    public var title: String { format.title }
    public var role: ConverterRole { .tool }
    public var menuGroup: String? { "Archive" }
    public var combinesInputs: Bool { true }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        ArchiveKind.detect(input) == nil
    }

    public func output(for input: InputFile) -> OutputSpec {
        output(for: [input])
    }

    public func output(for inputs: [InputFile]) -> OutputSpec {
        // Like Finder: "report.pdf" → "report.pdf.zip"; several → "Archive.zip".
        let base = inputs.count == 1 ? inputs[0].url.lastPathComponent : "Archive"
        return OutputSpec(fileExtension: format.fileExtension, baseName: base)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        try await convert([input], to: destination, options: options, progress: progress)
    }

    public func convert(_ inputs: [InputFile], to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        try await Archives.create(format, items: inputs.map(\.url), at: destination)
    }
}

/// One archive format → another (RAR → ZIP, ZIP → 7Z, ...), by extracting
/// to a scratch folder and archiving its contents again.
public struct ConvertArchiveConverter: Converter {
    public let format: ArchiveFormat

    public init(_ format: ArchiveFormat) {
        self.format = format
    }

    public var id: String { "archive.convert.\(format.id)" }
    public var title: String { format.title }
    public var role: ConverterRole { .format }
    public var isSecondary: Bool { format == .aar || format == .tarXz }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        guard let (kind, _) = ArchiveKind.detect(input) else { return false }
        return !kind.isSingleFile && kind != format.kind
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: format.fileExtension, baseName: ArchiveKind.detect(input)?.baseName)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let (kind, _) = ArchiveKind.detect(input) else { throw ConversionError.unreadableInput(input.url) }
        let scratch = destination.deletingLastPathComponent()
            .appendingPathComponent("extracted-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try await Archives.extract(kind, from: input.url, into: scratch)
        progress(0.5)
        try await Archives.create(format, contentsOf: scratch, at: destination)
    }
}

public enum ArchiveConverters {
    public static let all: [any Converter] =
        [ExtractArchiveConverter() as any Converter]
        + ArchiveFormat.all.map { ConvertArchiveConverter($0) as any Converter }
        + ArchiveFormat.all.map { CreateArchiveConverter($0) as any Converter }
}

// MARK: - The work, done with the system's own tools

enum Archives {
    static let tar = "/usr/bin/tar"     // bsdtar (libarchive)
    static let ditto = "/usr/bin/ditto"
    static let aa = "/usr/bin/aa"

    /// Extracts into `folder` (created here). `tar` refuses entries with
    /// `..` or absolute paths and `ditto` strips them, so nothing lands
    /// outside the folder.
    static func extract(_ kind: ArchiveKind, from archive: URL, into folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        switch kind {
        case .zip:
            // Like Archive Utility: restores resource forks from __MACOSX.
            try await Subprocess.run(ditto, ["-x", "-k", archive.path, folder.path])
        case .aar:
            try await Subprocess.run(aa, ["extract", "-d", folder.path, "-i", archive.path])
        case .gzip, .bzip2:
            throw ConversionError.unsupported("\(archive.lastPathComponent) is a single compressed file.")
        default:
            try await Subprocess.run(tar, ["-xf", archive.path, "-C", folder.path])
        }
    }

    /// `photos.zip` holding just `photos/` shouldn't become `photos/photos/`.
    static func flattenSingleFolder(named name: String, in folder: URL) throws {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: folder.path).filter { $0 != ".DS_Store" && $0 != "__MACOSX" }
        guard entries == [name] else { return }
        var isDirectory: ObjCBool = false
        let inner = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: inner.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        let holding = folder.deletingLastPathComponent().appendingPathComponent("flatten-\(UUID().uuidString)")
        try fm.moveItem(at: folder, to: holding)
        try fm.moveItem(at: holding.appendingPathComponent(name), to: folder)
        try fm.removeItem(at: holding)
    }

    /// Archives the listed files and folders. Items that share a folder are
    /// archived in place; otherwise they're cloned (instant on APFS) into a
    /// scratch folder first.
    static func create(_ format: ArchiveFormat, items: [URL], at destination: URL) async throws {
        guard !items.isEmpty else { throw ConversionError.nothingToDo("No files to archive.") }
        if format.kind == .zip && items.count == 1 {
            // Like Finder's Compress. --keepParent keeps a folder's own name
            // in the archive; for a single file it would store the enclosing
            // folder too, so it's only used for folders.
            let isFolder = (try? items[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            try await Subprocess.run(ditto, ["-c", "-k", "--sequesterRsrc"] + (isFolder ? ["--keepParent"] : [])
                                     + [items[0].path, destination.path])
            return
        }
        let parents = Set(items.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        if parents.count == 1, format.kind != .zip, format.kind != .aar {
            try await createTar(format, in: items[0].deletingLastPathComponent(), names: items.map(\.lastPathComponent), at: destination)
            return
        }
        let scratch = destination.deletingLastPathComponent()
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        for item in items {
            try FileManager.default.copyItem(at: item, to: scratch.appendingPathComponent(item.lastPathComponent))
        }
        try await create(format, contentsOf: scratch, at: destination)
    }

    /// Archives everything inside `folder`, without the folder itself.
    static func create(_ format: ArchiveFormat, contentsOf folder: URL, at destination: URL) async throws {
        switch format.kind {
        case .zip:
            try await Subprocess.run(ditto, ["-c", "-k", "--sequesterRsrc", folder.path, destination.path])
        case .aar:
            try await Subprocess.run(aa, ["archive", "-d", folder.path, "-o", destination.path])
        default:
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != "__MACOSX" }.sorted()
            guard !names.isEmpty else { throw ConversionError.nothingToDo("The archive is empty.") }
            try await createTar(format, in: folder, names: names, at: destination)
        }
    }

    private static func createTar(_ format: ArchiveFormat, in folder: URL, names: [String], at destination: URL) async throws {
        let mode: [String]
        switch format.kind {
        case .tarGz: mode = ["-czf"]
        case .tarXz: mode = ["-cJf"]
        case .sevenZip: mode = ["--format", "7zip", "-cf"]
        default: mode = ["-cf"]
        }
        // A name starting with "-" would read as an option.
        let safeNames = names.map { $0.hasPrefix("-") ? "./" + $0 : $0 }
        try await Subprocess.run(tar, mode + [destination.path, "-C", folder.path] + safeNames)
    }
}
