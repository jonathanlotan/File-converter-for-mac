import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A text document format `textutil` can write.
public struct TextFormat: Sendable, Hashable {
    public let id: String
    public let title: String
    /// `textutil -convert` format name.
    let textutilName: String
    public let fileExtension: String
    let typeIdentifier: String
    public let isSecondary: Bool

    public static let txt = TextFormat(id: "txt", title: "Plain Text", textutilName: "txt", fileExtension: "txt",
                                       typeIdentifier: "public.plain-text", isSecondary: false)
    public static let rtf = TextFormat(id: "rtf", title: "RTF", textutilName: "rtf", fileExtension: "rtf",
                                       typeIdentifier: "public.rtf", isSecondary: false)
    public static let html = TextFormat(id: "html", title: "HTML", textutilName: "html", fileExtension: "html",
                                        typeIdentifier: "public.html", isSecondary: false)
    public static let docx = TextFormat(id: "docx", title: "Word", textutilName: "docx", fileExtension: "docx",
                                        typeIdentifier: "org.openxmlformats.wordprocessingml.document", isSecondary: false)
    public static let doc = TextFormat(id: "doc", title: "Word 97", textutilName: "doc", fileExtension: "doc",
                                       typeIdentifier: "com.microsoft.word.doc", isSecondary: true)
    public static let odt = TextFormat(id: "odt", title: "OpenDocument", textutilName: "odt", fileExtension: "odt",
                                       typeIdentifier: "org.oasis-open.opendocument.text", isSecondary: true)

    public static let all: [TextFormat] = [txt, rtf, html, docx, doc, odt]
}

/// Which files count as text documents (what `textutil` and the Cocoa text
/// system can read).
public enum TextDocuments {
    static let richTypes: [UTType] = [
        .rtf, .html, .webArchive,
        UTType("com.apple.rtfd"), UTType("com.apple.flat-rtfd"),
        UTType("com.microsoft.word.doc"), UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("org.oasis-open.opendocument.text"), UTType("com.microsoft.word.wordml"),
    ].compactMap { $0 }

    /// Plain text and Markdown count; source code and CSV don't.
    public static func isTextDocument(_ input: InputFile) -> Bool {
        let type = input.contentType
        if input.url.pathExtension.lowercased() == "rtfd" { return true }
        if richTypes.contains(where: type.conforms(to:)) { return true }
        return type.conforms(to: .plainText) && !type.conforms(to: .sourceCode)
            && !type.conforms(to: .delimitedText) && !type.conforms(to: .script)
    }
}

/// Text document → another text format with the system `textutil` tool,
/// in a subprocess (its HTML importer would otherwise need the main thread).
public struct TextDocumentConverter: Converter {
    public let format: TextFormat

    public init(_ format: TextFormat) {
        self.format = format
    }

    public var id: String { "document.\(format.id)" }
    public var title: String { format.title }
    public var role: ConverterRole { .format }
    public var isSecondary: Bool { format.isSecondary }
    public var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil") }

    public func accepts(_ input: InputFile) -> Bool {
        guard TextDocuments.isTextDocument(input) else { return false }
        if format == .txt { return !input.contentType.conforms(to: .plainText) }
        return input.contentType.identifier != format.typeIdentifier
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: format.fileExtension)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        var arguments = ["-convert", format.textutilName]
        if format == .txt || format == .html { arguments += ["-encoding", "UTF-8"] }
        arguments += ["-output", destination.path, input.url.path]
        try await Subprocess.run("/usr/bin/textutil", arguments)
    }
}

// MARK: - PDF

enum PDFFiles {
    static func isPDF(_ input: InputFile) -> Bool {
        !input.isDirectory && input.contentType.conforms(to: .pdf)
    }

    static func pageCount(_ url: URL) -> Int {
        CGPDFDocument(url as CFURL)?.numberOfPages ?? 0
    }
}

/// PDF → plain text with PDFKit. Scanned PDFs (images only) have no text.
public struct PDFTextConverter: Converter {
    public init() {}

    public var id: String { "pdf.txt" }
    public var title: String { "Plain Text" }
    public var role: ConverterRole { .format }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        PDFFiles.isPDF(input)
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: "txt")
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let document = PDFDocument(url: input.url) else { throw ConversionError.unreadableInput(input.url) }
        if document.isLocked { throw ConversionError.unsupported("\(input.url.lastPathComponent) is password-protected.") }
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            pages.append(document.page(at: index)?.string ?? "")
            progress(Double(index + 1) / Double(max(document.pageCount, 1)) * 0.95)
        }
        let text = pages.joined(separator: "\n\u{0C}\n") // form feed between pages
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.nothingToDo("\(input.url.lastPathComponent) has no text; it may be scanned pages.")
        }
        try Data(text.utf8).write(to: destination)
    }
}

/// PDF → one image per page, rendered with Core Graphics. A single page
/// becomes one file; several become a folder `name (pages)` of numbered images.
public struct PDFToImagesConverter: Converter {
    public let format: ImageFormat

    public init(_ format: ImageFormat) {
        self.format = format
    }

    public var id: String { "pdf.\(format.id)" }
    public var title: String { format.title }
    public var role: ConverterRole { .format }
    public var isSecondary: Bool { format != .png && format != .jpeg }
    public var isAvailable: Bool { format.isWritable }

    public func accepts(_ input: InputFile) -> Bool {
        PDFFiles.isPDF(input)
    }

    public func output(for input: InputFile) -> OutputSpec {
        PDFFiles.pageCount(input.url) > 1
            ? OutputSpec(fileExtension: "", nameSuffix: " (pages)", isDirectory: true)
            : OutputSpec(fileExtension: format.fileExtension)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let document = CGPDFDocument(input.url as CFURL) else { throw ConversionError.unreadableInput(input.url) }
        if !document.isUnlocked { throw ConversionError.unsupported("\(input.url.lastPathComponent) is password-protected.") }
        let count = document.numberOfPages
        guard count > 0 else { throw ConversionError.nothingToDo("\(input.url.lastPathComponent) has no pages.") }

        var targets: [URL] = []
        if count == 1 {
            targets = [destination]
        } else {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            let digits = String(count).count
            targets = (1...count).map { page in
                let number = String(repeating: "0", count: digits - String(page).count) + String(page)
                return destination.appendingPathComponent("\(input.baseName) \(number).\(format.fileExtension)")
            }
        }
        for (index, target) in targets.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: index + 1) else { continue }
            let image = try Self.render(page, dpi: options.pdfRenderDPI, opaque: !format.supportsAlpha)
            guard let file = CGImageDestinationCreateWithURL(target as CFURL, format.typeIdentifier as CFString, 1, nil) else {
                throw ConversionError.encoderFailed("this Mac can't write \(format.title)")
            }
            var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: options.pdfRenderDPI,
                                               kCGImagePropertyDPIHeight: options.pdfRenderDPI]
            if format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = options.imageQuality }
            CGImageDestinationAddImage(file, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(file) else { throw ConversionError.encoderFailed("couldn't write page \(index + 1)") }
            progress(Double(index + 1) / Double(count) * 0.95)
        }
    }

    /// Renders the page's crop box upright (honouring /Rotate) at `dpi`.
    static func render(_ page: CGPDFPage, dpi: Double, opaque: Bool) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((page.rotationAngle % 360) + 360) % 360
        let rotated = rotation == 90 || rotation == 270
        let scale = dpi / 72
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: ImageCodec.sRGB,
                                      bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)
        else { throw ConversionError.encoderFailed("couldn't allocate \(width)×\(height) pixels") }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // Turn the page so it reads upright, then move its crop box to the origin.
        switch rotation {
        case 90:
            context.translateBy(x: 0, y: size.height)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: size.width, y: size.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: size.width, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ConversionError.encoderFailed("couldn't render the page") }
        return image
    }
}

/// Every document and PDF converter, in menu order.
public enum DocumentConverters {
    // Typed in pieces, like ImageConverters.all, so older compilers check it quickly.
    public static let all: [any Converter] = {
        let text: [any Converter] = TextFormat.all.map { TextDocumentConverter($0) }
        let pdfText: [any Converter] = [PDFTextConverter()]
        let pdfImages: [any Converter] = [ImageFormat.png, .jpeg, .heic, .tiff].map { PDFToImagesConverter($0) }
        let tools: [any Converter] = [MergePDFsConverter(), SplitPDFConverter(), CompressPDFConverter(), RemovePDFMetadataConverter(),
                                      RecognizeTextConverter()]
        return text + pdfText + pdfImages + tools
    }()
}
