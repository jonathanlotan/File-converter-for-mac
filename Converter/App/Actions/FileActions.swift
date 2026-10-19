import AppKit
import ConverterCore
import UniformTypeIdentifiers

/// Something done *with* files rather than a conversion of them. Works for
/// any file or folder, including ones nothing can convert.
struct FileAction: Hashable, Identifiable {
    let id: String
    let title: String
    let symbol: String
    /// Name of the sub-ring this action is grouped under ("Share").
    var group: String?

    static let airDrop = FileAction(id: "action.airdrop", title: "AirDrop", symbol: "dot.radiowaves.left.and.right",
                                    group: shareGroup)
    static let mail = FileAction(id: "action.share.mail", title: "Mail", symbol: "envelope", group: shareGroup)
    static let messages = FileAction(id: "action.share.messages", title: "Messages", symbol: "message", group: shareGroup)
    static let notes = FileAction(id: "action.share.notes", title: "Notes", symbol: "note.text", group: shareGroup)
    static let photos = FileAction(id: "action.share.photos", title: "Photos", symbol: "photo.on.rectangle", group: shareGroup)
    /// The system's share picker, with every service and extension.
    static let shareMore = FileAction(id: "action.share", title: "More…", symbol: "square.and.arrow.up", group: shareGroup)
    static let metadata = FileAction(id: "action.metadata", title: "Metadata", symbol: "info.circle")
    static let float = FileAction(id: "action.float", title: "Float", symbol: "tray")
    static let copy = FileAction(id: "action.copy", title: "Copy", symbol: "doc.on.doc")
    static let move = FileAction(id: "action.move", title: "Move…", symbol: "folder")
    static let copyPath = FileAction(id: "action.copyPath", title: "Copy Path", symbol: "link")
    static let terminal = FileAction(id: "action.terminal", title: "Terminal", symbol: "terminal")

    static let shareGroup = "Share"
    static let sharing: [FileAction] = [airDrop, mail, messages, notes, photos, shareMore]
    static let all: [FileAction] = sharing + [metadata, float, copy, move, copyPath, terminal]

    /// The system sharing service behind a Share action. Notes has no
    /// public name; its extension's identifier is used, and Notes is simply
    /// left out if a later macOS renames it (it's still under More…).
    var sharingService: NSSharingService.Name? {
        switch id {
        case Self.airDrop.id: return .sendViaAirDrop
        case Self.mail.id: return .composeEmail
        case Self.messages.id: return .composeMessage
        case Self.notes.id: return NSSharingService.Name("com.apple.Notes.SharingExtension")
        case Self.photos.id: return .addToIPhoto
        default: return nil
        }
    }

    /// The actions that can handle `urls` on this Mac: share services that
    /// aren't installed, or can't take these files, are left out.
    @MainActor
    static func available(for urls: [URL],
                          service: (NSSharingService.Name) -> NSSharingService? = { NSSharingService(named: $0) }) -> [FileAction] {
        all.filter { action in
            guard let name = action.sharingService else { return true }
            if action == .photos && !urls.allSatisfy(isPhotoOrVideo) { return false }
            return service(name)?.canPerform(withItems: urls) ?? false
        }
    }

    private static func isPhotoOrVideo(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }
}

/// Carries out file actions. System pieces (pasteboard, folder picker,
/// app launching) are injectable so tests don't touch the real ones.
@MainActor
final class FileActionPerformer {
    var pasteboard: NSPasteboard = .general
    /// Asks where to move files; nil means the user cancelled.
    var chooseFolder: @MainActor () -> URL? = FileActionPerformer.askForFolder
    /// Opens folders in a terminal app.
    var openFolders: @MainActor ([URL], URL) -> Void = { folders, app in
        NSWorkspace.shared.open(folders, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
    /// Tells the user something went wrong (an alert; tests capture it).
    var report: @MainActor (String, String) -> Void = FileActionPerformer.alert
    /// Looks up a system sharing service (tests supply their own).
    var sharingService: @MainActor (NSSharingService.Name) -> NSSharingService? = { NSSharingService(named: $0) }
    /// Shows the system share picker at the pointer.
    var showSharePicker: @MainActor ([URL]) -> Void = { SharePicker.shared.show($0, at: NSEvent.mouseLocation) }
    /// Opens the metadata window.
    var showMetadata: @MainActor ([URL]) -> Void = { _ in }

    private let shelf: ShelfController?
    private let settings: AppSettings?

    init(shelf: ShelfController?, settings: AppSettings?) {
        self.shelf = shelf
        self.settings = settings
    }

    func perform(_ action: FileAction, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch action {
        case .shareMore: showSharePicker(urls)
        case .metadata: showMetadata(urls)
        case .float: shelf?.add(urls)
        case .copy: copy(urls)
        case .move: if let folder = chooseFolder() { move(urls, to: folder) }
        case .copyPath: copyPaths(urls)
        case .terminal: openInTerminal(urls)
        default: if action.sharingService != nil { share(urls, with: action) }
        }
    }

    // MARK: - Actions

    /// Hands the files to AirDrop, Mail, Messages, Notes or Photos.
    func share(_ urls: [URL], with action: FileAction) {
        guard let name = action.sharingService, let service = sharingService(name), service.canPerform(withItems: urls) else {
            let advice = action == .airDrop ? "Turn on AirDrop in Control Center and try again."
                                            : "Try More… to choose another way to share."
            report("\(action.title) can't share these files", advice)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: urls)
    }

    /// Files on the pasteboard, ready to paste in Finder (which copies them).
    func copy(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    /// Full paths as text, one per line.
    func copyPaths(_ urls: [URL]) {
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    /// Moves the originals into `folder`. A name that's taken there gets
    /// " 2", " 3"... like Finder's "Keep Both"; nothing is replaced.
    @discardableResult
    func move(_ urls: [URL], to folder: URL) -> [Result<URL, any Error>] {
        let results: [Result<URL, any Error>] = urls.map { url in
            Result {
                guard url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL else { return url }
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                // A folder keeps its whole name ("v1.2" isn't an extension).
                let base = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
                let spec = OutputSpec(fileExtension: isFolder ? "" : url.pathExtension, isDirectory: isFolder)
                let target = OutputNamer.firstAvailable(in: folder, base: base, spec: spec)
                try FileManager.default.moveItem(at: url, to: target)
                return target
            }
        }
        let failures = results.compactMap { result -> String? in
            if case .failure(let error) = result { return error.localizedDescription }
            return nil
        }
        if !failures.isEmpty {
            report("Some files couldn't be moved", failures.joined(separator: "\n"))
        }
        return results
    }

    /// Folders to open: a folder itself, or the folder a file is in.
    static func terminalFolders(for urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let folder = isFolder ? url : url.deletingLastPathComponent()
            return seen.insert(folder.standardizedFileURL.path).inserted ? folder : nil
        }
    }

    func openInTerminal(_ urls: [URL]) {
        guard let app = settings?.terminalApp.url ?? TerminalApp.terminal.url else {
            report("No terminal app found", "Swivel opens folders in Terminal or iTerm2.")
            return
        }
        // A handful of windows at most.
        openFolders(Array(Self.terminalFolders(for: urls).prefix(5)), app)
    }

    // MARK: - Helpers

    static func askForFolder() -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to move the files."
        panel.prompt = "Move Here"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func alert(_ title: String, _ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// Where "Terminal" opens folders.
enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal, iTerm

    var id: String { rawValue }
    var title: String { self == .terminal ? "Terminal" : "iTerm2" }
    var bundleIdentifier: String { self == .terminal ? "com.apple.Terminal" : "com.googlecode.iterm2" }
    var url: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) }
    var isInstalled: Bool { url != nil }
}
