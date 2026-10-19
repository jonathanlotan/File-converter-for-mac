import AVFoundation
import ImageIO
import PDFKit
import XCTest
@testable import ConverterCore

/// The file tools on input they should really change: a noisy high-bit-rate
/// clip to compress, a 720p clip to shrink, a tagged clip to clean, PDFs to
/// merge, a tagged PDF to clean, lossless sound to compress, images to
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

    func testRemovingVideoMetadataKeepsThePictureSoundAndOrientation() async throws {
        // A portrait clip (stored 320×240, rotated to show as 240×320) with sound.
        let silent = folder.appendingPathComponent("silent.mov"), tone = folder.appendingPathComponent("tone.wav")
        let aac = folder.appendingPathComponent("tone.m4a")
        try await MediaSamples.writeVideo(to: silent, width: 320, height: 240, seconds: 2,
                                          transform: CGAffineTransform(rotationAngle: .pi / 2))
        try MediaSamples.writeTone(to: tone, seconds: 2, bits: 16)
        try await Subprocess.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", tone.path, aac.path])
        let clip = folder.appendingPathComponent("IMG_0042.mp4")
        try await MediaSamples.mux(video: silent, audio: aac, to: clip, fileType: .mp4,
                                   metadata: MediaSamples.recorderMetadata())
        let before = await sections(clip)
        XCTAssertEqual(before["Details"]?["Location"]?.hasPrefix("+32.0800+034.7800"), true, "the fixture carries a location")
        XCTAssertEqual(before["Details"]?["Title"], "Beach")
        XCTAssertEqual(before["Video"]?["Dimensions"], "240 × 320 pixels")
        let tagged = try await AVURLAsset(url: clip).load(.metadata).map { $0.identifier?.rawValue ?? "?" }
        XCTAssertEqual(tagged.sorted(), ["uiso/date", "uiso/loci", "uiso/titl"], "MP4 keeps the tags it has ISO forms for")

        let output = try await JobRunner.run(converter("video.stripMetadata"), on: InputFile(url: clip))
        XCTAssertEqual(output.lastPathComponent, "IMG_0042 (no metadata).mp4", "same container")
        let after = await sections(output)
        XCTAssertNil(after["Details"], "no title, location, date, make or model left: \(after["Details"]?.fields ?? [])")
        XCTAssertEqual(after["Media"]?["Duration"], "0:02")
        XCTAssertEqual(after["Video"]?["Dimensions"], "240 × 320 pixels", "still upright")
        XCTAssertEqual(after["Video"]?["Codec"], "H.264", "not re-encoded")
        XCTAssertEqual(after["Audio"]?["Codec"], "AAC", "sound copied as it was")

        let items = try await AVURLAsset(url: output).load(.metadata)
        XCTAssertTrue(items.isEmpty, "nothing left at all: \(items.map { $0.identifier?.rawValue ?? "?" })")

        // A MOV keeps the whole QuickTime set (com.apple.quicktime.*), make and model included.
        let mov = folder.appendingPathComponent("phone.mov")
        try await MediaSamples.writeVideo(to: mov, width: 64, height: 48, seconds: 1, metadata: MediaSamples.recorderMetadata())
        let movTags = try await AVURLAsset(url: mov).load(.metadata).map { $0.identifier?.rawValue ?? "?" }
        XCTAssertTrue(movTags.contains("mdta/com.apple.quicktime.make"), "\(movTags)")
        XCTAssertTrue(movTags.contains("mdta/com.apple.quicktime.location.ISO6709"), "\(movTags)")
        let cleaned = try await JobRunner.run(converter("video.stripMetadata"), on: InputFile(url: mov))
        XCTAssertEqual(cleaned.lastPathComponent, "phone (no metadata).mov")
        let left = try await AVURLAsset(url: cleaned).load(.metadata)
        XCTAssertTrue(left.isEmpty, "\(left.map { $0.identifier?.rawValue ?? "?" })")
        let cleanedInfo = await sections(cleaned)
        XCTAssertNil(cleanedInfo["Details"])
        XCTAssertEqual(cleanedInfo["Video"]?["Dimensions"], "64 × 48 pixels")
    }

    private func sections(_ url: URL) async -> [String: MetadataSection] {
        Dictionary(uniqueKeysWithValues: await FileMetadata.sections(for: url).map { ($0.title, $0) })
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

    func testRemovingPDFMetadataKeepsThePages() async throws {
        let pdf = folder.appendingPathComponent("report.pdf")
        try MediaSamples.writePDF(to: pdf, pages: 3, info: [
            kCGPDFContextTitle: "Quarterly Report", kCGPDFContextAuthor: "Sam", kCGPDFContextSubject: "Numbers",
            kCGPDFContextKeywords: ["finance", "q3"], kCGPDFContextCreator: "Spreadsheets 2.0",
        ])
        let before = await sections(pdf)["PDF"]
        XCTAssertEqual(before?["Title"], "Quarterly Report", "the fixture is tagged")
        XCTAssertEqual(before?["Keywords"], "finance, q3")

        let output = try await JobRunner.run(converter("pdf.stripMetadata"), on: InputFile(url: pdf))
        XCTAssertEqual(output.lastPathComponent, "report (no metadata).pdf")
        let pdfSection = await sections(output)["PDF"]
        let after = try XCTUnwrap(pdfSection)
        XCTAssertEqual(after["Pages"], "3")
        for label in ["Title", "Author", "Subject", "Keywords", "Application"] {
            XCTAssertNil(after[label], "\(label) should be gone: \(after.fields)")
        }
        XCTAssertEqual(try XCTUnwrap(PDFDocument(url: output)).page(at: 2)?.string?.contains("Page 3"), true, "text intact")
    }

    func testCompressingAnImageHeavyPDF() async throws {
        let pdf = folder.appendingPathComponent("scan.pdf")
        try MediaSamples.writeImagePDF(to: pdf)
        let output = try await JobRunner.run(converter("pdf.compress"), on: InputFile(url: pdf))
        XCTAssertEqual(output.lastPathComponent, "scan (compressed).pdf")
        XCTAssertLessThan(try size(output), try size(pdf))
        XCTAssertEqual(PDFFiles.pageCount(output), 1)
    }

    // MARK: Audio

    func testCompressingLosslessAudioMakesASmallerM4A() async throws {
        let wav = folder.appendingPathComponent("wav/music.wav"), flac = folder.appendingPathComponent("flac/music.flac")
        for url in [wav, flac] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try MediaSamples.writeTone(to: wav, seconds: 4, bits: 24, noisy: true)
        try await Subprocess.run("/usr/bin/afconvert", ["-f", "flac", "-d", "flac", wav.path, flac.path])
        let compress = try converter("audio.compress")
        let options = ConversionOptions(compressionAudioBitRate: 96)

        for source in [wav, flac] {
            let input = try InputFile(url: source)
            XCTAssertTrue(compress.accepts(input), "\(source.lastPathComponent) is lossless, so always offered")
            let output = try await JobRunner.run(compress, on: input, options: options)
            XCTAssertEqual(output.lastPathComponent, "music (compressed).m4a", source.lastPathComponent)
            XCTAssertLessThan(try size(output), try size(source) / 2, source.lastPathComponent)
            let info = try XCTUnwrap(AudioInfo(url: output))
            XCTAssertEqual(fourCC(info.formatID), "aac ")
            XCTAssertEqual(info.channels, 2)
            XCTAssertEqual(info.duration, 4, accuracy: 0.02, "exact length kept")
            // The file's rate: the sound at 96 kbit/s plus a small header.
            let rate = Double(try size(output)) * 8 / info.duration / 1000
            XCTAssertEqual(rate, 100, accuracy: 12, "\(source.lastPathComponent) → about 96 kbit/s, got \(rate)")
        }
    }

    func testCompressIsOnlyOfferedAboveTheTargetRate() async throws {
        let wav = folder.appendingPathComponent("tone.wav")
        try MediaSamples.writeTone(to: wav, seconds: 4, bits: 16)
        // Constant bit rate (-s 0), so the files really are 256 and 96 kbit/s.
        let high = folder.appendingPathComponent("high.m4a"), low = folder.appendingPathComponent("low.m4a")
        try await Subprocess.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-s", "0", "-b", "256000", wav.path, high.path])
        try await Subprocess.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-s", "0", "-b", "96000", wav.path, low.path])
        let ids = { (url: URL) throws in ConverterRegistry.standard.converters(for: [try InputFile(url: url)]).map(\.id) }
        XCTAssertTrue(try ids(high).contains("audio.compress"), "256 kbit/s AAC can shrink to 128")
        XCTAssertFalse(try ids(low).contains("audio.compress"), "96 kbit/s AAC is already below 128")

        let output = try await JobRunner.run(converter("audio.compress"), on: InputFile(url: high))
        XCTAssertLessThan(try size(output), try size(high) * 2 / 3)

        do {
            // The menu went by the standard 128; the setting may say otherwise.
            try await JobRunner.run(converter("audio.compress"), on: InputFile(url: high),
                                    options: ConversionOptions(compressionAudioBitRate: 256))
            XCTFail("a 256 kbit/s file can't shrink to 256 kbit/s")
        } catch {
            XCTAssertEqual(error.localizedDescription, "high.m4a is already at 256 kbit/s or less.")
        }
        XCTAssertEqual(try folderContents(folder), ["high (compressed).m4a", "high.m4a", "low.m4a", "tone.wav"])
    }

    func testShrinkEstimateUsesSizeAndLength() {
        let shrinks = { (seconds: Double, bytes: Int, kbps: Int) in
            CompressAudioConverter.shrinks(format: kAudioFormatMPEG4AAC, channels: 2, seconds: seconds, bytes: bytes, to: kbps)
        }
        XCTAssertTrue(CompressAudioConverter.shrinks(format: kAudioFormatFLAC, channels: 2, seconds: 10, bytes: 100, to: 128),
                      "lossless always shrinks")
        // 10 s at 320 kbit/s is 400 000 bytes.
        XCTAssertTrue(shrinks(10, 400_000, 128))
        XCTAssertFalse(shrinks(10, 165_000, 128), "128 kbit/s plus its container's overhead")
        XCTAssertFalse(shrinks(10, 120_000, 128))
        XCTAssertTrue(shrinks(10, 120_000, 64), "but it would shrink to 64")
        XCTAssertFalse(CompressAudioConverter.shrinks(format: kAudioFormatMPEG4AAC, channels: 1, seconds: 10, bytes: 80_000, to: 128),
                       "mono is encoded at half the rate")
        XCTAssertTrue(shrinks(0, 120_000, 128), "offered while the length isn't known")
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
