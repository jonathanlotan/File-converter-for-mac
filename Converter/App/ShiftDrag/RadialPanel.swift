import AppKit
import ConverterCore
import os
import SwiftUI

/// The floating window that holds the wheel. Borderless and non-activating,
/// so the app the drag started in (Finder) keeps focus and the drag carries
/// on uninterrupted.
@MainActor
final class RadialPanel: NSPanel {
    let model: RadialMenuModel
    /// Called with what was chosen and the dropped files.
    var onPick: ((RadialMenuModel.Target, [InputFile]) -> Void)?
    /// The ring changed by scrolling (so the drag watcher can follow).
    var onModeChange: ((RingMode) -> Void)?
    /// Screen point at the ring's centre while visible.
    private(set) var ringCenter: CGPoint = .zero

    let dropView: RadialDropView
    private var hideTask: Task<Void, Never>?
    /// Bumped on every show, so a fade-out that finishes after the panel
    /// was shown again doesn't hide it.
    private var generation = 0
    private var scrollMonitor: Any?
    private var scroller = RingScroller()
    private let log = Logger(subsystem: "io.github.jonathanlotan.Swivel", category: "shift-drag")

    init(model: RadialMenuModel) {
        self.model = model
        let side = model.geometry.panelSide
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        dropView = RadialDropView(model: model, frame: bounds)
        super.init(contentRect: bounds, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the ring draws its own
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let container = NSView(frame: bounds)
        let host = NSHostingView(rootView: RadialMenuView(model: model))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        dropView.autoresizingMask = [.width, .height]
        container.addSubview(host)
        container.addSubview(dropView) // on top, so drags reach it first
        contentView = container

        dropView.onDrop = { [weak self] target in self?.picked(target) }
        dropView.onScroll = { [weak self] event in self?.scrolled(event) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the wheel on `mode`, centred on `screenPoint`, nudged inwards
    /// near screen edges so the whole ring stays visible.
    func show(_ mode: RingMode, at screenPoint: CGPoint) {
        hideTask?.cancel()
        generation += 1
        model.reset(mode: mode)
        scroller = RingScroller()
        let g = model.geometry
        let screen = NSScreen.screens.first { NSMouseInRect(screenPoint, $0.frame, false) } ?? NSScreen.main
        var center = screenPoint
        if let visible = screen?.visibleFrame {
            let margin = g.outerRadius + 8
            center.x = min(max(center.x, visible.minX + margin), visible.maxX - margin)
            center.y = min(max(center.y, visible.minY + margin), visible.maxY - margin)
        }
        ringCenter = center
        setFrame(NSRect(x: center.x - g.panelSide / 2, y: center.y - g.panelSide / 2,
                        width: g.panelSide, height: g.panelSide), display: false)
        // The wheel springs in (or just fades, with Reduce Motion) on the
        // next frame, once the window is up.
        model.isPresented = false
        alphaValue = 1
        orderFrontRegardless()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.model.isPresented = true }
        }
        // Scrolls over other windows (the wheel may not be under the
        // pointer) still switch rings. Mouse monitors need no permission.
        if scrollMonitor == nil {
            scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.scrolled(event) }
            }
        }
        log.notice("wheel shown: \(mode.rawValue, privacy: .public)")
    }

    /// Shows another ring (a different key was tapped).
    func switchMode(_ mode: RingMode) {
        guard isVisible else { return }
        model.setMode(mode)
        log.notice("ring: \(mode.rawValue, privacy: .public)")
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        guard isVisible else { return }
        let shown = generation
        model.isPresented = false
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000) // let the wheel animate away
            guard let self, self.generation == shown else { return }
            self.orderOut(nil)
            self.model.reset()
        }
        log.notice("wheel hidden")
    }

    /// The mouse button came up. A drop on the wheel arrives a moment later,
    /// so wait before hiding rather than pulling the window out from under it.
    func dragEnded() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func scrolled(_ event: NSEvent) {
        guard isVisible, let steps = scroller.steps(for: ScrollSample(event)) else { return }
        let mode = model.mode.advanced(by: steps)
        model.setMode(mode)
        onModeChange?(mode)
        log.notice("ring (scroll): \(mode.rawValue, privacy: .public)")
    }

    private func picked(_ target: RadialMenuModel.Target) {
        let inputs = model.inputs
        log.notice("dropped on \(target.title, privacy: .public) with \(inputs.count) item(s)")
        hide()
        onPick?(target, inputs)
    }
}

// MARK: - Drop target

/// Transparent layer over the wheel that receives the drag, tracks which
/// slice is under the cursor, and reports the drop.
@MainActor
final class RadialDropView: NSView {
    /// How long the cursor rests on a group ("More Formats", "Resize")
    /// before its sub-ring opens.
    static let dwellNanoseconds: UInt64 = 250_000_000

    var onDrop: ((RadialMenuModel.Target) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    private let model: RadialMenuModel
    private var dwellTask: Task<Void, Never>?

    init(model: RadialMenuModel, frame: NSRect) {
        self.model = model
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Only now does the app read the drag's contents: the user has
        // brought the files to this window.
        if model.phase == .waiting { model.load(StatusDropView.fileURLs(in: sender)) }
        return track(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        track(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dwellTask?.cancel()
        model.clearHover()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        _ = track(sender, allowDwell: false)
        dwellTask?.cancel()
        // No target (centre, a group, outside) returns false, and the source
        // slides the files back: nothing happens.
        guard let target = model.target else { return false }
        onDrop?(target)
        return true
    }

    /// Point relative to the ring centre, y up.
    func ringPoint(for windowPoint: NSPoint) -> CGPoint {
        let local = convert(windowPoint, from: nil)
        return CGPoint(x: local.x - bounds.midX, y: local.y - bounds.midY)
    }

    private func track(_ sender: NSDraggingInfo, allowDwell: Bool = true) -> NSDragOperation {
        if let group = model.hover(at: ringPoint(for: sender.draggingLocation)), allowDwell {
            dwellTask?.cancel()
            dwellTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.dwellNanoseconds)
                guard !Task.isCancelled else { return }
                self?.model.openGroup(group)
            }
        }
        return model.target == nil ? [] : DropOperation.safe(within: sender.draggingSourceOperationMask)
    }
}

/// The operation to accept a file drop with. Held modifier keys narrow what
/// the source allows (Command means move, generic; Control means link;
/// Option means copy), and a drop outside that mask is refused. So accept
/// whichever harmless operation is allowed, and never `.move` or `.delete`:
/// Converter only reads the originals.
enum DropOperation {
    static func safe(within mask: NSDragOperation) -> NSDragOperation {
        for operation in [NSDragOperation.copy, .generic, .link] where mask.contains(operation) {
            return operation
        }
        return []
    }
}

// MARK: - Scrolling between rings

/// One scroll event's essentials (testable without a real NSEvent).
struct ScrollSample {
    var deltaY: CGFloat
    var isPrecise: Bool
    var phase: NSEvent.Phase
    var isMomentum: Bool
    var time: TimeInterval

    init(deltaY: CGFloat, isPrecise: Bool, phase: NSEvent.Phase = [], isMomentum: Bool = false, time: TimeInterval) {
        self.deltaY = deltaY
        self.isPrecise = isPrecise
        self.phase = phase
        self.isMomentum = isMomentum
        self.time = time
    }

    init(_ event: NSEvent) {
        self.init(deltaY: event.scrollingDeltaY, isPrecise: event.hasPreciseScrollingDeltas, phase: event.phase,
                  isMomentum: !event.momentumPhase.isEmpty, time: event.timestamp)
    }
}

/// Turns scrolling into ring changes: one ring per trackpad swipe (momentum
/// ignored), or one per wheel notch with a short pause between.
struct RingScroller {
    static let trackpadDistance: CGFloat = 24
    static let wheelPause: TimeInterval = 0.2

    private var accumulated: CGFloat = 0
    private var switchedThisSwipe = false
    private var lastWheelSwitch: TimeInterval = -.infinity

    /// +1 (next ring), -1 (previous) or nil (no change yet). Scrolling up
    /// (positive delta) goes to the next ring.
    mutating func steps(for sample: ScrollSample) -> Int? {
        guard !sample.isMomentum else { return nil }
        if sample.isPrecise {
            if sample.phase.contains(.began) {
                accumulated = 0
                switchedThisSwipe = false
            }
            guard !switchedThisSwipe else { return nil }
            accumulated += sample.deltaY
            guard abs(accumulated) >= Self.trackpadDistance else { return nil }
            switchedThisSwipe = true
            return accumulated > 0 ? 1 : -1
        }
        guard sample.deltaY != 0, sample.time - lastWheelSwitch >= Self.wheelPause else { return nil }
        lastWheelSwitch = sample.time
        return sample.deltaY > 0 ? 1 : -1
    }
}
