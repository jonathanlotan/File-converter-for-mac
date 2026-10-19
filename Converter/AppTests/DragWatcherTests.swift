import AppKit
import XCTest
@testable import ConverterApp

/// Plays back drags through a fake environment, one poll at a time.
@MainActor
final class FakeDragEnvironment: DragEnvironment {
    var isMouseButtonDown = false
    var dragChangeCount = 10
    var dragHasFileURLs = false
    var pressedKeys: Set<ModifierKey> = []
    var mouseLocation = CGPoint(x: 500, y: 400)

    /// Another app starts a drag.
    func startDrag(files: Bool) {
        dragChangeCount += 1
        dragHasFileURLs = files
    }
}

@MainActor
final class DragWatcherTests: XCTestCase {
    var env: FakeDragEnvironment!
    var watcher: DragWatcher!
    var events: [String] = []

    override func setUp() async throws {
        env = FakeDragEnvironment()
        watcher = DragWatcher(environment: env, usesTimer: false)
        events = []
        watcher.onShowMenu = { [unowned self] mode, point in events.append("show \(mode.rawValue) \(Int(point.x)),\(Int(point.y))") }
        watcher.onSwitchMode = { [unowned self] mode in events.append("switch \(mode.rawValue)") }
        watcher.onHideMenu = { [unowned self] in events.append("hide") }
        watcher.onDragEnded = { [unowned self] in events.append("ended") }
    }

    private func press() {
        env.isMouseButtonDown = true
        watcher.mouseDown()
    }

    /// Press, start a file drag, and let the watcher notice it.
    private func startFileDrag() {
        press()
        env.startDrag(files: true)
        watcher.tick()
    }

    /// Key down for one poll, then up for the next: a tap.
    private func tap(_ key: ModifierKey) {
        env.pressedKeys.insert(key)
        watcher.tick()
        env.pressedKeys.remove(key)
        watcher.tick()
    }

    func testEachKeyOpensItsRingAtThePointer() {
        for (key, mode) in [(ModifierKey.shift, RingMode.formats), (.command, .tools), (.control, .actions)] {
            events = []
            startFileDrag()
            XCTAssertEqual(watcher.state, .dragging)
            env.mouseLocation = CGPoint(x: 640, y: 300)
            tap(key)
            XCTAssertEqual(watcher.state, .showingMenu(mode))
            XCTAssertEqual(events, ["show \(mode.rawValue) 640,300"])
            env.isMouseButtonDown = false
            watcher.tick()
        }
    }

    func testTheWheelStaysOpenAfterTheKeyIsReleased() {
        startFileDrag()
        tap(.shift)
        for _ in 0..<5 { watcher.tick() }
        XCTAssertEqual(watcher.state, .showingMenu(.formats), "tapping, not holding")
        XCTAssertFalse(events.contains("hide"))
    }

    func testAnotherKeySwitchesRings() {
        startFileDrag()
        tap(.shift)
        tap(.command)
        tap(.control)
        tap(.control) // the same ring again: nothing to do
        XCTAssertEqual(events.dropFirst(), ["switch tools", "switch actions"])
        XCTAssertEqual(watcher.state, .showingMenu(.actions))
    }

    func testKeysHeldWhenTheDragBeganDontOpenTheWheel() {
        // Command-click and Shift-click select files; the key may still be
        // down as the drag starts.
        env.pressedKeys = [.command]
        startFileDrag()
        watcher.tick()
        XCTAssertEqual(watcher.state, .dragging)
        XCTAssertEqual(events, [])

        env.pressedKeys = []
        watcher.tick()
        tap(.command)
        XCTAssertEqual(watcher.state, .showingMenu(.tools), "a fresh tap does")
    }

    func testDragsWithoutFilesAreIgnored() {
        press()
        env.startDrag(files: false)
        watcher.tick()
        tap(.shift)
        XCTAssertEqual(watcher.state, .ignoring)
        XCTAssertEqual(events, [])
        env.isMouseButtonDown = false
        watcher.tick()
        XCTAssertEqual(watcher.state, .idle)
    }

    func testAClickWithoutADragDoesNothing() {
        press()
        tap(.shift)
        env.isMouseButtonDown = false
        watcher.tick()
        XCTAssertEqual(watcher.state, .idle)
        XCTAssertEqual(events, [])
    }

    func testReleasingTheButtonEndsTheDrag() {
        startFileDrag()
        tap(.shift)
        env.isMouseButtonDown = false
        watcher.tick()
        XCTAssertEqual(watcher.state, .idle)
        XCTAssertEqual(events.last, "ended")
    }

    func testCustomKeysAndUnmappedKeys() {
        var keys = RingKeys.standard
        keys.assign(.option, to: .actions) // Control now opens nothing
        watcher.ringKeys = { keys }
        startFileDrag()
        tap(.control)
        XCTAssertEqual(watcher.state, .dragging)
        tap(.option)
        XCTAssertEqual(watcher.state, .showingMenu(.actions))
    }

    func testScrollingKeepsTheWatcherInStep() {
        startFileDrag()
        tap(.shift)
        watcher.modeChanged(to: .tools) // the panel switched on a scroll
        tap(.command)
        XCTAssertEqual(events, ["show formats 500,400"], "already on tools, so no switch")
    }

    func testStopHidesAnOpenWheel() {
        startFileDrag()
        tap(.shift)
        watcher.stop()
        XCTAssertEqual(watcher.state, .idle)
        XCTAssertEqual(events.last, "hide")
    }

    func testControllerRemembersTheSwitch() throws {
        let suite = "ConverterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ShiftDragController(queue: JobQueue(), environment: FakeDragEnvironment(), defaults: defaults)
        XCTAssertTrue(controller.isEnabled, "on by default")
        XCTAssertTrue(controller.watcher.isRunning)

        controller.isEnabled = false
        XCTAssertFalse(controller.watcher.isRunning)
        XCTAssertFalse(defaults.bool(forKey: ShiftDragController.enabledKey))

        controller.isEnabled = true
        XCTAssertTrue(controller.watcher.isRunning)
        controller.watcher.stop()
    }
}

final class RingKeysTests: XCTestCase {
    func testStandardKeys() {
        let keys = RingKeys.standard
        XCTAssertEqual(keys.mode(for: .shift), .formats)
        XCTAssertEqual(keys.mode(for: .command), .tools)
        XCTAssertEqual(keys.mode(for: .control), .actions)
        XCTAssertNil(keys.mode(for: .option))
    }

    func testTakingAnotherRingsKeySwapsThem() {
        var keys = RingKeys.standard
        keys.assign(.shift, to: .tools)
        XCTAssertEqual(keys.key(for: .tools), .shift)
        XCTAssertEqual(keys.key(for: .formats), .command, "formats gets tools' old key")
        keys.assign(nil, to: .actions)
        XCTAssertNil(keys.key(for: .actions))
        XCTAssertNil(keys.mode(for: .control))
    }

    func testRingsWrapAround() {
        XCTAssertEqual(RingMode.formats.advanced(by: 1), .tools)
        XCTAssertEqual(RingMode.actions.advanced(by: 1), .formats)
        XCTAssertEqual(RingMode.formats.advanced(by: -1), .actions)
    }
}

final class RingScrollerTests: XCTestCase {
    func testOneRingPerTrackpadSwipe() {
        var scroller = RingScroller()
        XCTAssertNil(scroller.steps(for: ScrollSample(deltaY: -10, isPrecise: true, phase: .began, time: 0)))
        XCTAssertEqual(scroller.steps(for: ScrollSample(deltaY: -20, isPrecise: true, phase: .changed, time: 0.02)), 1)
        XCTAssertNil(scroller.steps(for: ScrollSample(deltaY: -40, isPrecise: true, phase: .changed, time: 0.04)),
                     "the rest of the swipe does nothing")
        XCTAssertNil(scroller.steps(for: ScrollSample(deltaY: -30, isPrecise: true, isMomentum: true, time: 0.1)),
                     "momentum is ignored")
        XCTAssertNil(scroller.steps(for: ScrollSample(deltaY: 10, isPrecise: true, phase: .began, time: 1)))
        XCTAssertEqual(scroller.steps(for: ScrollSample(deltaY: 20, isPrecise: true, phase: .changed, time: 1.02)), -1,
                       "a new swipe the other way goes back")
    }

    func testMouseWheelNotchesNeedAPause() {
        var scroller = RingScroller()
        XCTAssertEqual(scroller.steps(for: ScrollSample(deltaY: -1, isPrecise: false, time: 0)), 1)
        XCTAssertNil(scroller.steps(for: ScrollSample(deltaY: -1, isPrecise: false, time: 0.05)))
        XCTAssertEqual(scroller.steps(for: ScrollSample(deltaY: -1, isPrecise: false, time: 0.3)), 1)
        XCTAssertNil(scroller.steps(for: ScrollSample(deltaY: 0, isPrecise: false, time: 1)))
    }
}

final class DropOperationTests: XCTestCase {
    func testNeverMovesTheOriginal() {
        XCTAssertEqual(DropOperation.safe(within: [.copy, .move, .generic, .link]), .copy)
        XCTAssertEqual(DropOperation.safe(within: .generic), .generic, "Command held")
        XCTAssertEqual(DropOperation.safe(within: .link), .link, "Control held")
        XCTAssertEqual(DropOperation.safe(within: .move), [], "a move-only drag is refused")
        XCTAssertEqual(DropOperation.safe(within: []), [])
    }
}
