import AppKit
import ConverterCore
import ServiceManagement
import SwiftUI
import XCTest
@testable import ConverterApp

/// Stands in for SMAppService so tests never add a real login item.
@MainActor
final class FakeLoginItem: LoginItemControlling {
    var status: SMAppService.Status = .notRegistered
    var statusAfterRegister: SMAppService.Status = .enabled
    var failure: (any Error)?
    var openedSettings = false

    func register() throws {
        if let failure { throw failure }
        status = statusAfterRegister
    }

    func unregister() throws { status = .notRegistered }
    func openSystemSettings() { openedSettings = true }
}

@MainActor
final class SettingsTests: XCTestCase {
    var suiteName: String!
    var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "ConverterTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSettingsArePersisted() {
        let settings = AppSettings(defaults: defaults, loginItem: FakeLoginItem())
        XCTAssertEqual(settings.options, .default, "defaults on first launch")
        settings.options.imageQuality = 0.7
        settings.options.videoCompression = .smaller
        settings.options.audioBitRate = 320
        settings.preferredFormats[FormatKind.image.rawValue] = "image.tga"
        settings.revealAfterConverting = true
        XCTAssertTrue(settings.showMenuBarIcon, "shown by default")
        settings.showMenuBarIcon = false

        let reloaded = AppSettings(defaults: defaults, loginItem: FakeLoginItem())
        XCTAssertFalse(reloaded.showMenuBarIcon)
        XCTAssertEqual(reloaded.options.imageQuality, 0.7)
        XCTAssertEqual(reloaded.options.videoCompression, .smaller)
        XCTAssertEqual(reloaded.options.audioBitRate, 320)
        XCTAssertEqual(reloaded.preferredFormatIDs, ["image.tga"])
        XCTAssertTrue(reloaded.revealAfterConverting)
    }

    func testLaunchAtLoginGoesThroughTheLoginItem() {
        let login = FakeLoginItem()
        let settings = AppSettings(defaults: defaults, loginItem: login)
        XCTAssertFalse(settings.launchAtLogin)
        settings.setLaunchAtLogin(true)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(login.status, .enabled)
        settings.setLaunchAtLogin(false)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(login.status, .notRegistered)
    }

    func testLoginItemWaitingForApprovalCountsAsOn() {
        let login = FakeLoginItem()
        login.statusAfterRegister = .requiresApproval
        let settings = AppSettings(defaults: defaults, loginItem: login)
        settings.setLaunchAtLogin(true)
        XCTAssertTrue(settings.launchAtLogin)
        XCTAssertEqual(settings.loginStatus, .requiresApproval)
        settings.openLoginItemsSettings()
        XCTAssertTrue(login.openedSettings)
    }

    func testLoginItemFailureIsShown() {
        let login = FakeLoginItem()
        login.failure = ConversionError.unsupported("Operation not permitted")
        let settings = AppSettings(defaults: defaults, loginItem: login)
        settings.setLaunchAtLogin(true)
        XCTAssertFalse(settings.launchAtLogin)
        XCTAssertEqual(settings.loginError, "Operation not permitted")
    }

    func testPreferredFormatComesFirstEvenFromMoreFormats() throws {
        let folder = try makeTemporaryFolder("Preferred")
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = try makeImage("photo.png", in: folder)
        let model = ConversionMenuModel(converters: ConverterRegistry.standard.converters(for: [input]),
                                        preferred: ["image.tga", "video.mp4"])
        guard case .converter(let first) = model.formats.first else { return XCTFail("expected a format first") }
        XCTAssertEqual(first.id, "image.tga")
        guard case .group(_, let more) = model.formats.last else { return XCTFail("expected More Formats last") }
        XCTAssertFalse(more.contains { $0.id == "image.tga" }, "not listed twice")
    }

    func testEachKindOffersItsOwnFormats() {
        let ids = { (kind: FormatKind) in kind.choices(in: .standard).map(\.id) }
        XCTAssertEqual(ids(.video), ["video.mp4", "video.mp4-hevc", "video.mov", "video.mov-prores", "video.m4v", "video.gif"])
        XCTAssertTrue(ids(.audio).contains("audio.flac"))
        XCTAssertFalse(ids(.image).contains("image.resize.50pct"), "tools aren't formats")
        XCTAssertFalse(ids(.image).contains("image.video.mp4"), "GIF → MP4 isn't an image format")
    }

    func testRenderSettingsTabs() throws {
        let settings = AppSettings(defaults: defaults, loginItem: FakeLoginItem())
        let shiftDrag = ShiftDragController(queue: JobQueue(), environment: FakeDragEnvironment(), defaults: defaults)
        defer { shiftDrag.watcher.stop() }
        let out = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Converter/Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for tab in SettingsView.Tab.allCases {
            let view = SettingsView(settings: settings, shiftDrag: shiftDrag, registry: .standard, tab: tab)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: out.appendingPathComponent("settings-\(tab.rawValue).png"))
            XCTAssertGreaterThan(size.height, 100, "\(tab) tab has content")
        }
    }
}
