import AppKit

/// Handles "Convert with Converter…" in the Services menu (Finder's
/// right-click > Services, and any app that shares files). Declared under
/// `NSServices` in Info.plist; works without an extension or the sandbox.
@MainActor
final class ServicesProvider: NSObject {
    nonisolated static let messageName = "convertFiles"

    private let onFiles: ([URL]) -> Void

    init(onFiles: @escaping ([URL]) -> Void) {
        self.onFiles = onFiles
    }

    /// Called by AppKit for the `convertFiles` service message.
    @objc func convertFiles(_ pasteboard: NSPasteboard, userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = "Converter needs files to convert." as NSString
            return
        }
        // Return to the requesting app at once; the menu follows.
        Task { @MainActor in self.onFiles(urls) }
    }
}
