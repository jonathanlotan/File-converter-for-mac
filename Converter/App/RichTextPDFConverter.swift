import AppKit
import ConverterCore
import UniformTypeIdentifiers

/// Text document (TXT, Markdown, RTF, HTML, Word, OpenDocument) → PDF.
///
/// Reading rich text into `NSAttributedString` and laying it out in pages
/// needs AppKit's text system, so this converter lives in the app rather
/// than in ConverterCore. Every input is first turned into RTFD with the
/// system `textutil` tool in a subprocess, so the HTML importer (which
/// needs the main thread) never runs here, and images survive.
struct RichTextPDFConverter: Converter {
    var id: String { "document.pdf" }
    var title: String { "PDF" }
    var role: ConverterRole { .format }
    var isAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/textutil") }

    func accepts(_ input: InputFile) -> Bool {
        TextDocuments.isTextDocument(input)
    }

    func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: "pdf")
    }

    func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        let rtfd = destination.deletingLastPathComponent().appendingPathComponent("text-\(UUID().uuidString).rtfd")
        defer { try? FileManager.default.removeItem(at: rtfd) }
        try await Subprocess.run("/usr/bin/textutil", ["-convert", "rtfd", "-output", rtfd.path, input.url.path])
        progress(0.3)
        try Task.checkCancellation()

        let text = try NSAttributedString(url: rtfd, options: [.documentType: NSAttributedString.DocumentType.rtfd],
                                          documentAttributes: nil)
        try RichTextPDF.write(text, to: destination, pageSize: RichTextPDF.defaultPageSize)
    }
}

enum RichTextPDF {
    /// US Letter where the region measures in inches, A4 elsewhere.
    static var defaultPageSize: CGSize {
        Locale.current.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
    }

    /// Lays `text` out on pages with one-inch margins and writes a PDF.
    /// TextKit is used from this thread only, which is safe off the main thread.
    static func write(_ text: NSAttributedString, to url: URL, pageSize: CGSize, margin: CGFloat = 72) throws {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let contentSize = CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)

        var pages: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            pages.append(container)
        } while NSMaxRange(layout.glyphRange(for: pages[pages.count - 1])) < layout.numberOfGlyphs && pages.count < 10_000

        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextCreator: "Converter"] as CFDictionary) else {
            throw ConversionError.encoderFailed("couldn't create the PDF")
        }
        // Resolve dynamic colours (text without an explicit colour) as on
        // paper, even when the Mac is in dark mode.
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            for page in pages {
                context.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                // TextKit draws top-down.
                context.translateBy(x: 0, y: pageSize.height)
                context.scaleBy(x: 1, y: -1)
                let range = layout.glyphRange(for: page)
                let origin = CGPoint(x: margin, y: margin)
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
                NSGraphicsContext.restoreGraphicsState()
                context.endPDFPage()
            }
        }
        context.closePDF()
    }
}
