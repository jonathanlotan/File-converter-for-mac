import AppKit
import XCTest
@testable import ConverterApp

/// Exercises the menu bar drop target with a synthetic drag. A real drag
/// from Finder still needs a manual check: the window server's delivery to
/// the status item can't be reproduced in a unit test.
final class StatusDropViewTests: XCTestCase {
    @MainActor
    func testFileDropIsAcceptedAsACopyAndReportedAfterTheDrag() async throws {
        let folder = try makeTemporaryFolder("Drop")
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = try makeImage("photo.png", in: folder).url

        let view = StatusDropView(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        var hovering: [Bool] = []
        var dropped: [URL] = []
        view.onHover = { hovering.append($0) }
        view.onDrop = { dropped = $0 }

        let drag = FakeDrag(fileURLs: [photo])
        XCTAssertEqual(view.draggingEntered(drag), .copy, "must never be a move")
        XCTAssertEqual(view.draggingUpdated(drag), .copy)
        XCTAssertTrue(view.performDragOperation(drag))
        XCTAssertEqual(hovering, [true, false])
        XCTAssertTrue(dropped.isEmpty, "the menu must wait until the drag session ends")

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(dropped.map(\.standardizedFileURL), [photo.standardizedFileURL])
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path), "the original stays put")
    }

    @MainActor
    func testNonFileDragIsRefused() {
        let view = StatusDropView(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
        var hovering: [Bool] = []
        view.onHover = { hovering.append($0) }
        let drag = FakeDrag(text: "just some text")
        XCTAssertEqual(view.draggingEntered(drag), [])
        XCTAssertFalse(view.performDragOperation(drag))
        XCTAssertFalse(hovering.contains(true), "the icon shouldn't light up for text")
    }

    @MainActor
    func testViewIsRegisteredForFileDrags() {
        let view = StatusDropView(frame: .zero)
        XCTAssertTrue(view.registeredDraggedTypes.contains(.fileURL))
    }
}

/// Minimal NSDraggingInfo backed by a private pasteboard. AppKit only
/// calls it on the main thread, hence the main-actor class and the
/// @preconcurrency conformance to the (partly annotated) protocol.
@MainActor
final class FakeDrag: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    /// Cursor position in window coordinates.
    var location: NSPoint = .zero

    init(fileURLs: [URL] = [], text: String? = nil) {
        draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("ConverterTests-\(UUID().uuidString)"))
        draggingPasteboard.clearContents()
        if !fileURLs.isEmpty { draggingPasteboard.writeObjects(fileURLs.map { $0 as NSURL }) }
        if let text { draggingPasteboard.setString(text, forType: .string) }
    }

    var draggingDestinationWindow: NSWindow? { nil }
    /// What the source allows; modifier keys narrow it (⌘ → generic, ⌃ → link).
    var operationMask: NSDragOperation = [.copy, .move, .generic, .link]
    var draggingSourceOperationMask: NSDragOperation { operationMask }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
