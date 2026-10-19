import AppKit
import ConverterCore
import ImageIO
import SwiftUI
import XCTest
@testable import ConverterApp

/// The metadata window's model, Copy All, and stepping through a selection.
@MainActor
final class MetadataWindowTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = try makeTemporaryFolder("MetadataWindow")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A JPEG with a camera, a place and a caption.
    private func taggedPhoto() throws -> URL {
        let plain = try makeImage("plain.png", in: folder)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(plain.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let url = folder.appendingPathComponent("IMG_0042.jpg")
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone 17 Pro"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifFNumber: 1.8, kCGImagePropertyExifExposureTime: 0.01,
                                             kCGImagePropertyExifISOSpeedRatings: [64]],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5007, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 0.1246, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: "Evening walk"],
        ]
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testPlainImage() async throws {
        let png = try makeImage("photo.png", in: folder).url
        let model = MetadataModel(urls: [png], loadsThumbnails: false)
        await model.loaded()
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.sections.map(\.title), ["File", "Image"])
        XCTAssertTrue(model.summary.contains(" · "), "kind and size: \(model.summary)")
        XCTAssertFalse(model.canRemoveMetadata, "nothing to remove")
        XCTAssertTrue(model.text.hasPrefix("photo.png\n\nFile\nKind: "))
    }

    func testTaggedPhotoCanBeCleaned() async throws {
        let model = MetadataModel(urls: [try taggedPhoto()], loadsThumbnails: false)
        await model.loaded()
        XCTAssertEqual(model.sections.map(\.title), ["File", "Image", "Camera", "Location", "Description"])
        XCTAssertEqual(model.sections.first { $0.title == "Location" }?["Coordinates"], "51.500700, -0.124600")
        XCTAssertTrue(model.canRemoveMetadata)
    }

    func testSteppingThroughASelection() async throws {
        let png = try makeImage("photo.png", in: folder).url
        let jpeg = try taggedPhoto()
        let model = MetadataModel(urls: [png, jpeg], loadsThumbnails: false)
        await model.loaded()
        model.show(1)
        XCTAssertEqual(model.url, jpeg)
        await model.loaded()
        XCTAssertNotNil(model.sections.first { $0.title == "Camera" })
        model.show(5)
        XCTAssertEqual(model.index, 1, "out of range is ignored")
    }

    func testCopyAllAndRemoveMetadata() async throws {
        let jpeg = try taggedPhoto()
        var removed: [InputFile] = []
        let controller = MetadataWindowController { removed.append($0) }
        controller.showsWindow = false
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ConverterTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        controller.pasteboard = pasteboard
        controller.show([jpeg])
        let model = try XCTUnwrap(controller.model)
        await model.loaded()
        controller.copy(model.text)
        let copied = try XCTUnwrap(pasteboard.string(forType: .string))
        XCTAssertTrue(copied.contains("Camera\nMake: Apple\nModel: iPhone 17 Pro"))
        XCTAssertTrue(copied.contains("Caption: Evening walk"))
        XCTAssertTrue(removed.isEmpty)
    }

    func testRenderWindow() async throws {
        let model = MetadataModel(urls: [try taggedPhoto(), try makeImage("photo.png", in: folder).url])
        await model.loaded()
        let view = MetadataView(model: model, onCopy: {}, onRemoveMetadata: {})
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 440, height: 760)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: snapshotFolder().appendingPathComponent("metadata.png"))
    }
}
