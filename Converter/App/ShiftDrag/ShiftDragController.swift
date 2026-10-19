import AppKit
import ConverterCore

/// Connects the drag watcher to the wheel, the job queue and the file
/// actions, and remembers whether the gesture is switched on.
@MainActor
final class ShiftDragController: ObservableObject {
    static let enabledKey = "ShiftDragEnabled"

    let watcher: DragWatcher
    let panel: RadialPanel
    private let queue: JobQueue
    private let actions: FileActionPerformer?
    private let defaults: UserDefaults

    init(queue: JobQueue, registry: ConverterRegistry = .standard, preferred: @escaping () -> [String] = { [] },
         ringKeys: @escaping () -> RingKeys = { .standard }, actions: FileActionPerformer? = nil,
         environment: DragEnvironment = SystemDragEnvironment(), defaults: UserDefaults = .standard) {
        self.queue = queue
        self.actions = actions
        self.panel = RadialPanel(model: RadialMenuModel(registry: registry, preferred: preferred))
        self.defaults = defaults
        defaults.register(defaults: [Self.enabledKey: true])
        watcher = DragWatcher(environment: environment)
        watcher.ringKeys = ringKeys
        panel.model.ringKeys = ringKeys

        watcher.onShowMenu = { [weak self] mode, point in self?.panel.show(mode, at: point) }
        watcher.onSwitchMode = { [weak self] mode in self?.panel.switchMode(mode) }
        watcher.onHideMenu = { [weak self] in self?.panel.hide() }
        watcher.onDragEnded = { [weak self] in self?.panel.dragEnded() }
        panel.onModeChange = { [weak self] mode in self?.watcher.modeChanged(to: mode) }
        panel.onPick = { [weak self] target, inputs in self?.run(target, on: inputs) }

        if isEnabled { watcher.start() }
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Self.enabledKey)
            newValue ? watcher.start() : watcher.stop()
        }
    }

    #if DEBUG
    /// Design check, debug builds only: shows the wheel in the middle of the
    /// screen for a sample photo and steps through the rings, with a slice
    /// selected and a sub-ring open, then closes it.
    func previewWheel() {
        guard let screen = NSScreen.main, let sample = Self.samplePhoto() else { return }
        let frame = screen.visibleFrame
        panel.show(.formats, at: CGPoint(x: frame.midX, y: frame.midY))
        let model = panel.model
        model.load([sample])
        let steps: [(RingMode, Int, Bool)] = [(.formats, 0, false), (.tools, 1, true), (.actions, 0, true)]
        Task { @MainActor [weak self] in
            for (mode, slice, openGroup) in steps {
                model.setMode(mode)
                model.hover(at: Self.ringPoint(slice: slice, of: model))
                if openGroup { model.openGroup(slice) }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
            }
            self?.panel.hide()
        }
    }

    private static func ringPoint(slice: Int, of model: RadialMenuModel) -> CGPoint {
        let g = model.geometry
        let angle = g.centerAngle(ofSlice: slice, count: max(model.slices.count, 1))
        let radius = (g.innerRadius + g.outerRadius) / 2
        return CGPoint(x: radius * CGFloat(sin(angle)), y: radius * CGFloat(cos(angle)))
    }

    /// A small JPEG in the temporary folder, made once.
    private static func samplePhoto() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Wheel Preview.jpg")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let image = NSImage(size: NSSize(width: 64, height: 48), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation, let jpeg = NSBitmapImageRep(data: tiff)?
            .representation(using: .jpeg, properties: [:]) else { return nil }
        try? jpeg.write(to: url)
        return url
    }
    #endif

    private func run(_ target: RadialMenuModel.Target, on inputs: [InputFile]) {
        switch target {
        case .convert(let converter):
            queue.start(converter, on: inputs)
        case .action(let action):
            // After the drop has finished, so a panel or picker doesn't
            // appear while the source app is still ending its drag.
            let urls = inputs.map(\.url)
            Task { @MainActor [actions] in actions?.perform(action, on: urls) }
        }
    }
}
