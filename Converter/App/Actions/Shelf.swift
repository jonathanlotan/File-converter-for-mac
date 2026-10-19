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
                Text("Drop files here to keep them handy.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.items, id: \.self) { url in row(url) }
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

    private func row(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 28, height: 28)
            Text(url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button { model.remove(url) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Remove from the shelf")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(object: url as NSURL) }
        .help(url.path)
    }
}
