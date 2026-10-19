import AppKit
import ConverterCore
import XCTest
@testable import ConverterApp

final class ConversionMenuModelTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTemporaryFolder("Menu")
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

    func testJPEGLayout() throws {
        let input = try makeImage("photo.jpg", in: folder, width: 2000, height: 1000, type: "public.jpeg")
        let model = ConversionMenuModel(converters: ConverterRegistry.standard.converters(for: [input]))

        let formats = titles(model.formats)
        XCTAssertEqual(formats.first, "PNG", "JPEG itself isn't offered")
        XCTAssertFalse(formats.contains("JPEG"))
        XCTAssertEqual(formats.last, "More Formats: BMP, JPEG 2000, ICNS, ICO, PSD, TGA")

        XCTAssertEqual(titles(model.tools), [
            "Resize: 50%, 25%, 1920 px, 1280 px, 640 px",
            "Crop: Square, 4:3, 3:2, 16:9, 3:4, 2:3, 9:16",
            "Compress",
            "Remove Metadata",
            "Recognize Text",
            "Archive: ZIP, TAR.GZ, TAR.XZ, 7Z, Apple Archive",
        ])
    }

    @MainActor
    func testMenuItemsAndTooltipShowTheNextFreeName() throws {
        let input = try makeImage("photo.png", in: folder)
        try Data().write(to: folder.appendingPathComponent("photo.jpg"))
        var picked: [String] = []
        let menu = ConversionMenu.make(for: [input], converters: ConverterRegistry.standard.converters(for: [input])) {
            picked.append($0.id)
        }

        XCTAssertEqual(menu.items.first?.title, "Convert “photo.png”")
        XCTAssertTrue(menu.items.first?.isSectionHeader ?? false, "a section header, not a choice")
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).map(\.title), ["Convert “photo.png”", "Tools"])
        let jpeg = try XCTUnwrap(menu.items.first { $0.title == "JPEG" })
        XCTAssertEqual(jpeg.toolTip, "Saves “photo 2.jpg” next to the original")
        let more = try XCTUnwrap(menu.items.first { $0.title == "More Formats" }?.submenu)
        XCTAssertTrue(more.items.map(\.title).contains("ICO"))

        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex(of: jpeg)))
        XCTAssertEqual(picked, ["image.jpeg"])
    }

    @MainActor
    func testFilesWithNothingInCommonSaySo() throws {
        // Every file can be archived except an archive, and an archive can
        // only be extracted or converted: a PNG and a RAR share nothing.
        let rar = folder.appendingPathComponent("old.rar")
        try Data("not really".utf8).write(to: rar)
        let inputs = [try makeImage("photo.png", in: folder), try InputFile(url: rar)]
        let menu = ConversionMenu.make(for: inputs, converters: ConverterRegistry.standard.converters(for: inputs)) { _ in }
        XCTAssertEqual(menu.items.map(\.title), ["Convert 2 files", "No conversion works for all of these files"])
        XCTAssertTrue(menu.items[0].isSectionHeader)
        XCTAssertFalse(menu.items[1].isEnabled, "nothing to choose")
    }
}
