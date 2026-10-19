import AppKit
import ConverterCore
import XCTest
@testable import ConverterApp

/// The file actions, with the pasteboard, folder picker and app launching
/// swapped out so nothing on this Mac changes.
@MainActor
final class FileActionTests: XCTestCase {
    var folder: URL!
    var pasteboard: NSPasteboard!
    var reports: [String] = []

    override func setUp() async throws {
        folder = try makeTemporaryFolder("Actions")
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ConverterTests-\(UUID().uuidString)"))
        reports = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        pasteboard.releaseGlobally()
    }

    private func performer(shelf: ShelfController? = nil) -> FileActionPerformer {
        let performer = FileActionPerformer(shelf: shelf, settings: nil)
        performer.pasteboard = pasteboard
        performer.report = { [unowned self] title, _ in reports.append(title) }
        return performer
    }

    private func file(_ name: String, _ text: String = "x") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testCopyPutsFilesOnThePasteboardForFinder() throws {
        let a = try file("a.txt"), b = try file("b.txt")
        performer().perform(.copy, on: [a, b])
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls?.map(\.standardizedFileURL), [a.standardizedFileURL, b.standardizedFileURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "copying doesn't touch the files")
    }

    func testCopyPathWritesOnePathPerLine() throws {
        let a = try file("a.txt"), b = try file("sub/b.txt")
        performer().perform(.copyPath, on: [a, b])
        XCTAssertEqual(pasteboard.string(forType: .string), "\(a.path)\n\(b.path)")
    }

    func testMoveNeverReplacesAnything() throws {
        let destination = folder.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "already here".write(to: destination.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        let report = try file("report.txt", "moving")
        let photos = folder.appendingPathComponent("photos v1.2", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)

        let moving = performer()
        moving.chooseFolder = { destination }
        moving.perform(.move, on: [report, photos])

        XCTAssertFalse(FileManager.default.fileExists(atPath: report.path), "the original moved")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("report.txt"), encoding: .utf8), "already here")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("report 2.txt"), encoding: .utf8), "moving")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("photos v1.2").path),
                      "a folder keeps its full name")
        XCTAssertTrue(reports.isEmpty)
    }

    func testCancellingTheMovePickerMovesNothing() throws {
        let report = try file("report.txt")
        let moving = performer()
        moving.chooseFolder = { nil }
        moving.perform(.move, on: [report])
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.path))
    }

    func testTerminalOpensEachFolderOnce() throws {
        let a = try file("a.txt"), b = try file("b.txt")
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(FileActionPerformer.terminalFolders(for: [a, b, sub]).map(\.standardizedFileURL.path),
                       [folder.standardizedFileURL.path, sub.standardizedFileURL.path])

        var opened: [URL] = []
        var app: URL?
        let terminal = performer()
        terminal.openFolders = { folders, terminalApp in opened = folders; app = terminalApp }
        terminal.perform(.terminal, on: [a, sub])
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(app?.lastPathComponent, "Terminal.app")
    }

    func testFloatPutsFilesOnTheShelf() throws {
        let shelf = ShelfController()
        shelf.showsWindow = false
        let a = try file("a.txt")
        performer(shelf: shelf).perform(.float, on: [a, a])
        XCTAssertEqual(shelf.model.items, [a.standardizedFileURL], "no duplicates")
        shelf.model.remove(a.standardizedFileURL)
        XCTAssertTrue(shelf.model.items.isEmpty)
    }

    func testMenusOfferActionsEvenWithoutConversions() throws {
        let rar = try file("old.rar")
        let png = try makeImage("photo.png", in: folder)
        let inputs = [png, try InputFile(url: rar)]
        var chosen: [String] = []
        let menu = ConversionMenu.make(for: inputs, converters: ConverterRegistry.standard.converters(for: inputs),
                                       onPick: { _ in }, onAction: { chosen.append($0.id) })
        let titles = menu.items.map(\.title)
        XCTAssertEqual(Array(titles.prefix(2)), ["Convert 2 files", "No conversion works for all of these files"])
        XCTAssertEqual(Array(titles.suffix(6)), ["AirDrop", "Float", "Copy", "Move…", "Copy Path", "Terminal"])
        let copyPath = try XCTUnwrap(menu.items.firstIndex { $0.title == "Copy Path" })
        menu.performActionForItem(at: copyPath)
        XCTAssertEqual(chosen, ["action.copyPath"])
    }

    func testKeyAndTerminalSettingsArePersisted() throws {
        let suite = "ConverterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, loginItem: FakeLoginItem())
        XCTAssertEqual(settings.ringKeys, .standard)
        var keys = settings.ringKeys
        keys.assign(.option, to: .actions)
        settings.ringKeys = keys
        settings.terminalApp = .iTerm

        let reloaded = AppSettings(defaults: defaults, loginItem: FakeLoginItem())
        XCTAssertEqual(reloaded.ringKeys.key(for: .actions), .option)
        XCTAssertEqual(reloaded.terminalApp, .iTerm)
    }
}
