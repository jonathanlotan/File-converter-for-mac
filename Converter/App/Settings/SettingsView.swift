import AppKit
import ConverterCore
import ServiceManagement
import SwiftUI

/// The settings window: launch at login, the Shift-drag switch, favourite
/// formats, and the quality settings the converters use.
struct SettingsView: View {
    enum Tab: String, CaseIterable {
        case general, formats, images, media, documents
    }

    @ObservedObject var settings: AppSettings
    @ObservedObject var shiftDrag: ShiftDragController
    let registry: ConverterRegistry
    @State var tab: Tab = .general

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(Tab.general)
            formats.tabItem { Label("Formats", systemImage: "star") }.tag(Tab.formats)
            images.tabItem { Label("Images", systemImage: "photo") }.tag(Tab.images)
            media.tabItem { Label("Video & Audio", systemImage: "film") }.tag(Tab.media)
            documents.tabItem { Label("Documents", systemImage: "doc.text") }.tag(Tab.documents)
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
                Toggle("Show converted files in Finder", isOn: $settings.revealAfterConverting)
                Picker("Open folders in", selection: $settings.terminalApp) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(app.isInstalled ? app.title : "\(app.title) (not installed)").tag(app)
                    }
                }
            } footer: {
                Text("Converter works offline. Results are saved next to the original, which is never changed.")
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

/// Owns the one settings window and brings it to the front.
@MainActor
final class SettingsWindowController {
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
        if window == nil {
            let view = SettingsView(settings: settings, shiftDrag: shiftDrag, registry: registry)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Converter Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // A menu bar app isn't active until asked.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
