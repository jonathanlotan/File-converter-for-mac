import AppIntents
import AVFoundation
import ConverterCore
import UniformTypeIdentifiers
import XCTest
@testable import ConverterApp

/// The Shortcuts actions: what the conversion picker lists, that Convert
/// File saves beside the original and hands the result back, and that a
/// folder automation's mixed bag of files (its own results among them)
/// converts what it should and skips the rest.
final class IntentTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTemporaryFolder("Intents")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func outputs(of result: some IntentResult) throws -> [IntentFile] {
        try XCTUnwrap((result as? IntentResultContainer<[IntentFile], Never, Never, Never>)?.value, "no files returned")
    }

    func testTheQueryListsConversionsButNotTheCropEditor() async throws {
        let query = ConversionEntity.defaultQuery
        let found = try await query.entities(for: ["image.jpeg", "image.crop.custom", "image.resize.1920"])
        XCTAssertEqual(found.map(\.id), ["image.jpeg", "image.resize.1920"], "Crop › Custom… opens a window")

        let all = await IntentSupport.conversions().map(\.id)
        XCTAssertTrue(all.contains("image.jpeg"))
        XCTAssertFalse(all.contains("image.crop.custom"))
        XCTAssertTrue(all.contains("document.pdf"), "the app's own converters are listed too")
        XCTAssertEqual(all.count, Set(all).count, "ids are unique")

        let suggested = try await query.suggestedEntities().map(\.id)
        XCTAssertEqual(suggested.first, "image.jpeg")
        XCTAssertTrue(suggested.contains("image.stripMetadata"))
    }

    func testConversionsAreNamedWithTheirGroupAndKind() async throws {
        let query = ConversionEntity.defaultQuery
        let entities = try await query.entities(for: ["image.resize.1920", "image.crop.1x1", "video.compress", "image.jpeg"])
        XCTAssertEqual(entities.map(\.name), ["Resize › 1920 px", "Crop › Square", "Compress", "JPEG"])
        XCTAssertEqual(entities.map(\.kind), ["Images", "Images", "Video", "Images"])

        let matches = try await query.entities(matching: "square").map(\.id)
        XCTAssertEqual(matches, ["image.crop.1x1"])
    }

    func testConvertFileMakesAPNGBesideTheJPEGAndReturnsIt() async throws {
        let jpeg = try makeImage("photo.jpg", in: folder, type: "public.jpeg")
        let conversions = try await ConversionEntity.defaultQuery.entities(for: ["image.png"])
        let intent = ConvertFileIntent(files: [IntentFile(fileURL: jpeg.url)], conversion: try XCTUnwrap(conversions.first))

        let results = try outputs(of: try await intent.perform())

        XCTAssertEqual(try folderContents(folder), ["photo.jpg", "photo.png"])
        let output = try XCTUnwrap(results.first?.fileURL)
        XCTAssertEqual(output, folder.appendingPathComponent("photo.png").standardizedFileURL)
        XCTAssertEqual(try InputFile(url: output).image?.typeIdentifier, "public.png")
        XCTAssertEqual(results.first?.type?.identifier, "public.png")
    }

    private func conversion(_ id: String) async throws -> ConversionEntity {
        let found = try await ConversionEntity.defaultQuery.entities(for: [id])
        return try XCTUnwrap(found.first, "no \(id)")
    }

    private func notes() throws -> URL {
        let notes = folder.appendingPathComponent("notes.txt")
        try "hello".write(to: notes, atomically: true, encoding: .utf8)
        return notes
    }

    /// Fails the test unless `perform` throws exactly `message`.
    private func assertFails<Value>(_ message: String, _ perform: () async throws -> Value,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await perform()
            XCTFail("expected “\(message)”", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, message, file: file, line: line)
        }
    }

    func testAConversionThatAppliesToNoFileFailsWithTheConverterMessage() async throws {
        let intent = ConvertFileIntent(files: [IntentFile(fileURL: try notes())], conversion: try await conversion("image.png"))
        await assertFails("PNG can't be made from notes.txt.") { try await intent.perform() }
        XCTAssertEqual(try folderContents(folder), ["notes.txt"], "nothing written")
    }

    func testFilesTheConversionDoesNotApplyToAreSkipped() async throws {
        let jpeg = try makeImage("photo.jpg", in: folder, type: "public.jpeg")
        let intent = ConvertFileIntent(files: [IntentFile(fileURL: try notes()), IntentFile(fileURL: jpeg.url)],
                                       conversion: try await conversion("image.png"))

        let results = try outputs(of: try await intent.perform())

        XCTAssertEqual(results.map(\.fileURL?.lastPathComponent), ["photo.png"])
        XCTAssertEqual(try folderContents(folder), ["notes.txt", "photo.jpg", "photo.png"])
    }

    func testSwivelsOwnResultsAreNotConvertedAgain() async throws {
        // A folder automation: "when files are added, compress them". Each
        // result lands in the same folder and comes back as a new file.
        let jpeg = try makeNoisyJPEG("photo.jpg", in: folder)
        let compress = try await conversion("image.compress")
        let first = try outputs(of: try await ConvertFileIntent(files: [IntentFile(fileURL: jpeg.url)], conversion: compress).perform())
        let result = try XCTUnwrap(first.first?.fileURL)
        XCTAssertEqual(result.lastPathComponent, "photo (compressed).jpg")

        // Only its own result: nothing converted, and no error to notify about.
        let again1 = try outputs(of: try await ConvertFileIntent(files: [IntentFile(fileURL: result)], conversion: compress).perform())
        XCTAssertEqual(again1.count, 0)
        let again2 = try outputs(of: try await CompressIntent(files: [IntentFile(fileURL: result)]).perform())
        XCTAssertEqual(again2.count, 0)

        // The original added again: its result takes the next number, and is left alone in turn.
        let again = try outputs(of: try await CompressIntent(files: [IntentFile(fileURL: jpeg.url), IntentFile(fileURL: result)])
            .perform())
        let numbered = try XCTUnwrap(again.first?.fileURL)
        XCTAssertEqual(again.map(\.fileURL?.lastPathComponent), ["photo (compressed) 2.jpg"])
        let again3 = try outputs(of: try await CompressIntent(files: [IntentFile(fileURL: numbered)]).perform())
        XCTAssertEqual(again3.count, 0)

        // Only a conversion's own results: another tool still applies.
        let cleaned = try outputs(of: try await ConvertFileIntent(files: [IntentFile(fileURL: result)],
                                                                  conversion: try await conversion("image.stripMetadata")).perform())
        XCTAssertEqual(cleaned.map(\.fileURL?.lastPathComponent), ["photo (compressed) (no metadata).jpg"])
        XCTAssertEqual(try folderContents(folder),
                       ["photo (compressed) (no metadata).jpg", "photo (compressed) 2.jpg", "photo (compressed).jpg", "photo.jpg"])
    }

    func testAToolForSeveralFilesStillNeedsEnoughThatItAppliesTo() async throws {
        let png = try makeImage("shot.png", in: folder)
        let intent = ConvertFileIntent(files: [IntentFile(fileURL: png.url), IntentFile(fileURL: try notes())],
                                       conversion: try await conversion("image.combinePDF"))
        await assertFails("Combine into PDF needs at least 2 files.\nCombine into PDF doesn't apply to notes.txt.") {
            try await intent.perform()
        }
        XCTAssertEqual(try folderContents(folder), ["notes.txt", "shot.png"])
    }

    func testAListOfReasonsIsCutShort() {
        let reasons = (1...9).map { "Compress doesn't apply to \($0).txt." }
        XCTAssertEqual(IntentConversion.summary(Array(reasons.prefix(2))), reasons[0] + "\n" + reasons[1])
        let lines = IntentConversion.summary(reasons).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines.last, "…and 4 more.")
    }

    func testTheAppShortcutsPickTheToolForEachFile() async throws {
        // Noise saved at full quality, so Compress has something to take out
        // (it declines when the result isn't at least 5% smaller).
        let jpeg = try makeNoisyJPEG("photo.jpg", in: folder)
        let png = try makeImage("shot.png", in: folder)
        let wav = folder.appendingPathComponent("tone.wav")
        try writeTone(to: wav)

        let compressed = try outputs(of: try await CompressIntent(files: [jpeg.url, wav].map { IntentFile(fileURL: $0) }).perform())
        XCTAssertEqual(compressed.map(\.fileURL?.lastPathComponent), ["photo (compressed).jpg", "tone (compressed).m4a"])

        let jpegs = try outputs(of: try await ConvertToJPEGIntent(files: [IntentFile(fileURL: png.url)]).perform())
        XCTAssertEqual(jpegs.map(\.fileURL?.lastPathComponent), ["shot.jpg"])

        let pdfs = try outputs(of: try await ConvertToPDFIntent(files: [IntentFile(fileURL: png.url)]).perform())
        XCTAssertEqual(pdfs.map(\.fileURL?.lastPathComponent), ["shot.pdf"])

        let text = try notes()
        await assertFails("Compress doesn't apply to notes.txt.") {
            try await CompressIntent(files: [IntentFile(fileURL: text)]).perform()
        }
        let mixed = try outputs(of: try await CompressIntent(files: [IntentFile(fileURL: text), IntentFile(fileURL: wav)]).perform())
        XCTAssertEqual(mixed.map(\.fileURL?.lastPathComponent), ["tone (compressed) 2.m4a"], "the text file is skipped")
    }

    func testFilesWithoutALocationShareOneTemporaryFolder() async throws {
        let data = try Data(contentsOf: try makeImage("shot.png", in: folder).url)
        let file = { (name: String) in IntentFile(data: data, filename: name, type: .png) }

        let run = try IntentConversion.inputs(for: [file("shot.png"), file("shot.png")]).map(\.url)
        // Inputs' URLs are standardized; so is this, now that it exists.
        let parent = IntentConversion.temporaryFolder.standardizedFileURL.path
        let runFolder = run[0].deletingLastPathComponent()
        XCTAssertEqual(runFolder.deletingLastPathComponent().path, parent, "a folder for this run in Swivel Shortcuts")
        XCTAssertEqual(run.map(\.lastPathComponent), ["shot.png", "shot.png"], "both keep their name")
        XCTAssertNotEqual(run[0], run[1])
        XCTAssertTrue(run[1].path.hasPrefix(runFolder.path + "/"), "in the same run's folder")

        let next = try XCTUnwrap(try IntentConversion.inputs(for: [file("other.png")]).first?.url)
        XCTAssertEqual(next.deletingLastPathComponent().deletingLastPathComponent().path, parent)
        XCTAssertNotEqual(next.deletingLastPathComponent(), runFolder, "the next run gets its own")

        let jpegs = try outputs(of: try await ConvertToJPEGIntent(files: [file("shot.png")]).perform())
        let output = try XCTUnwrap(jpegs.first?.fileURL)
        XCTAssertEqual(output.lastPathComponent, "shot.jpg", "the result lands beside the copy")
        XCTAssertEqual(output.deletingLastPathComponent().deletingLastPathComponent().path, parent)

        // What the app does when it starts.
        IntentConversion.removeTemporaryFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent))
    }

    private func makeNoisyJPEG(_ name: String, in folder: URL) throws -> InputFile {
        let (width, height) = (600, 400)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 2041
        for i in stride(from: 0, to: pixels.count, by: 4) {
            for c in 0..<3 {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                pixels[i + c] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let url = folder.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                                   [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try InputFile(url: url)
    }

    func testThreeAppShortcutsAreDeclared() {
        // Their titles and phrases live in the extracted metadata, not on
        // AppShortcut; the build log's appintentsmetadataprocessor lists them.
        XCTAssertEqual(SwivelShortcuts.appShortcuts.count, 3)
    }

    /// One second of a 440 Hz stereo tone as 16-bit WAV: lossless, so
    /// Compress always applies.
    private func writeTone(to url: URL) throws {
        let rate = 44_100.0
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate)))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
            for i in 0..<Int(buffer.frameLength) { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / rate) * 0.4) }
        }
        try file.write(from: buffer)
    }
}
