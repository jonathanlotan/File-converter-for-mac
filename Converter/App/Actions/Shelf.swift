import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files parked on the floating shelf.
@MainActor
final class ShelfModel: ObservableObject {
    @Published private(set) var items: [URL] = []
    @Published var isPinned = false

    func add(_ urls: [URL]) {
        for url in urls.map(\.standardizedFileURL) where !items.contains(url) {
            items.append(url)
        }
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
    }

    func clear() {
        items.removeAll()
        isPinned = false
    }
}

/// The "Float" action: a small window that stays above other apps and
/// holds files until they're dragged somewhere else. It can be pinned to
/// the right edge of the screen.
@MainActor
final class ShelfController: NSObject, NSWindowDelegate {
    let model = ShelfModel()
    /// False in tests, so no window appears.
    var showsWindow = true
    private var panel: NSPanel?

    func add(_ urls: [URL]) {
        model.add(urls)
        if showsWindow { show() }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            panel.setFrameTopLeftPoint(NSPoint(x: mouse.x + 24, y: mouse.y + 24))
            panel.constrainToScreen()
        }
        panel.orderFrontRegardless()
    }

    /// Docks the shelf to the right edge of its screen, or frees it again.
    func togglePin() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        model.isPinned.toggle()
        panel.isMovable = !model.isPinned
        if model.isPinned {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width,
                                         y: visible.midY - panel.frame.height / 2))
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "Shelf"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 200, height: 160)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ShelfView(model: model, onPin: { [weak self] in self?.togglePin() }))
        return panel
    }

    func windowWillClose(_ notification: Notification) {
        model.clear()
        panel?.isMovable = true
    }
}

private extension NSPanel {
    func constrainToScreen() {
        guard let screen = screen ?? NSScreen.main else { return }
        setFrame(constrainFrameRect(frame, to: screen), display: false)
    }
}

/// The shelf's contents: drag a row out to use the file elsewhere.
struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    let onPin: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.items.count == 1 ? "1 item" : "\(model.items.count) items")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(action: onPin) {
                    Image(systemName: model.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(model.isPinned ? "Unpin from the screen edge" : "Pin to the screen edge")
                Button { model.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove everything from the shelf")
                    .disabled(model.items.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Drop files here to keep them handy.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.items, id: \.self) { url in ShelfRow(url: url) { model.remove(url) } }
                    }
                    .padding(6)
                }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.add([url]) }
                }
            }
            return true
        }
    }

}

/// One file on the shelf: icon, name, kind and size. Drag it out to use it.
private struct ShelfRow: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hovering = false

    private var details: String {
        let values = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey, .fileSizeKey, .isDirectoryKey])
        let kind = values?.localizedTypeDescription ?? ""
        guard values?.isDirectory != true, let size = values?.fileSize else { return kind }
        return "\(kind) · \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Remove from the shelf")
            .accessibilityLabel("Remove \(url.lastPathComponent) from the shelf")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        // Rounded inside the window's own corners, like a sidebar selection.
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help(url.path)
        .accessibilityElement(children: .combine)
    }
}
