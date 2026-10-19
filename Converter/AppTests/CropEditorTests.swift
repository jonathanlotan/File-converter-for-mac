import AppKit
import ConverterCore
import SwiftUI
import XCTest
@testable import ConverterApp

/// The crop editor's geometry, its batch flow, and Crop › Custom….
@MainActor
final class CropEditorTests: XCTestCase {
    var folder: URL!
    var photo: InputFile!

    override func setUp() async throws {
        folder = try makeTemporaryFolder("CropEditor")
        photo = try makeImage("photo.png", in: folder) // 320 × 200
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func editor(_ inputs: [InputFile]? = nil) -> CropEditorModel {
        CropEditorModel(inputs: inputs ?? [photo], loadsPreviews: false)
    }

    func testStartsWithTheWholeImage() {
        let model = editor()
        XCTAssertEqual(model.region, CropRegion(x: 0, y: 0, width: 320, height: 200))
        XCTAssertEqual(model.resultSize, PixelSize(width: 320, height: 200))
        XCTAssertTrue(model.isUnchanged, "nothing to crop yet")
    }

    func testAspectTakesTheLargestCentredRegion() {
        let model = editor()
        model.setAspect(.ratio(1, 1))
        XCTAssertEqual(model.region, CropRegion(x: 60, y: 0, width: 200, height: 200))
        model.setAspect(.original)
        XCTAssertEqual(model.region, CropRegion(x: 0, y: 0, width: 320, height: 200))
        model.setAspect(.ratio(9, 16))
        XCTAssertEqual(model.region, CropRegion(x: 104, y: 0, width: 113, height: 200))
        XCTAssertFalse(model.isUnchanged)
    }

    func testFreeformHandlesAndMoving() {
        let model = editor()
        model.drag(.bottomRight, by: CGSize(width: -20, height: -10))
        model.endDrag()
        XCTAssertEqual(model.region, CropRegion(x: 0, y: 0, width: 300, height: 190))
        model.drag(.left, by: CGSize(width: 30, height: 0))
        model.endDrag()
        XCTAssertEqual(model.region, CropRegion(x: 30, y: 0, width: 270, height: 190))
        model.drag(.top, by: CGSize(width: 0, height: 500))
        model.endDrag()
        XCTAssertEqual(model.region, CropRegion(x: 30, y: 174, width: 270, height: 16), "no smaller than 16 px")

        // A drag's translation is from where it started, not cumulative.
        model.drag(.move, by: CGSize(width: 10, height: 0))
        model.drag(.move, by: CGSize(width: 20, height: 0))
        model.endDrag()
        XCTAssertEqual(model.region, CropRegion(x: 50, y: 174, width: 270, height: 16))
        model.drag(.move, by: CGSize(width: 1000, height: -1000))
        model.endDrag()
        XCTAssertEqual(model.region, CropRegion(x: 50, y: 0, width: 270, height: 16), "stays inside the image")
    }

    func testShapeIsKeptWhileDragging() {
        let model = editor()
        model.setAspect(.ratio(1, 1))
        model.drag(.topLeft, by: CGSize(width: 40, height: 10))
        model.endDrag()
        XCTAssertEqual(model.region, CropRegion(x: 100, y: 40, width: 160, height: 160), "the opposite corner stays put")
        model.drag(.right, by: CGSize(width: 500, height: 0))
        model.endDrag()
        XCTAssertEqual(model.region, CropRegion(x: 100, y: 40, width: 160, height: 160), "can't grow past the bottom edge")
        model.drag(.bottom, by: CGSize(width: 0, height: -100))
        model.endDrag()
        XCTAssertEqual(model.region, CropRegion(x: 150, y: 40, width: 60, height: 60), "an edge shrinks around the middle")
    }

    func testTypingAnExactSize() {
        let model = editor()
        model.setOutputWidth(100)
        XCTAssertEqual(model.outputSize, PixelSize(width: 100, height: 63), "height follows the current shape")
        XCTAssertEqual(model.aspect, .ratio(100, 63))
        XCTAssertEqual(model.aspectChoices.last?.title, "100:63", "the typed shape shows in the menu")
        XCTAssertEqual(model.region, CropRegion(x: 1, y: 0, width: 317, height: 200))

        model.setOutputHeight(100)
        XCTAssertEqual(model.outputSize, PixelSize(width: 100, height: 100))
        XCTAssertEqual(model.aspect, .ratio(1, 1))
        XCTAssertEqual(model.region, CropRegion(x: 60, y: 0, width: 200, height: 200))
        XCTAssertEqual(model.converter.mode, .region(CropRegion(x: 60, y: 0, width: 200, height: 200),
                                                     size: PixelSize(width: 100, height: 100)))
        XCTAssertEqual(model.converter.output(for: photo).nameSuffix, " (100x100)")

        model.setOutputSize(nil)
        XCTAssertEqual(model.resultSize, PixelSize(width: 200, height: 200))
        model.setOutputWidth(99_999)
        XCTAssertEqual(model.outputSize?.width, CropEditorModel.maximumSide)
        model.setAspect(.free)
        XCTAssertNil(model.outputSize, "choosing a shape goes back to the crop's own size")
    }

    func testCropAndNextKeepsTheShape() throws {
        let tall = try makeImage("tall.png", in: folder, width: 100, height: 300)
        let model = editor([photo, tall])
        var crops: [(CropImageConverter, InputFile)] = []
        var finished = false
        model.onCrop = { crops.append(($0, $1)) }
        model.onFinish = { finished = true }

        model.setAspect(.ratio(1, 1))
        XCTAssertTrue(model.hasMore)
        model.crop()
        XCTAssertEqual(crops.first?.1, photo)
        XCTAssertEqual(crops.first?.0.mode, .region(CropRegion(x: 60, y: 0, width: 200, height: 200), size: nil))
        XCTAssertEqual(model.index, 1)
        XCTAssertEqual(model.region, CropRegion(x: 0, y: 100, width: 100, height: 100), "the next image gets the same shape")
        XCTAssertFalse(finished)
        model.crop()
        XCTAssertEqual(crops.count, 2)
        XCTAssertTrue(finished)
    }

    func testSkipAndCancel() throws {
        let other = try makeImage("other.png", in: folder)
        let model = editor([photo, other])
        var crops = 0, finished = 0
        model.onCrop = { _, _ in crops += 1 }
        model.onFinish = { finished += 1 }
        model.skip()
        XCTAssertEqual(model.index, 1)
        model.cancel()
        XCTAssertEqual(crops, 0)
        XCTAssertEqual(finished, 1)
    }

    func testEditorSavesTheCropThroughTheQueue() async throws {
        let queue = JobQueue()
        let controller = CropEditorController(queue: queue)
        controller.showsWindow = false
        controller.open([photo])
        let model = try XCTUnwrap(controller.model)
        model.setAspect(.ratio(1, 1))
        model.crop()
        XCTAssertNil(controller.model, "the editor closes after the last image")
        try await waitUntilIdle(queue)
        XCTAssertTrue(try folderContents(folder).contains("photo (cropped).png"))
        let saved = try XCTUnwrap(InputFile(url: folder.appendingPathComponent("photo (cropped).png")).image)
        XCTAssertEqual(saved.width, 200)
        XCTAssertEqual(saved.height, 200)
    }

    func testCustomCropOpensTheEditorInsteadOfRunning() async throws {
        let opened = OpenedFiles()
        let tool = CustomCropTool { opened.inputs = $0 }
        let registry = ConverterRegistry(ConverterRegistry.standard.everything + [tool])
        let menu = ConversionMenuModel(converters: registry.converters(for: [photo]))
        let crop = menu.tools.compactMap { entry -> [any Converter]? in
            if case .group("Crop", let members) = entry { return members }
            return nil
        }.first
        XCTAssertEqual(crop?.map(\.title).last, "Custom…")

        let queue = JobQueue()
        queue.start(tool, on: [photo])
        for _ in 0..<20 where opened.inputs.isEmpty { await Task.yield() }
        XCTAssertEqual(opened.inputs, [photo])
        XCTAssertTrue(queue.jobs.isEmpty, "nothing runs until a crop is chosen")
        queue.start(CropImageConverter(.aspect(width: 1, height: 1)), on: [photo])
        XCTAssertEqual(queue.jobs.count, 1)
        try await waitUntilIdle(queue)
    }

    func testRenderEditor() throws {
        let url = folder.appendingPathComponent("scene.png")
        try writeScene(to: url)
        let model = CropEditorModel(inputs: [try InputFile(url: url), photo])
        model.setAspect(.ratio(4, 3))
        model.drag(.bottomRight, by: CGSize(width: -300, height: 0))
        model.endDrag()
        let view = CropEditorView(model: model)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 740, height: 500)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: snapshotFolder().appendingPathComponent("crop-editor.png"))
    }

    /// Sky, sun and ground, so the snapshot shows what's dimmed.
    private func writeScene(to url: URL) throws {
        let (w, h) = (1600, 1000)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.45, green: 0.7, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h / 3))
        context.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 1000, y: 600, width: 220, height: 220))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

/// Where the snapshot tests write PNGs for a visual check.
func snapshotFolder() throws -> URL {
    let out = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Converter/Snapshots", isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    return out
}

@MainActor
private final class OpenedFiles {
    var inputs: [InputFile] = []
}
