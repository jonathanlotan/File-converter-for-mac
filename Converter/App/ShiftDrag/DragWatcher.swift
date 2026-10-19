import AppKit
import os

/// What the drag watcher reads from the system. Swappable so tests can play
/// back a drag without touching the real mouse or pasteboard.
@MainActor
protocol DragEnvironment: AnyObject {
    var isMouseButtonDown: Bool { get }
    /// Goes up whenever any app starts a new drag.
    var dragChangeCount: Int { get }
    /// The current drag carries file URLs. Reads pasteboard *types* only,
    /// never contents.
    var dragHasFileURLs: Bool { get }
    /// Modifier keys held right now.
    var pressedKeys: Set<ModifierKey> { get }
    /// Screen coordinates, origin bottom-left.
    var mouseLocation: CGPoint { get }
}

/// Spots another app's file drag and tells the wheel when to open and
/// which ring to show.
///
/// macOS has no "a drag started" notification, so the watcher infers it
/// without any permission prompt:
/// 1. A global `.leftMouseDown` monitor (mouse monitors need no
///    Accessibility or Input Monitoring) arms the watcher and notes the drag
///    pasteboard's `changeCount`.
/// 2. While the button stays down it polls, at 60 Hz, the pressed buttons,
///    `changeCount` and `NSEvent.modifierFlags`. None of these needs a
///    permission, unlike a global `.flagsChanged` monitor.
/// 3. A new `changeCount` with file URLs means a file drag. *Tapping* a
///    mapped key after that (Shift, Command, Control by default) opens that
///    key's ring; keys already held when the drag began don't count, so a
///    Shift- or Command-click selection doesn't open the wheel by itself.
///    Another key switches rings. The wheel stays open until the drop.
///
/// Polling only runs while a mouse button is held, so the idle cost is nil.
@MainActor
final class DragWatcher {
    enum State: Equatable {
        case idle
        /// Button down; waiting to see whether a drag starts.
        case armed(baseline: Int)
        /// A drag without files (text, images from a browser): ignored.
        case ignoring
        /// A file drag, wheel not open yet.
        case dragging
        case showingMenu(RingMode)
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { log.notice("state: \(String(describing: self.state), privacy: .public)") } }
    }

    /// Open the wheel on this ring, centred on this screen point.
    var onShowMenu: ((RingMode, CGPoint) -> Void)?
    /// Switch the open wheel to another ring.
    var onSwitchMode: ((RingMode) -> Void)?
    /// Watching stopped while the wheel was open.
    var onHideMenu: (() -> Void)?
    /// The mouse button came up while the wheel was open.
    var onDragEnded: (() -> Void)?
    /// Which key opens which ring (read on every tap, so settings apply at once).
    var ringKeys: () -> RingKeys = { .standard }

    private let environment: DragEnvironment
    private let usesTimer: Bool
    private var timer: Timer?
    private var monitor: Any?
    /// Keys held at the previous poll, to spot new taps.
    private var heldKeys: Set<ModifierKey> = []
    private let log = Logger(subsystem: "com.example.Converter", category: "shift-drag")

    init(environment: DragEnvironment, usesTimer: Bool = true) {
        self.environment = environment
        self.usesTimer = usesTimer
    }

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        log.notice("watching drags (global monitor installed: \(self.monitor != nil, privacy: .public))")
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if case .showingMenu = state { onHideMenu?() }
        state = .idle
        stopPolling()
    }

    /// A mouse button went down in another app.
    func mouseDown() {
        state = .armed(baseline: environment.dragChangeCount)
        startPolling()
    }

    /// One poll of the system state.
    func tick() {
        let env = environment
        guard env.isMouseButtonDown else {
            if case .showingMenu = state { onDragEnded?() }
            state = .idle
            stopPolling()
            return
        }
        let held = env.pressedKeys
        let tapped = held.subtracting(heldKeys)
        heldKeys = held

        switch state {
        case .idle:
            stopPolling()
        case .armed(let baseline):
            guard env.dragChangeCount != baseline else { return }
            state = env.dragHasFileURLs ? .dragging : .ignoring
            heldKeys = held // keys down when the drag began don't open anything
        case .ignoring:
            break
        case .dragging:
            if let mode = mode(for: tapped) {
                state = .showingMenu(mode)
                onShowMenu?(mode, env.mouseLocation)
            }
        case .showingMenu(let current):
            if let mode = mode(for: tapped), mode != current {
                state = .showingMenu(mode)
                onSwitchMode?(mode)
            }
        }
    }

    /// The wheel switched rings some other way (scrolling).
    func modeChanged(to mode: RingMode) {
        if case .showingMenu = state { state = .showingMenu(mode) }
    }

    private func mode(for tapped: Set<ModifierKey>) -> RingMode? {
        let keys = ringKeys()
        // Deterministic if two keys land in the same poll.
        return ModifierKey.allCases.filter(tapped.contains).lazy.compactMap(keys.mode(for:)).first
    }

    private func startPolling() {
        heldKeys = environment.pressedKeys
        guard usesTimer, timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so it keeps firing during event tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}

/// The real system state.
@MainActor
final class SystemDragEnvironment: DragEnvironment {
    private let pasteboard = NSPasteboard(name: .drag)

    var isMouseButtonDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }
    var dragChangeCount: Int { pasteboard.changeCount }
    var dragHasFileURLs: Bool { pasteboard.types?.contains(.fileURL) ?? false }
    var pressedKeys: Set<ModifierKey> { ModifierKey.pressed(in: NSEvent.modifierFlags) }
    var mouseLocation: CGPoint { NSEvent.mouseLocation }
}
