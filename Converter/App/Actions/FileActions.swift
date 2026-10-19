import AppKit
import ConverterCore

/// Something done *with* files rather than a conversion of them. Works for
/// any file or folder, including ones nothing can convert.
struct FileAction: Hashable, Identifiable {
    let id: String
    let title: String
    let symbol: String

    static let airDrop = FileAction(id: "action.airdrop", title: "AirDrop", symbol: "dot.radiowaves.left.and.right")
    static let float = FileAction(id: "action.float", title: "Float", symbol: "tray")
    static let copy = FileAction(id: "action.copy", title: "Copy", symbol: "doc.on.doc")
    static let move = FileAction(id: "action.move", title: "Move…", symbol: "folder")
    static let copyPath = FileAction(id: "action.copyPath", title: "Copy Path", symbol: "link")
    static let terminal = FileAction(id: "action.terminal", title: "Terminal", symbol: "terminal")

    static let all: [FileAction] = [airDrop, float, copy, move, copyPath, terminal]
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

    private let shelf: ShelfController?
    private let settings: AppSettings?

    init(shelf: ShelfController?, settings: AppSettings?) {
        self.shelf = shelf
        self.settings = settings
    }

    func perform(_ action: FileAction, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        switch action {
        case .airDrop: airDrop(urls)
        case .float: shelf?.add(urls)
        case .copy: copy(urls)
        case .move: if let folder = chooseFolder() { move(urls, to: folder) }
        case .copyPath: copyPaths(urls)
        case .terminal: openInTerminal(urls)
        default: break
        }
    }

    // MARK: - Actions

    func airDrop(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            report("AirDrop isn't available", "Turn on AirDrop in Control Center and try again.")
            return
        }
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
            report("No terminal app found", "Converter opens folders in Terminal or iTerm2.")
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
