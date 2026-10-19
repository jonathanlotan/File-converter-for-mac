import AVFoundation
import ImageIO
import PDFKit
import XCTest
@testable import ConverterCore

/// The file tools on input they should really change: a noisy high-bit-rate
/// clip to compress, a 720p clip to shrink, PDFs to merge, images to
/// combine, an image-heavy PDF to compress, and text to recognise.
final class FileToolTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = try makeTemporaryFolder("FileTools")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func converter(_ id: String) throws -> any Converter {
        try XCTUnwrap(ConverterRegistry.standard.converter(id: id), "missing \(id)")
    }

    private func size(_ url: URL) throws -> Int {
        try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    // MARK: Video

    func testCompressingANoisyClipMakesASmallerHEVCFile() async throws {
        let clip = folder.appendingPathComponent("noisy.mov")
        try await MediaSamples.writeVideo(to: clip, width: 640, height: 360, seconds: 2, noisy: true)
        let output = try await JobRunner.run(converter("video.compress"), on: InputFile(url: clip),
                                             options: ConversionOptions(videoCompression: .smaller))
        XCTAssertEqual(output.lastPathComponent, "noisy (compressed).mp4")
        XCTAssertLessThan(try size(output), try size(clip) / 2)

        let track = try await XCTUnwrapAsync(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let description = try await XCTUnwrapAsync(try await track.load(.formatDescriptions).first)
        XCTAssertEqual(fourCC(CMFormatDescriptionGetMediaSubType(description)), "hvc1")
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.1)
    }

    func testBitRateScalesWithSizeFrameRateAndLevel() {
        let balanced = CompressVideoConverter.bitRate(width: 1920, height: 1080, fps: 30, level: .balanced)
        XCTAssertEqual(balanced, 3_110_400)
        XCTAssertLessThan(CompressVideoConverter.bitRate(width: 1920, height: 1080, fps: 30, level: .smaller), balanced)
        XCTAssertGreaterThan(CompressVideoConverter.bitRate(width: 1920, height: 1080, fps: 30, level: .better), balanced)
        XCTAssertEqual(CompressVideoConverter.bitRate(width: 16, height: 16, fps: 1, level: .smaller), 250_000, "floor")
    }

    func testResizingA720pClipTo540p() async throws {
        let clip = folder.appendingPathComponent("hd.mov")
        try await MediaSamples.writeVideo(to: clip, width: 1280, height: 720, seconds: 1)
        let input = try InputFile(url: clip)
        let output = try await JobRunner.run(converter("video.resize.540"), on: input)
        XCTAssertEqual(output.lastPathComponent, "hd (540p).mp4")
        let track = try await XCTUnwrapAsync(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 960, height: 540))

        do {
            try await JobRunner.run(converter("video.resize.1080"), on: input)
            XCTFail("1080p must not enlarge a 720p clip")
        } catch {
            XCTAssertEqual(error.localizedDescription, "hd.mov is already 1080p or smaller.")
        }
    }

    func testResizeOffersOnlySmallerSizes() {
        XCTAssertTrue(ResizeVideoConverter.shrinks(shortSide: 1080, to: 720))
        XCTAssertFalse(ResizeVideoConverter.shrinks(shortSide: 720, to: 720), "never the same size")
        XCTAssertFalse(ResizeVideoConverter.shrinks(shortSide: 540, to: 1080), "never larger")
        XCTAssertTrue(ResizeVideoConverter.shrinks(shortSide: nil, to: 2160), "offered while the size isn't known")
    }

    // MARK: PDF

    func testMergingPDFsInNameOrder() async throws {
        let one = folder.appendingPathComponent("part 2.pdf"), two = folder.appendingPathComponent("part 10.pdf")
        try MediaSamples.writePDF(to: one, pages: 1)
        try MediaSamples.writePDF(to: two, pages: 3)
        let inputs = [try InputFile(url: two), try InputFile(url: one)] // dragged out of order
        let merge = try converter("pdf.merge")
        XCTAssertFalse(ConverterRegistry.standard.converters(for: [inputs[0]]).contains { $0.id == "pdf.merge" },
                       "one PDF can't be merged")
        XCTAssertTrue(ConverterRegistry.standard.converters(for: inputs).contains { $0.id == "pdf.merge" })

        let output = try await JobRunner.runCombined(merge, on: inputs)
        XCTAssertEqual(output.lastPathComponent, "part 2 (merged).pdf", "named after the first in name order")
        let pdf = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(pdf.pageCount, 4)
        XCTAssertEqual(pdf.page(at: 1)?.string?.contains("Page 1"), true, "part 10's pages come after part 2")
    }

    func testCompressingAnImageHeavyPDF() async throws {
        let pdf = folder.appendingPathComponent("scan.pdf")
        try MediaSamples.writeImagePDF(to: pdf)
        let output = try await JobRunner.run(converter("pdf.compress"), on: InputFile(url: pdf))
        XCTAssertEqual(output.lastPathComponent, "scan (compressed).pdf")
        XCTAssertLessThan(try size(output), try size(pdf))
        XCTAssertEqual(PDFFiles.pageCount(output), 1)
    }

    // MARK: Images

    func testCombiningImagesIntoOnePDF() async throws {
        let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("b.png")
        try Samples.write([Samples.testCard()], type: "public.png", to: a)
        try Samples.write([Samples.testCard(width: 600, height: 300)], type: "public.png", to: b,
                          frameProperties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
        let output = try await JobRunner.runCombined(converter("image.combinePDF"), on: [InputFile(url: b), InputFile(url: a)])
        XCTAssertEqual(output.lastPathComponent, "a (combined).pdf")
        let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 2)
        XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 320, height: 200))
        XCTAssertEqual(pdf.page(at: 2)?.getBoxRect(.mediaBox).size, CGSize(width: 300, height: 150), "144 dpi halves the size")
    }

    func testRecognizingTextInAnImage() async throws {
        let url = folder.appendingPathComponent("sign.png")
        try Samples.write([MediaSamples.textImage("Converter reads this")], type: "public.png", to: url)
        let output = try await JobRunner.run(converter("ocr.text"), on: InputFile(url: url))
        XCTAssertEqual(output.lastPathComponent, "sign (text).txt")
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("Converter reads this"))
    }

    func testAnImageWithoutTextSaysSo() async throws {
        let url = folder.appendingPathComponent("card.png")
        try Samples.write([Samples.testCard()], type: "public.png", to: url)
        do {
            try await JobRunner.run(converter("ocr.text"), on: InputFile(url: url))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No text found in card.png.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["card.png"])
    }
}

/// XCTUnwrap for values produced by an `await`.
func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}
