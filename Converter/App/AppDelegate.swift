import AppKit
import Combine
import ConverterCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let queue = JobQueue()
    /// ConverterCore's converters plus the app's own, which need AppKit.
    private(set) lazy var registry = ConverterRegistry(ConverterRegistry.standard.everything + [
        RichTextPDFConverter(),
        CustomCropTool { [weak self] inputs in self?.cropEditor.open(inputs) },
    ])
    private(set) lazy var cropEditor = CropEditorController(queue: queue)
    private(set) lazy var metadataWindow = MetadataWindowController { [weak self] input in
        self?.queue.enqueue(StripImageMetadataConverter(), on: [input])
    }
    let settings = AppSettings()
    /// The "Float" shelf, shared by the wheel and the menus.
    let shelf = ShelfController()
    private(set) var statusItem: StatusItemController?
    private(set) var shiftDrag: ShiftDragController?
    private var settingsWindow: SettingsWindowController?
    private var servicesProvider: ServicesProvider?
    private var optionsSubscription: AnyCancellable?

    // Set up before launch finishes: files opened with the app ("Open With",
    // dropped on its icon) arrive between willFinish and didFinish.
    func applicationWillFinishLaunching(_ notification: Notification) {
        ImageRasterizers.register(SVGRasterizer())
        // New jobs always use the current settings.
        optionsSubscription = settings.$options.sink { [weak self] options in self?.queue.options = options }

        let settings = settings
        let actions = FileActionPerformer(shelf: shelf, settings: settings)
        actions.showMetadata = { [weak self] urls in self?.metadataWindow.show(urls) }
        let shiftDrag = ShiftDragController(queue: queue, registry: registry, preferred: { settings.preferredFormatIDs },
                                            ringKeys: { settings.ringKeys }, actions: actions)
        self.shiftDrag = shiftDrag
        let settingsWindow = SettingsWindowController(settings: settings, shiftDrag: shiftDrag, registry: registry)
        self.settingsWindow = settingsWindow
        let statusItem = StatusItemController(queue: queue, registry: registry, shiftDrag: shiftDrag,
                                              settings: settings, actions: actions, showSettings: { settingsWindow.show() })
        self.statusItem = statusItem

        // "Convert with Converter…" in Finder's right-click > Services.
        let services = ServicesProvider { [weak statusItem] urls in statusItem?.offerConversions(for: urls, at: .cursor) }
        servicesProvider = services
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    /// Opening the app while it runs (Finder, Spotlight, Launchpad) shows
    /// Settings, so it's reachable even with the menu bar icon hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settingsWindow?.show()
        return false
    }

    /// Files sent by Finder: Open With, a drop on the app's icon, or the
    /// Quick Action extension (which hands its files to the app this way).
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in self.statusItem?.offerConversions(for: urls, at: .cursor) }
    }

    /// Cancels running conversions and waits briefly for them to clean up
    /// their temporary files before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard queue.hasActiveJobs else { return .terminateNow }
        queue.cancelAll()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(3)
            while queue.hasActiveJobs && Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
