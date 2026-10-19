import AppKit
import ConverterCore
import ServiceManagement
import SwiftUI

/// One pane of the settings window: launch at login and the wheel,
/// favourite formats, and the quality settings the converters use.
/// `SettingsWindowController` shows each pane as a toolbar tab.
struct SettingsView: View {
    enum Tab: String, CaseIterable {
        case general, formats, images, media, documents

        var title: String {
            switch self {
            case .general: return "General"
            case .formats: return "Formats"
            case .images: return "Images"
            case .media: return "Video & Audio"
            case .documents: return "Documents"
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .formats: return "star"
            case .images: return "photo"
            case .media: return "film"
            case .documents: return "doc.text"
            }
        }
    }

    @ObservedObject var settings: AppSettings
    @ObservedObject var shiftDrag: ShiftDragController
    let registry: ConverterRegistry
    let tab: Tab

    var body: some View {
        Group {
            switch tab {
            case .general: general
            case .formats: formats
            case .images: images
            case .media: media
            case .documents: documents
            }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                Toggle("Open Converter at login", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }))
                if settings.loginStatus == .requiresApproval {
                    HStack {
                        Text("Allow Converter in Login Items to finish turning this on.")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { settings.openLoginItemsSettings() }
                    }
                }
                if let error = settings.loginError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
            Section {
                Toggle("Open the wheel while dragging files", isOn: Binding(
                    get: { shiftDrag.isEnabled },
                    set: { shiftDrag.isEnabled = $0 }))
                ForEach(RingMode.allCases) { mode in
                    Picker(ringLabel(mode), selection: keyBinding(mode)) {
                        Text("No key").tag(ModifierKey?.none)
                        ForEach(ModifierKey.allCases) { key in
                            Text("\(key.symbol)  \(key.title)").tag(ModifierKey?.some(key))
                        }
                    }
                    .disabled(!shiftDrag.isEnabled)
                }
            } header: {
                Text("Wheel")
            } footer: {
                Text("Start dragging files, then tap a key to open its ring. Tap another key, or scroll, to switch rings. The wheel stays open until you drop.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show icon in menu bar", isOn: $settings.showMenuBarIcon)
                Toggle("Show converted files in Finder", isOn: $settings.revealAfterConverting)
                Picker("Open folders in", selection: $settings.terminalApp) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(app.isInstalled ? app.title : "\(app.title) (not installed)").tag(app)
                    }
                }
            } footer: {
                Text("Converter works offline. Results are saved next to the original, which is never changed. With the menu bar icon hidden, open Converter again to see these settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func ringLabel(_ mode: RingMode) -> String {
        switch mode {
        case .formats: return "Convert formats"
        case .tools: return "File tools"
        case .actions: return "File actions"
        }
    }

    /// Choosing a key another ring uses swaps the two.
    private func keyBinding(_ mode: RingMode) -> Binding<ModifierKey?> {
        Binding(
            get: { settings.ringKeys.key(for: mode) },
            set: { key in
                var keys = settings.ringKeys
                keys.assign(key, to: mode)
                settings.ringKeys = keys
            })
    }

    // MARK: Formats

    private var formats: some View {
        Form {
            Section {
                ForEach(FormatKind.allCases) { kind in
                    Picker(kind.title, selection: preferredBinding(kind)) {
                        Text("Standard order").tag("")
                        Divider()
                        ForEach(kind.choices(in: registry), id: \.id) { converter in
                            Text(converter.title).tag(converter.id)
                        }
                    }
                }
            } footer: {
                Text("The chosen format comes first in the menu and sits at the top of the Shift-drag ring.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func preferredBinding(_ kind: FormatKind) -> Binding<String> {
        Binding(
            get: { settings.preferredFormats[kind.rawValue] ?? "" },
            set: { settings.preferredFormats[kind.rawValue] = $0.isEmpty ? nil : $0 })
    }

    // MARK: Images

    private var images: some View {
        Form {
            Section {
                LabeledContent("JPEG, HEIC and AVIF quality") {
                    percentSlider($settings.options.imageQuality, in: 0.5...1)
                }
                LabeledContent("Compress image") {
                    percentSlider($settings.options.compressionQuality, in: 0.1...0.9)
                }
            } footer: {
                Text("Higher quality makes larger files. “Compress image” uses its own, lower setting.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Keep camera and location details (EXIF, GPS)", isOn: $settings.options.keepMetadata)
            }
        }
        .formStyle(.grouped)
    }

    private func percentSlider(_ value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        HStack {
            Slider(value: value, in: range, step: 0.05)
                .frame(width: 180)
            Text("\(Int((value.wrappedValue * 100).rounded())) %")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: Video & audio

    private var media: some View {
        Form {
            Section("Video") {
                Picker("Compress video", selection: $settings.options.videoCompression) {
                    Text("Smaller file").tag(ConversionOptions.VideoCompression.smaller)
                    Text("Balanced").tag(ConversionOptions.VideoCompression.balanced)
                    Text("Better quality").tag(ConversionOptions.VideoCompression.better)
                }
                Picker("GIF frame rate", selection: $settings.options.gifFrameRate) {
                    ForEach([5.0, 10, 15, 20, 30], id: \.self) { Text("\(Int($0)) fps").tag($0) }
                }
                Picker("GIF size", selection: $settings.options.gifMaxSide) {
                    ForEach([320, 480, 640, 800, 1080], id: \.self) { Text("\($0) px").tag($0) }
                }
            }
            Section("Audio") {
                Picker("AAC bit rate", selection: $settings.options.audioBitRate) {
                    ForEach([128, 192, 256, 320], id: \.self) { Text("\($0) kbit/s").tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Documents

    private var documents: some View {
        Form {
            Section {
                Picker("PDF pages as images", selection: $settings.options.pdfRenderDPI) {
                    Text("72 dpi (screen)").tag(72.0)
                    Text("150 dpi").tag(150.0)
                    Text("300 dpi (print)").tag(300.0)
                }
            } footer: {
                Text("Used by PDF → PNG, JPEG, HEIC and TIFF.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Owns the one settings window: a Mac-style settings window with a
/// toolbar tab per pane. The window takes the selected tab's name and
/// resizes to fit it; on macOS 26 and later the toolbar is Liquid Glass.
@MainActor
final class SettingsWindowController {
    static let selectedTabKey = "SettingsSelectedTab"

    private let settings: AppSettings
    private let shiftDrag: ShiftDragController
    private let registry: ConverterRegistry
    private var window: NSWindow?

    init(settings: AppSettings, shiftDrag: ShiftDragController, registry: ConverterRegistry) {
        self.settings = settings
        self.shiftDrag = shiftDrag
        self.registry = registry
    }

    func show() {
        settings.refreshLoginStatus()
        if window == nil { window = makeWindow() }
        // A menu bar app isn't active until asked.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let tabs = RememberingTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsView.Tab.allCases {
            let pane = NSHostingController(rootView: SettingsView(settings: settings, shiftDrag: shiftDrag,
                                                                   registry: registry, tab: tab))
            pane.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: pane)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = min(UserDefaults.standard.integer(forKey: Self.selectedTabKey),
                                            SettingsView.Tab.allCases.count - 1)

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ConverterSettings")
        if !window.setFrameUsingName("ConverterSettings") { window.center() }
        return window
    }
}

/// Reopens on the tab that was last used.
private final class RememberingTabViewController: NSTabViewController {
    override var selectedTabViewItemIndex: Int {
        didSet { UserDefaults.standard.set(selectedTabViewItemIndex, forKey: SettingsWindowController.selectedTabKey) }
    }
}
