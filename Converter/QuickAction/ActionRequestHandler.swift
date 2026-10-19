import AppKit

/// "Convert with Converter" in Finder's Quick Actions (right-click and the
/// preview pane). App extensions must be sandboxed, so this one converts
/// nothing itself: it opens the chosen files with Converter, which shows
/// its format menu at the pointer and saves the results beside them.
final class ActionRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        // The extension context and its items are only used from this request.
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
        Task {
            let urls = await QuickActionSupport.fileURLs(from: items)
            guard !urls.isEmpty, let app = QuickActionSupport.hostApp(of: Bundle.main.bundleURL) else {
                context.cancelRequest(withError: CocoaError(.fileNoSuchFile))
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            do {
                _ = try await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
                context.completeRequest(returningItems: nil)
            } catch {
                context.cancelRequest(withError: error)
            }
        }
    }
}
