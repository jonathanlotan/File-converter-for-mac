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

    private func run(_ target: RadialMenuModel.Target, on inputs: [InputFile]) {
        switch target {
        case .convert(let converter):
            queue.enqueue(converter, on: inputs)
        case .action(let action):
            // After the drop has finished, so a panel or picker doesn't
            // appear while the source app is still ending its drag.
            let urls = inputs.map(\.url)
            Task { @MainActor [actions] in actions?.perform(action, on: urls) }
        }
    }
}
