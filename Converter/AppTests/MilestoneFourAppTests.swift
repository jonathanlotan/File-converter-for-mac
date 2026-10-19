import AppKit
import ConverterCore
import PDFKit
import XCTest
@testable import ConverterApp

final class RichTextPDFTests: XCTestCase {
    var folder: URL!
    let phrase = "Converter sample document"

    override func setUpWithError() throws {
        folder = try makeTemporaryFolder("RichTextPDF")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func document(_ ext: String, text: String) async throws -> InputFile {
        let txt = folder.appendingPathComponent("source-\(ext).txt")
        try text.write(to: txt, atomically: true, encoding: .utf8)
        if ext == "txt" { return try InputFile(url: txt) }
        let url = folder.appendingPathComponent("sample.\(ext)")
        try await Subprocess.run("/usr/bin/textutil", ["-convert", ext, "-output", url.path, txt.path])
        return try InputFile(url: url)
    }

    func testEveryTextFormatBecomesAPDFWithItsText() async throws {
        for ext in ["txt", "rtf", "html", "docx", "doc", "odt"] {
            let input = try await document(ext, text: "\(phrase)\n\nSecond paragraph.\n")
            XCTAssertTrue(RichTextPDFConverter().accepts(input), ext)
            let output = try await JobRunner.run(RichTextPDFConverter(), on: input)
            let pdf = try XCTUnwrap(PDFDocument(url: output), ext)
            XCTAssertEqual(pdf.pageCount, 1, ext)
            XCTAssertTrue(pdf.string?.contains(phrase) ?? false, "\(ext): text missing")
            let size = try XCTUnwrap(pdf.page(at: 0)?.bounds(for: .mediaBox).size)
            XCTAssertEqual(size, RichTextPDF.defaultPageSize, ext)
        }
    }

    func testLongDocumentsFlowOntoSeveralPages() async throws {
        let paragraph = String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 12)
        let body = (1...60).map { "Paragraph \($0). \(paragraph)" }.joined(separator: "\n\n")
        let output = try await JobRunner.run(RichTextPDFConverter(), on: try await document("rtf", text: body))
        let pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertGreaterThan(pdf.pageCount, 5)
        // Page breaks depend on the paper size (A4 or US Letter, from the
        // region), so check the whole text and how the last page ends.
        XCTAssertTrue(pdf.string?.contains("Paragraph 60.") ?? false, "the last paragraph is missing")
        let lastPage = pdf.page(at: pdf.pageCount - 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        XCTAssertTrue(lastPage.hasSuffix("adipiscing elit."), "nothing lost at the end: …\(lastPage.suffix(80))")
    }

    func testTheAppRegistryOffersPDFForDocuments() async throws {
        let appRegistry = await MainActor.run { (NSApp.delegate as? AppDelegate)?.registry }
        let registry = try XCTUnwrap(appRegistry, "tests run inside the app")
        let input = try await document("rtf", text: phrase)
        let model = ConversionMenuModel(converters: registry.converters(for: [input]))
        let titles = model.formats.compactMap { entry -> String? in
            if case .converter(let converter) = entry { return converter.title }
            return nil
        }
        XCTAssertEqual(titles, ["Plain Text", "HTML", "Word", "PDF"])
    }
}

final class MilestoneFourQueueTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTemporaryFolder("QueueM4")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    func testSeveralFilesMakeOneArchiveJob() async throws {
        let queue = JobQueue()
        let inputs = try (1...3).map { try makeImage("p\($0).png", in: folder) }
        let zip = try XCTUnwrap(ConverterRegistry.standard.converter(id: "archive.create.zip"))
        XCTAssertEqual(OutputPreview.name(of: zip, for: inputs), "Archive.zip")

        let jobs = queue.enqueue(zip, on: inputs)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].title, "3 files → ZIP")
        try await waitUntilIdle(queue)
        XCTAssertEqual(jobs[0].state, .succeeded(folder.appendingPathComponent("Archive.zip")))
    }

    @MainActor
    func testVideoJobsRunOneAtATime() async throws {
        let queue = JobQueue(maxConcurrent: 2)
        let gate = Gate()
        let inputs = try (1...2).map { try makeImage("v\($0).png", in: folder) }
        let videos = queue.enqueue(GatedConverter(gate: gate, id: "video.test"), on: inputs)
        let other = queue.enqueue(GatedConverter(gate: gate), on: [try makeImage("x.png", in: folder)])

        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(videos.map(\.state), [.running, .queued], "a second video waits")
        XCTAssertEqual(other[0].state, .running, "a non-video job uses the free slot")

        gate.openGate()
        try await waitUntilIdle(queue)
        XCTAssertEqual(gate.startCount, 3)
    }
}

final class MilestoneFourMenuTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTemporaryFolder("MenuM4")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func titles(_ entries: [ConversionMenuModel.Entry]) -> [String] {
        entries.map { entry in
            switch entry {
            case .converter(let converter): return converter.title
            case .group(let title, let members): return "\(title): " + members.map(\.title).joined(separator: ", ")
            }
        }
    }

    func testAFolderOffersArchiveFormatsDirectly() throws {
        let sub = folder.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let input = try InputFile(url: sub)
        let model = ConversionMenuModel(converters: ConverterRegistry.standard.converters(for: [input]))
        XCTAssertTrue(model.formats.isEmpty)
        XCTAssertEqual(titles(model.tools), ["ZIP", "TAR.GZ", "TAR.XZ", "7Z", "Apple Archive"])
    }

    func testAVideoGroupsItsSoundAndExtraFormats() throws {
        let movie = folder.appendingPathComponent("clip.mov")
        try Data().write(to: movie) // the menu only looks at the type
        let model = ConversionMenuModel(converters: ConverterRegistry.standard.converters(for: [try InputFile(url: movie)]))
        XCTAssertEqual(titles(model.formats), [
            "MP4", "MP4 (HEVC)", "MOV", "GIF", "Audio: M4A, WAV, AIFF, FLAC", "More Formats: MOV (ProRes), M4V",
        ])
        XCTAssertEqual(titles(model.tools), ["Save Frame", "Compress", "Resize: 4K, 1080p, 720p, 540p", "Remove Audio",
                                             "Remove Metadata", "Archive: ZIP, TAR.GZ, TAR.XZ, 7Z, Apple Archive"])
    }
}
