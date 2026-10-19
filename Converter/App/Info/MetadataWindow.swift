import AppKit
import Combine
import ConverterCore
import QuickLookThumbnailing
import SwiftUI

/// What the metadata window shows: one file of the selection at a time.
@MainActor
final class MetadataModel: ObservableObject {
    let urls: [URL]
    @Published private(set) var index = 0
    @Published private(set) var sections: [MetadataSection] = []
    @Published private(set) var isLoading = true
    @Published private(set) var thumbnail: NSImage?
    /// True for an image with camera, location or descriptive tags that
    /// Remove Metadata can take out.
    @Published private(set) var canRemoveMetadata = false
    private var loading: Task<Void, Never>?

    /// `urls` must not be empty.
    init(urls: [URL], loadsThumbnails: Bool = true) {
        self.urls = urls
        self.loadsThumbnails = loadsThumbnails
        load()
    }

    private let loadsThumbnails: Bool

    var url: URL { urls[index] }

    /// "JPEG image · 2.4 MB": the start of the File section.
    var summary: String {
        let file = sections.first { $0.title == "File" }
        return [file?["Kind"], file?["Size"].map { $0.components(separatedBy: " (").first ?? $0 }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Everything shown, as text.
    var text: String {
        url.lastPathComponent + "\n\n" + FileMetadata.text(sections)
    }

    func show(_ newIndex: Int) {
        guard urls.indices.contains(newIndex), newIndex != index else { return }
        index = newIndex
        load()
    }

    /// Waits for the current file's details (for tests).
    func loaded() async {
        await loading?.value
    }

    private func load() {
        loading?.cancel()
        isLoading = true
        canRemoveMetadata = false
        thumbnail = NSWorkspace.shared.icon(forFile: url.path)
        let url = url
        loading = Task { [weak self] in
            let sections = await FileMetadata.sections(for: url)
            guard let self, !Task.isCancelled else { return }
            self.sections = sections
            self.isLoading = false
            let tagged = sections.contains { ["Camera", "Location", "Description"].contains($0.title) }
            self.canRemoveMetadata = tagged && (try? InputFile(url: url)).map(StripImageMetadataConverter().accepts) == true
        }
        guard loadsThumbnails else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            guard let image = representation?.cgImage else { return }
            let size = representation?.contentRect.size ?? CGSize(width: 64, height: 64)
            Task { @MainActor [weak self] in
                guard let self, self.url == url else { return }
                self.thumbnail = NSImage(cgImage: image, size: size)
            }
        }
    }
}

/// The "Metadata" action's window: file facts, then camera, location,
/// media or PDF details, all selectable, with Copy All.
@MainActor
final class MetadataWindowController: NSObject, NSWindowDelegate {
    /// Saves a copy of an image without its metadata.
    private let removeMetadata: (InputFile) -> Void
    private var window: NSWindow?
    private(set) var model: MetadataModel?
    private var title: AnyCancellable?
    var pasteboard: NSPasteboard = .general
    /// False in tests, so no window appears.
    var showsWindow = true

    init(removeMetadata: @escaping (InputFile) -> Void) {
        self.removeMetadata = removeMetadata
    }

    func show(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let model = MetadataModel(urls: urls, loadsThumbnails: showsWindow)
        self.model = model
        guard showsWindow else { return }

        let window = self.window ?? makeWindow()
        self.window = window
        let view = MetadataView(model: model,
                                onCopy: { [weak self] in self?.copy(model.text) },
                                onRemoveMetadata: { [weak self] in
                                    if let input = try? InputFile(url: model.url) { self?.removeMetadata(input) }
                                })
        window.contentView = NSHostingView(rootView: view)
        title = model.$index.sink { [weak window] index in
            window?.title = urls[index].lastPathComponent
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func copy(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.subtitle = "Metadata"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 360, height: 320)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("ConverterMetadata")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model = nil
        title = nil
    }
}

struct MetadataView: View {
    @ObservedObject var model: MetadataModel
    let onCopy: () -> Void
    let onRemoveMetadata: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(16)
            Divider()
            if model.isLoading && model.sections.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    ForEach(model.sections) { section in
                        Section(section.title) {
                            ForEach(section.fields) { field in
                                LabeledContent(field.label) {
                                    Text(field.value)
                                        .textSelection(.enabled)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail = model.thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Color.clear
                }
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(model.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.urls.count > 1 {
                Button { model.show(model.index - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.index == 0)
                    .help("Previous file")
                    .accessibilityLabel("Previous file")
                Text("\(model.index + 1) of \(model.urls.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button { model.show(model.index + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.index + 1 == model.urls.count)
                    .help("Next file")
                    .accessibilityLabel("Next file")
            }
            Spacer()
            if model.canRemoveMetadata {
                Button("Remove Metadata", action: onRemoveMetadata)
                    .help("Saves a copy with the camera, location and description tags removed. The original stays as it is.")
            }
            Button("Copy All", action: onCopy)
                .disabled(model.sections.isEmpty)
        }
    }
}
