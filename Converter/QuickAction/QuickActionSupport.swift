import Foundation
import UniformTypeIdentifiers

/// The Quick Action's logic, kept apart from the request handler so the
/// app's tests can compile and exercise it too.
enum QuickActionSupport {
    /// Converter.app, found from the extension's own bundle at
    /// Converter.app/Contents/PlugIns/ConverterQuickAction.appex.
    static func hostApp(of extensionBundle: URL) -> URL? {
        let app = extensionBundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    /// File and folder URLs from the items Finder hands the action.
    static func fileURLs(from items: [NSExtensionItem]) async -> [URL] {
        var urls: [URL] = []
        for provider in items.flatMap({ $0.attachments ?? [] })
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadURL(from: provider) { urls.append(url) }
        }
        return urls
    }

    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                switch item {
                case let url as URL: continuation.resume(returning: url.isFileURL ? url : nil)
                case let data as Data: continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                default: continuation.resume(returning: nil)
                }
            }
        }
    }
}
