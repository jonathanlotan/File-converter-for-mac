import AppKit
import ConverterCore
import XCTest
@testable import ConverterApp

final class RadialGeometryTests: XCTestCase {
    let g = RadialGeometry()

    func testFourSlicesStartAtTheTopAndGoClockwise() {
        XCTAssertEqual(g.hit(CGPoint(x: 0, y: 100), count: 4), .slice(0))
        XCTAssertEqual(g.hit(CGPoint(x: 100, y: 0), count: 4), .slice(1))
        XCTAssertEqual(g.hit(CGPoint(x: 0, y: -100), count: 4), .slice(2))
        XCTAssertEqual(g.hit(CGPoint(x: -100, y: 0), count: 4), .slice(3))
    }

    func testSliceBoundaries() {
        let r: CGFloat = 100
        func point(degrees: Double) -> CGPoint {
            let a = degrees * .pi / 180
            return CGPoint(x: r * CGFloat(sin(a)), y: r * CGFloat(cos(a)))
        }
        XCTAssertEqual(g.hit(point(degrees: 44), count: 4), .slice(0))
        XCTAssertEqual(g.hit(point(degrees: 46), count: 4), .slice(1))
        XCTAssertEqual(g.hit(point(degrees: 316), count: 4), .slice(0), "wraps past 12 o'clock")
        XCTAssertEqual(g.hit(point(degrees: 314), count: 4), .slice(3))
    }

    func testCentreRingAndOutside() {
        XCTAssertEqual(g.hit(CGPoint(x: 5, y: 10), count: 6), .center)
        XCTAssertEqual(g.hit(CGPoint(x: 0, y: g.outerRadius + 3), count: 6), .slice(0), "the gap counts as the ring")
        XCTAssertEqual(g.hit(CGPoint(x: 0, y: 180), count: 6), .outside, "no sub-ring open")
        XCTAssertEqual(g.hit(CGPoint(x: 0, y: 100), count: 0), .outside)
    }

    func testSubRingFansOutAroundItsParent() {
        let count = 8, parent = 0, members = 3
        let r = (g.subInnerRadius + g.subOuterRadius) / 2
        for member in 0..<members {
            let a = g.subCenterAngle(member: member, members: members, parent: parent, count: count)
            let p = CGPoint(x: r * CGFloat(sin(a)), y: r * CGFloat(cos(a)))
            XCTAssertEqual(g.hit(p, count: count, openGroup: (parent, members)), .subSlice(member))
        }
        // Member 0 sits left of 12 o'clock, at a negative angle that must wrap.
        XCTAssertLessThan(g.subCenterAngle(member: 0, members: members, parent: parent, count: count), 0)
        let opposite = CGPoint(x: 0, y: -r)
        XCTAssertEqual(g.hit(opposite, count: count, openGroup: (parent, members)), .outside)
    }

    func testPanelFitsTheSubRing() {
        XCTAssertGreaterThanOrEqual(g.panelSide / 2, g.subOuterRadius + g.subSlack)
    }
}

@MainActor
final class RadialMenuModelTests: XCTestCase {
    var folder: URL!
    var photo: URL!

    override func setUp() async throws {
        folder = try makeTemporaryFolder("Radial")
        photo = try makeImage("photo.jpg", in: folder, width: 2000, height: 1000, type: "public.jpeg").url
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The y-up point at the middle of slice `index` of the main ring.
    private func point(onSlice index: Int, of model: RadialMenuModel) -> CGPoint {
        let g = model.geometry
        let a = g.centerAngle(ofSlice: index, count: model.slices.count)
        let r = (g.innerRadius + g.outerRadius) / 2
        return CGPoint(x: r * CGFloat(sin(a)), y: r * CGFloat(cos(a)))
    }

    func testThreeRingsFormatsToolsActions() {
        let model = RadialMenuModel()
        model.load([photo])
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.mode, .formats)
        let formats = model.slices.map(\.title)
        XCTAssertEqual(formats.first, "PNG")
        XCTAssertFalse(formats.contains("JPEG"))
        XCTAssertEqual(formats.last, "More")

        model.setMode(.tools)
        XCTAssertEqual(model.slices.map(\.title), ["Resize", "Compress", "Remove Metadata", "Recognize Text", "Archive"])
        XCTAssertTrue(model.slices.first { $0.title == "Resize" }?.isGroup ?? false)

        model.setMode(.actions)
        XCTAssertEqual(model.slices.map(\.title), ["AirDrop", "Float", "Copy", "Move…", "Copy Path", "Terminal"])
    }

    func testSwitchingRingsClearsTheHover() {
        let model = RadialMenuModel()
        model.load([photo])
        model.hover(at: point(onSlice: 0, of: model))
        XCTAssertNotNil(model.target)
        model.setMode(.actions)
        XCTAssertNil(model.target, "nothing is selected until the pointer moves")
        model.hover(at: point(onSlice: 0, of: model))
        guard case .action(let action) = model.target else { return XCTFail("expected an action") }
        XCTAssertEqual(action, .airDrop)
        XCTAssertEqual(model.caption.title, "AirDrop")
        XCTAssertEqual(model.caption.detail, "photo.jpg")
    }

    func testAFolderHasNoFormatsButHasToolsAndActions() throws {
        let sub = folder.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let model = RadialMenuModel()
        model.load([sub])
        XCTAssertTrue(model.slices.isEmpty)
        XCTAssertEqual(model.caption.title, "No formats for this")
        XCTAssertEqual(model.caption.detail, "Scroll for more")
        model.setMode(.tools)
        XCTAssertEqual(model.slices.first?.title, "ZIP")
        model.setMode(.actions)
        XCTAssertEqual(model.slices.count, 6)
    }

    func testHoverPicksASliceAndNamesTheOutput() {
        let model = RadialMenuModel()
        model.load([photo])
        model.hover(at: point(onSlice: 0, of: model))
        XCTAssertEqual(targetID(model), "image.png")
        XCTAssertEqual(model.caption.title, "PNG")
        XCTAssertEqual(model.caption.detail, "photo.png")

        model.hover(at: CGPoint(x: 3, y: 3))
        XCTAssertNil(model.target)
        XCTAssertEqual(model.caption.title, "Cancel")
    }

    func testGroupsOpenASubRingAfterTheDwell() throws {
        let model = RadialMenuModel()
        model.load([photo])
        model.setMode(.tools)
        let resize = try XCTUnwrap(model.slices.firstIndex { $0.title == "Resize" })

        XCTAssertEqual(model.hover(at: point(onSlice: resize, of: model)), resize, "asks for a dwell")
        XCTAssertNil(model.target, "a group alone isn't a target")
        model.openGroup(resize)
        XCTAssertEqual(model.openGroup, resize)

        let g = model.geometry
        let members = model.openGroupMembers
        let a = g.subCenterAngle(member: 2, members: members.count, parent: resize, count: model.slices.count)
        let r = (g.subInnerRadius + g.subOuterRadius) / 2
        model.hover(at: CGPoint(x: r * CGFloat(sin(a)), y: r * CGFloat(cos(a))))
        XCTAssertEqual(targetID(model), members[2].id)
        XCTAssertEqual(model.caption.detail, "photo (1920px).jpg")

        model.hover(at: point(onSlice: resize + 1, of: model))
        XCTAssertNil(model.openGroup, "moving to another slice closes the sub-ring")
    }

    func testFilesWithNothingInCommonSaySo() throws {
        let rar = folder.appendingPathComponent("old.rar")
        try Data("not really".utf8).write(to: rar)
        let model = RadialMenuModel()
        model.load([photo, rar])
        XCTAssertEqual(model.caption.title, "No common format")
        model.hover(at: CGPoint(x: 0, y: 100))
        XCTAssertNil(model.target)
        model.setMode(.actions)
        XCTAssertEqual(model.slices.count, 6, "actions work for any files")
    }

    private func targetID(_ model: RadialMenuModel) -> String? {
        switch model.target {
        case .convert(let converter): return converter.id
        case .action(let action): return action.id
        case nil: return nil
        }
    }

    func testWaitingRingHasNoTargets() {
        let model = RadialMenuModel()
        model.hover(at: CGPoint(x: 0, y: 100))
        XCTAssertEqual(model.phase, .waiting)
        XCTAssertNil(model.target)
        XCTAssertEqual(model.caption.title, "Convert")
    }
}

/// The panel's drop handling with synthetic drags at slice positions. The
/// panel is never put on screen.
@MainActor
final class RadialPanelDropTests: XCTestCase {
    var folder: URL!
    var photo: URL!
    var panel: RadialPanel!
    var picked: [(String, Int)] = []

    override func setUp() async throws {
        folder = try makeTemporaryFolder("RadialDrop")
        photo = try makeImage("photo.jpg", in: folder, width: 2000, height: 1000, type: "public.jpeg").url
        panel = RadialPanel(model: RadialMenuModel())
        picked = []
        panel.onPick = { [unowned self] target, inputs in
            switch target {
            case .convert(let converter): picked.append((converter.id, inputs.count))
            case .action(let action): picked.append((action.id, inputs.count))
            }
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Window coordinates of a point at `angle`/`radius` from the ring centre.
    private func windowPoint(angle: Double, radius: CGFloat) -> NSPoint {
        let side = panel.model.geometry.panelSide
        return NSPoint(x: side / 2 + radius * CGFloat(sin(angle)), y: side / 2 + radius * CGFloat(cos(angle)))
    }

    private var ringRadius: CGFloat {
        let g = panel.model.geometry
        return (g.innerRadius + g.outerRadius) / 2
    }

    func testDropOnASliceConvertsAsACopy() {
        let drag = FakeDrag(fileURLs: [photo])
        drag.location = windowPoint(angle: 0, radius: ringRadius) // slice 0, at the top
        XCTAssertEqual(panel.dropView.draggingEntered(drag), .copy)
        XCTAssertEqual(panel.model.slices.first?.title, "PNG", "entering loads the dragged files")
        XCTAssertTrue(panel.dropView.performDragOperation(drag))
        XCTAssertEqual(picked.map(\.0), ["image.png"])
        XCTAssertEqual(picked.first?.1, 1)
    }

    func testDropOnAnActionReportsIt() {
        let drag = FakeDrag(fileURLs: [photo])
        drag.location = windowPoint(angle: 0, radius: ringRadius)
        _ = panel.dropView.draggingEntered(drag)
        panel.model.setMode(.actions)
        XCTAssertEqual(panel.dropView.draggingUpdated(drag), .copy)
        XCTAssertTrue(panel.dropView.performDragOperation(drag))
        XCTAssertEqual(picked.map(\.0), ["action.airdrop"])
    }

    func testDropWhileCommandIsHeldIsAcceptedWithoutMoving() {
        let drag = FakeDrag(fileURLs: [photo])
        drag.location = windowPoint(angle: 0, radius: ringRadius)
        drag.operationMask = .generic // what Finder allows while ⌘ is down
        XCTAssertEqual(panel.dropView.draggingEntered(drag), .generic)
        XCTAssertTrue(panel.dropView.performDragOperation(drag))
        XCTAssertEqual(picked.map(\.0), ["image.png"])
    }

    func testDropInTheCentreCancels() {
        let drag = FakeDrag(fileURLs: [photo])
        drag.location = windowPoint(angle: 0, radius: 10)
        XCTAssertEqual(panel.dropView.draggingEntered(drag), [], "no operation over the centre")
        XCTAssertFalse(panel.dropView.performDragOperation(drag))
        XCTAssertTrue(picked.isEmpty)
    }

    func testDwellingOnAGroupOpensItsSubRing() async throws {
        let drag = FakeDrag(fileURLs: [photo])
        drag.location = windowPoint(angle: 0, radius: ringRadius)
        _ = panel.dropView.draggingEntered(drag)
        let model = panel.model
        let more = try XCTUnwrap(model.slices.firstIndex { $0.title == "More" })
        let g = model.geometry
        drag.location = windowPoint(angle: g.centerAngle(ofSlice: more, count: model.slices.count), radius: ringRadius)
        XCTAssertEqual(panel.dropView.draggingUpdated(drag), [], "a group isn't droppable")

        try await Task.sleep(nanoseconds: RadialDropView.dwellNanoseconds + 150_000_000)
        XCTAssertEqual(model.openGroup, more)

        let members = model.openGroupMembers
        let ico = try XCTUnwrap(members.firstIndex { $0.id == "image.ico" })
        let angle = g.subCenterAngle(member: ico, members: members.count, parent: more, count: model.slices.count)
        drag.location = windowPoint(angle: angle, radius: (g.subInnerRadius + g.subOuterRadius) / 2)
        XCTAssertEqual(panel.dropView.draggingUpdated(drag), .copy)
        XCTAssertTrue(panel.dropView.performDragOperation(drag))
        XCTAssertEqual(picked.map(\.0), ["image.ico"])
    }
}
