import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// Files in Finder-like name order ("2" before "10"), so merged pages follow
/// the names rather than the order the files happened to be dragged in.
func inNameOrder(_ inputs: [InputFile]) -> [InputFile] {
    inputs.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
}

// MARK: - Merge

/// Two or more PDFs → one, in name order, named after the first.
public struct MergePDFsConverter: Converter {
    public init() {}

    public var id: String { "pdf.merge" }
    public var title: String { "Merge PDFs" }
    public var role: ConverterRole { .tool }
    public var combinesInputs: Bool { true }
    public var minimumInputs: Int { 2 }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        PDFFiles.isPDF(input)
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: "pdf", nameSuffix: " (merged)")
    }

    public func output(for inputs: [InputFile]) -> OutputSpec {
        OutputSpec(fileExtension: "pdf", nameSuffix: " (merged)", baseName: inNameOrder(inputs).first?.baseName)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        throw ConversionError.nothingToDo("Choose two or more PDFs to merge.")
    }

    public func convert(_ inputs: [InputFile], to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard inputs.count >= minimumInputs else { throw ConversionError.nothingToDo("Choose two or more PDFs to merge.") }
        let merged = PDFDocument()
        let ordered = inNameOrder(inputs)
        for (index, input) in ordered.enumerated() {
            try Task.checkCancellation()
            let document = try PDFFiles.open(input)
            for page in 0..<document.pageCount {
                // A page can only belong to one document.
                guard let copy = document.page(at: page)?.copy() as? PDFPage else { continue }
                merged.insert(copy, at: merged.pageCount)
            }
            progress(Double(index + 1) / Double(ordered.count) * 0.9)
        }
        guard merged.write(to: destination) else { throw ConversionError.encoderFailed("couldn't write the merged PDF") }
    }
}

// MARK: - Split

/// A PDF of several pages → a folder with one PDF per page.
public struct SplitPDFConverter: Converter {
    public init() {}

    public var id: String { "pdf.split" }
    public var title: String { "Split Pages" }
    public var role: ConverterRole { .tool }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        PDFFiles.isPDF(input) && PDFFiles.pageCount(input.url) > 1
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: "", nameSuffix: " (split)", isDirectory: true)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        let document = try PDFFiles.open(input)
        let count = document.pageCount
        guard count > 1 else { throw ConversionError.nothingToDo("\(input.url.lastPathComponent) has only one page.") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let digits = String(count).count
        for index in 0..<count {
            try Task.checkCancellation()
            guard let copy = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(copy, at: 0)
            let number = String(index + 1)
            let name = "\(input.baseName) \(String(repeating: "0", count: digits - number.count))\(number).pdf"
            guard single.write(to: destination.appendingPathComponent(name)) else {
                throw ConversionError.encoderFailed("couldn't write page \(index + 1)")
            }
            progress(Double(index + 1) / Double(count) * 0.95)
        }
    }
}

// MARK: - Compress

/// Rewrites a PDF with its images as JPEG at screen resolution (PDFKit,
/// macOS 13.4 and later). Text-only PDFs rarely shrink, so a result that
/// isn't smaller is reported instead of saved.
public struct CompressPDFConverter: Converter {
    public init() {}

    public var id: String { "pdf.compress" }
    public var title: String { "Compress" }
    public var role: ConverterRole { .tool }

    public var isAvailable: Bool {
        if #available(macOS 13.4, *) { return true }
        return false
    }

    public func accepts(_ input: InputFile) -> Bool {
        PDFFiles.isPDF(input)
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: "pdf", nameSuffix: " (compressed)")
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard #available(macOS 13.4, *) else { throw ConversionError.unsupported("Compressing PDFs needs macOS 13.4 or later.") }
        let document = try PDFFiles.open(input)
        let written = document.write(to: destination, withOptions: [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true,
        ])
        guard written else { throw ConversionError.encoderFailed("couldn't write the compressed PDF") }
        let before = (try? input.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if before > 0 && after >= before * 95 / 100 {
            throw ConversionError.nothingToDo("\(input.url.lastPathComponent) has little to compress; the result wasn't smaller.")
        }
    }
}

// MARK: - Remove metadata

/// Rewrites a PDF without its document information: title, author, subject,
/// keywords, the application that made it and its dates. The pages aren't
/// changed. (PDFKit records itself as the producer of the copy.)
public struct RemovePDFMetadataConverter: Converter {
    public init() {}

    public var id: String { "pdf.stripMetadata" }
    public var title: String { "Remove Metadata" }
    public var role: ConverterRole { .tool }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        PDFFiles.isPDF(input)
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: "pdf", nameSuffix: " (no metadata)")
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        let document = try PDFFiles.open(input)
        document.documentAttributes = [:]
        guard document.write(to: destination) else { throw ConversionError.encoderFailed("couldn't write the PDF") }
    }
}

// MARK: - Combine images

/// Two or more images → one PDF, a page per image in name order, each page
/// sized from the image's resolution (DPI).
public struct CombineImagesToPDFConverter: Converter {
    public init() {}

    public var id: String { "image.combinePDF" }
    public var title: String { "Combine into PDF" }
    public var role: ConverterRole { .tool }
    public var combinesInputs: Bool { true }
    public var minimumInputs: Int { 2 }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        input.image != nil
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: "pdf", nameSuffix: " (combined)")
    }

    public func output(for inputs: [InputFile]) -> OutputSpec {
        OutputSpec(fileExtension: "pdf", nameSuffix: " (combined)", baseName: inNameOrder(inputs).first?.baseName)
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        throw ConversionError.nothingToDo("Choose two or more images to combine.")
    }

    public func convert(_ inputs: [InputFile], to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        guard let context = CGContext(destination as CFURL, mediaBox: nil, [kCGPDFContextCreator: "Converter"] as CFDictionary) else {
            throw ConversionError.encoderFailed("couldn't create the PDF")
        }
        let ordered = inNameOrder(inputs)
        for (index, input) in ordered.enumerated() {
            try Task.checkCancellation()
            guard let info = input.image else { throw ConversionError.unreadableInput(input.url) }
            let source = try ImageCodec.openSource(input)
            let image = try ImageCodec.decode(source, index: info.primaryIndex)
            let props = ImageCodec.properties(source, info.primaryIndex)
            let dpiX = (props[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
            let dpiY = (props[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue ?? 72
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * 72 / (dpiX > 0 ? dpiX : 72),
                             height: Double(image.height) * 72 / (dpiY > 0 ? dpiY : 72))
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            context.endPage()
            progress(Double(index + 1) / Double(ordered.count) * 0.95)
        }
        context.closePDF()
    }
}

// MARK: - Recognize text (OCR)

/// Image or PDF → plain text, recognised on this Mac with Vision. Nothing
/// leaves the computer.
public struct RecognizeTextConverter: Converter {
    public init() {}

    public var id: String { "ocr.text" }
    public var title: String { "Recognize Text" }
    public var role: ConverterRole { .tool }
    public var isAvailable: Bool { true }

    public func accepts(_ input: InputFile) -> Bool {
        input.image != nil || PDFFiles.isPDF(input)
    }

    public func output(for input: InputFile) -> OutputSpec {
        OutputSpec(fileExtension: "txt", nameSuffix: " (text)")
    }

    public func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        var pages: [String] = []
        if let info = input.image {
            let source = try ImageCodec.openSource(input)
            pages = [try Self.recognize(ImageCodec.decode(source, index: info.primaryIndex))]
        } else {
            guard let document = CGPDFDocument(input.url as CFURL) else { throw ConversionError.unreadableInput(input.url) }
            for number in 1...max(document.numberOfPages, 1) {
                try Task.checkCancellation()
                guard let page = document.page(at: number) else { continue }
                pages.append(try Self.recognize(PDFToImagesConverter.render(page, dpi: 200, opaque: true)))
                progress(Double(number) / Double(document.numberOfPages) * 0.95)
            }
        }
        let text = pages.joined(separator: "\n\u{0C}\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversionError.nothingToDo("No text found in \(input.url.lastPathComponent).")
        }
        try Data(text.utf8).write(to: destination)
    }

    /// Lines of text, top to bottom.
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = (request.results ?? []).sorted {
            // Vision's origin is bottom-left: higher lines first, then left to right.
            abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                ? $0.boundingBox.midY > $1.boundingBox.midY
                : $0.boundingBox.minX < $1.boundingBox.minX
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}

extension PDFFiles {
    static func open(_ input: InputFile) throws -> PDFDocument {
        guard let document = PDFDocument(url: input.url) else { throw ConversionError.unreadableInput(input.url) }
        if document.isLocked { throw ConversionError.unsupported("\(input.url.lastPathComponent) is password-protected.") }
        return document
    }
}
