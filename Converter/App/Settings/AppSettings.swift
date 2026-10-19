import ConverterCore
import Foundation
import ServiceManagement

/// Turning "open at login" on and off. Swappable so tests never add a real
/// login item to the Mac they run on.
@MainActor
protocol LoginItemControlling: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

/// The app itself as a login item (macOS 13 `SMAppService`, no helper app).
@MainActor
final class MainAppLoginItem: LoginItemControlling {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// A kind of file whose favourite output format the user can put first.
enum FormatKind: String, CaseIterable, Identifiable {
    case image, video, audio, document

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Documents"
        }
    }

    func includes(_ converter: any Converter) -> Bool {
        guard converter.role == .format else { return false }
        let id = converter.id
        switch self {
        case .image: return id.hasPrefix("image.") && !id.hasPrefix("image.video.")
        case .video: return id.hasPrefix("video.") && !id.hasPrefix("video.audio.")
        case .audio: return id.hasPrefix("audio.")
        case .document: return id.hasPrefix("document.")
        }
    }

    /// The formats offered for this kind, in menu order.
    func choices(in registry: ConverterRegistry) -> [any Converter] {
        registry.available.filter(includes)
    }
}

/// Everything in the settings window, saved in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let optionsKey = "ConversionOptions"
    static let preferredKey = "PreferredFormats"
    static let revealKey = "RevealAfterConverting"
    static let ringKeysKey = "RingKeys"
    static let terminalKey = "TerminalApp"
    static let menuBarIconKey = "ShowMenuBarIcon"

    /// Quality, bit rates and sizes the converters use.
    @Published var options: ConversionOptions {
        didSet {
            if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: Self.optionsKey) }
        }
    }
    /// `FormatKind.rawValue` → id of the converter to list first.
    @Published var preferredFormats: [String: String] {
        didSet { defaults.set(preferredFormats, forKey: Self.preferredKey) }
    }
    /// Select the results in Finder when a batch finishes.
    @Published var revealAfterConverting: Bool {
        didSet { defaults.set(revealAfterConverting, forKey: Self.revealKey) }
    }
    /// Which modifier key opens which ring during a drag.
    @Published var ringKeys: RingKeys {
        didSet {
            if let data = try? JSONEncoder().encode(ringKeys) { defaults.set(data, forKey: Self.ringKeysKey) }
        }
    }
    /// Show the icon in the menu bar. Apple's guidance: let people hide
    /// it, and don't rely on it being there (opening the app again shows
    /// Settings).
    @Published var showMenuBarIcon: Bool {
        didSet { defaults.set(showMenuBarIcon, forKey: Self.menuBarIconKey) }
    }
    /// Where the Terminal action opens folders.
    @Published var terminalApp: TerminalApp {
        didSet { defaults.set(terminalApp.rawValue, forKey: Self.terminalKey) }
    }
    @Published private(set) var loginStatus: SMAppService.Status
    @Published private(set) var loginError: String?

    private let defaults: UserDefaults
    private let loginItem: LoginItemControlling

    init(defaults: UserDefaults = .standard, loginItem: LoginItemControlling = MainAppLoginItem()) {
        self.defaults = defaults
        self.loginItem = loginItem
        options = defaults.data(forKey: Self.optionsKey)
            .flatMap { try? JSONDecoder().decode(ConversionOptions.self, from: $0) } ?? .default
        preferredFormats = defaults.dictionary(forKey: Self.preferredKey) as? [String: String] ?? [:]
        revealAfterConverting = defaults.bool(forKey: Self.revealKey)
        ringKeys = defaults.data(forKey: Self.ringKeysKey)
            .flatMap { try? JSONDecoder().decode(RingKeys.self, from: $0) } ?? .standard
        terminalApp = defaults.string(forKey: Self.terminalKey).flatMap(TerminalApp.init(rawValue:)) ?? .terminal
        showMenuBarIcon = defaults.object(forKey: Self.menuBarIconKey) as? Bool ?? true
        loginStatus = loginItem.status
    }

    /// Preferred converter ids, image first.
    var preferredFormatIDs: [String] {
        FormatKind.allCases.compactMap { preferredFormats[$0.rawValue] }
    }

    // MARK: Launch at login

    /// On, or waiting for the user to allow it in System Settings.
    var launchAtLogin: Bool {
        loginStatus == .enabled || loginStatus == .requiresApproval
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try loginItem.register() } else { try loginItem.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        refreshLoginStatus()
    }

    /// The user can change this in System Settings, so re-read it when the
    /// settings window opens.
    func refreshLoginStatus() {
        loginStatus = loginItem.status
    }

    func openLoginItemsSettings() {
        loginItem.openSystemSettings()
    }
}
