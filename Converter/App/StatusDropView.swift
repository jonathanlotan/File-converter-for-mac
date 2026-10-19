import AppKit

/// Transparent layer over the menu bar button that accepts dropped files.
/// Clicks fall through to the button: NSView's default `mouseDown` passes
/// the event up the responder chain to its superview.
final class StatusDropView: NSView {
    /// True while files hover over the icon.
    var onHover: ((Bool) -> Void)?
    /// Called after the drag session ends, with the dropped file URLs.
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    static func fileURLs(in info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !Self.fileURLs(in: sender).isEmpty else { return [] }
        onHover?(true)
        // Never a move: Finder must not move or delete the original.
        return DropOperation.safe(within: sender.draggingSourceOperationMask)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(in: sender).isEmpty ? [] : DropOperation.safe(within: sender.draggingSourceOperationMask)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHover?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(in: sender)
        onHover?(false)
        guard !urls.isEmpty else { return false }
        // Showing a menu inside the drop would hold up the source app's drag
        // session, so wait until it has ended.
        Task { @MainActor in self.onDrop?(urls) }
        return true
    }
}
