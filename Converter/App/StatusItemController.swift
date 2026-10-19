import AppKit
import Combine
import ConverterCore
import SwiftUI

/// The menu bar icon and everything reachable from it: dropping files on
/// the icon, the format picker, the job list, and the Open panel.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let queue: JobQueue
    private let registry: ConverterRegistry
    private let shiftDrag: ShiftDragController?
    private let settings: AppSettings?
    private let actions: FileActionPerformer?
    private let showSettings: () -> Void
    private let showWelcome: () -> Void
    private let mainMenu = NSMenu()
    /// Results of the current batch, selected in Finder when it ends.
    private var batchOutputs: [URL] = []
    private var visibility: AnyCancellable?

    private var iconTimer: Timer?
    private var badge: StatusIcon.Badge = .none
    private var badgeTask: Task<Void, Never>?
    private var batchHadFailure = false

    init(queue: JobQueue, registry: ConverterRegistry = .standard, shiftDrag: ShiftDragController? = nil,
         settings: AppSettings? = nil, actions: FileActionPerformer? = nil, showSettings: @escaping () -> Void = {},
         showWelcome: @escaping () -> Void = {}) {
        self.queue = queue
        self.registry = registry
        self.shiftDrag = shiftDrag
        self.settings = settings
        self.actions = actions
        self.showSettings = showSettings
        self.showWelcome = showWelcome
        super.init()

        if let button = statusItem.button {
            button.image = StatusIcon.image(progress: nil)
            button.toolTip = "Swivel: drop files here to convert them"
            let dropView = StatusDropView(frame: button.bounds)
            dropView.autoresizingMask = [.width, .height]
            dropView.onHover = { [weak self] hovering in self?.statusItem.button?.highlight(hovering) }
            dropView.onDrop = { [weak self] urls in self?.offerConversions(for: urls) }
            button.addSubview(dropView)
        }
        mainMenu.delegate = self
        mainMenu.autoenablesItems = false
        statusItem.menu = mainMenu
        statusItem.autosaveName = "ConverterStatusItem"
        if let settings {
            visibility = settings.$showMenuBarIcon.sink { [weak self] shown in self?.statusItem.isVisible = shown }
        }

        queue.onChange = { [weak self] in self?.queueChanged() }
        queue.onFinish = { [weak self] job in self?.jobFinished(job) }
    }

    // MARK: - Choosing a conversion

    enum PickerPlacement {
        /// Under the menu bar icon (files dropped on it, the Open panel).
        case statusItem
        /// At the pointer (Finder's Services, Quick Actions, Open With).
        case cursor
    }

    #if DEBUG
    /// Test hook, debug builds only: when this default names a converter,
    /// files arriving from Finder are converted with it instead of showing
    /// the menu, so the Services and Quick Action paths can be checked
    /// end to end without UI. `defaults write io.github.jonathanlotan.Swivel DebugAutoPickConverter image.jpeg`
    static let autoPickKey = "DebugAutoPickConverter"
    #endif

    /// Shows the format picker for these files.
    func offerConversions(for urls: [URL], at placement: PickerPlacement = .statusItem) {
        let inputs = urls.compactMap { try? InputFile(url: $0) }
        guard !inputs.isEmpty else { return }
        let converters = registry.converters(for: inputs)
        #if DEBUG
        if let id = UserDefaults.standard.string(forKey: Self.autoPickKey),
           let converter = converters.first(where: { $0.id == id }) {
            queue.enqueue(converter, on: inputs)
            return
        }
        #endif
        let urls = inputs.map(\.url)
        let picker = ConversionMenu.make(
            for: inputs, converters: converters, preferred: settings?.preferredFormatIDs ?? [],
            onPick: { [weak self] converter in self?.queue.start(converter, on: inputs) },
            onAction: actions.map { performer in { action in performer.perform(action, on: urls) } })
        switch placement {
        case .statusItem:
            show(picker)
        case .cursor:
            NSApp.activate(ignoringOtherApps: true)
            picker.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func chooseFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose files to convert. The results are saved next to them."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return }
        offerConversions(for: panel.urls)
    }

    /// Opens `menu` from the status item, then puts the main menu back.
    private func show(_ menu: NSMenu) {
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu !== mainMenu else { return }
        // The chosen item's action runs after this; restoring the menu next
        // turn of the run loop keeps the picker alive until then.
        Task { @MainActor in self.statusItem.menu = self.mainMenu }
    }

    // MARK: - Main menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === mainMenu else { return }
        menu.removeAllItems()

        let open = ActionMenuItem(title: "Convert Files…", keyEquivalent: "o") { [weak self] in self?.chooseFiles() }
        menu.addItem(open)
        menu.addItem(.separator())

        if queue.jobs.isEmpty {
            menu.addItem(ConversionMenu.disabledItem("Drop files here, or drag them and tap ⇧ ⌘ ⌃"))
        } else {
            menu.addItem(ConversionMenu.header("Conversions"))
            for job in queue.jobs {
                menu.addItem(row(for: job))
            }
            let clear = ActionMenuItem(title: "Clear Finished") { [weak self] in self?.queue.clearFinished() }
            clear.isEnabled = queue.jobs.contains { !$0.isActive }
            menu.addItem(clear)
        }

        // Icons follow Apple's guidance: sparingly, and for every item in a
        // group or none. Only the Settings/About group and Quit have them.
        menu.addItem(.separator())
        if let shiftDrag {
            let toggle = ActionMenuItem(title: "Wheel While Dragging") { shiftDrag.isEnabled.toggle() }
            toggle.state = shiftDrag.isEnabled ? .on : .off
            toggle.toolTip = "While dragging files, tap Shift (formats), Command (tools) or Control (actions) to open the wheel."
            menu.addItem(toggle)
        }
        #if DEBUG
        if let shiftDrag {
            menu.addItem(ActionMenuItem(title: "Preview Wheel (Debug)") { shiftDrag.previewWheel() })
        }
        #endif
        menu.addItem(.separator())
        let settingsItem = ActionMenuItem(title: "Settings…", keyEquivalent: ",") { [weak self] in self?.showSettings() }
        MenuIcons.set("gearshape", on: settingsItem)
        menu.addItem(settingsItem)
        let welcome = ActionMenuItem(title: "How to Use Swivel…") { [weak self] in self?.showWelcome() }
        MenuIcons.set("questionmark.circle", on: welcome)
        menu.addItem(welcome)
        let about = ActionMenuItem(title: "About Swivel") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        MenuIcons.set("info.circle", on: about)
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = ActionMenuItem(title: "Quit Swivel", keyEquivalent: "q") { NSApp.terminate(nil) }
        MenuIcons.set("power", on: quit)
        menu.addItem(quit)
    }

    private func row(for job: Job) -> NSMenuItem {
        let view = JobRowView(
            job: job,
            onCancel: { [weak self] in self?.queue.cancel(job) },
            onReveal: { [weak self] url in
                self?.mainMenu.cancelTracking()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: JobRowView.width, height: JobRowView.height)
        let item = NSMenuItem()
        item.view = host
        return item
    }

    // MARK: - Icon

    private func queueChanged() {
        if queue.hasActiveJobs {
            badgeTask?.cancel()
            badge = .none
            if iconTimer == nil {
                // .common mode keeps the ring moving while a menu is open.
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshIcon() }
                }
                RunLoop.main.add(timer, forMode: .common)
                iconTimer = timer
            }
        } else {
            iconTimer?.invalidate()
            iconTimer = nil
        }
        refreshIcon()
    }

    private func jobFinished(_ job: Job) {
        if case .failed = job.state { batchHadFailure = true }
        if case .succeeded(let url) = job.state { batchOutputs.append(url) }
        guard !queue.hasActiveJobs else { return }
        let failed = batchHadFailure
        batchHadFailure = false
        if settings?.revealAfterConverting == true, !batchOutputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(batchOutputs)
        }
        batchOutputs = []
        // A cancelled batch gets no badge.
        guard failed || job.state != .cancelled else { return }
        badge = failed ? .failed : .done
        refreshIcon()
        badgeTask?.cancel()
        badgeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: failed ? 4_000_000_000 : 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.badge = .none
            self.refreshIcon()
        }
    }

    private func refreshIcon() {
        statusItem.button?.image = StatusIcon.image(progress: queue.overallProgress, badge: badge)
    }
}
