import AppIntents
import ConverterCore
import XCTest
@testable import ConverterApp

/// The Shortcuts actions: what the conversion picker lists, and that Convert
/// File saves beside the original and hands the result back.
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

    func testAConversionThatDoesNotApplyFailsWithTheConverterMessage() async throws {
        let notes = folder.appendingPathComponent("notes.txt")
        try "hello".write(to: notes, atomically: true, encoding: .utf8)
        let conversions = try await ConversionEntity.defaultQuery.entities(for: ["image.png"])
        let intent = ConvertFileIntent(files: [IntentFile(fileURL: notes)], conversion: try XCTUnwrap(conversions.first))

        do {
            _ = try await intent.perform()
            XCTFail("a text file can't become a PNG")
        } catch {
            XCTAssertEqual(error.localizedDescription, "PNG can't be made from notes.txt.")
        }
        XCTAssertEqual(try folderContents(folder), ["notes.txt"], "nothing written")
    }

    func testTheAppShortcutsPickTheToolForEachFile() async throws {
        let jpeg = try makeImage("photo.jpg", in: folder, width: 1200, height: 800, type: "public.jpeg")
        let png = try makeImage("shot.png", in: folder)

        let compressed = try outputs(of: try await CompressIntent(files: [IntentFile(fileURL: jpeg.url)]).perform())
        XCTAssertEqual(compressed.map(\.fileURL?.lastPathComponent), ["photo (compressed).jpg"])

        let jpegs = try outputs(of: try await ConvertToJPEGIntent(files: [IntentFile(fileURL: png.url)]).perform())
        XCTAssertEqual(jpegs.map(\.fileURL?.lastPathComponent), ["shot.jpg"])

        let pdfs = try outputs(of: try await ConvertToPDFIntent(files: [IntentFile(fileURL: png.url)]).perform())
        XCTAssertEqual(pdfs.map(\.fileURL?.lastPathComponent), ["shot.pdf"])

        let notes = folder.appendingPathComponent("notes.txt")
        try "hello".write(to: notes, atomically: true, encoding: .utf8)
        do {
            _ = try await CompressIntent(files: [IntentFile(fileURL: notes)]).perform()
            XCTFail("nothing compresses a text file")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Compress doesn't apply to notes.txt.")
        }
    }

    func testThreeAppShortcutsAreDeclared() {
        // Their titles and phrases live in the extracted metadata, not on
        // AppShortcut; the build log's appintentsmetadataprocessor lists them.
        XCTAssertEqual(SwivelShortcuts.appShortcuts.count, 3)
    }
}
