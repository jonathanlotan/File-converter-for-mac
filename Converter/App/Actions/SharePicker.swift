import AppKit

/// The system share picker, for the wheel's Share › More… and the menus'
/// Share item. It lists every sharing service and extension on this Mac
/// (Notes, Reminders, Freeform, third-party apps), and Edit Extensions.
@MainActor
final class SharePicker: NSObject, NSSharingServicePickerDelegate {
    static let shared = SharePicker()

    /// An invisible window at the pointer for the picker to point at; the
    /// wheel has already gone by the time it opens.
    private var anchor: NSPanel?
    /// Pickers stay alive until a service is chosen or they're dismissed.
    private var pickers: [NSSharingServicePicker] = []

    func show(_ urls: [URL], at screenPoint: NSPoint) {
        guard !urls.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let anchor = anchor ?? makeAnchor()
        self.anchor = anchor
        anchor.setFrameOrigin(NSPoint(x: screenPoint.x - 1, y: screenPoint.y - 1))
        anchor.orderFrontRegardless()
        guard let view = anchor.contentView else { return }
        let picker = makePicker(urls)
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// The standard Share menu item (with its submenu of services), for the
    /// Actions section of the format menus.
    func menuItem(for urls: [URL]) -> NSMenuItem {
        makePicker(urls).standardShareMenuItem
    }

    private func makePicker(_ urls: [URL]) -> NSSharingServicePicker {
        let picker = NSSharingServicePicker(items: urls)
        picker.delegate = self
        pickers.append(picker)
        // Menus are rebuilt each time; keep only recent pickers.
        if pickers.count > 8 { pickers.removeFirst(pickers.count - 8) }
        return picker
    }

    private func makeAnchor() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 2, height: 2),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    // MARK: - NSSharingServicePickerDelegate

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                                          didChoose service: NSSharingService?) {
        let chose = service != nil
        let picker = ObjectIdentifier(sharingServicePicker)
        MainActor.assumeIsolated {
            if chose {
                // AirDrop and some extensions show their panel in this app.
                NSApp.activate(ignoringOtherApps: true)
            }
            anchor?.orderOut(nil)
            pickers.removeAll { ObjectIdentifier($0) == picker }
        }
    }
}
