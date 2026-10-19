import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import ConverterApp

/// The Services entry and the Quick Action extension: what they declare,
/// and the code that turns Finder's request into files for the app.
final class FinderIntegrationTests: XCTestCase {
    var folder: URL!

    override func setUpWithError() throws {
        folder = try makeTemporaryFolder("Finder")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Services

    @MainActor
    func testServiceHandsFilesToTheApp() async throws {
        let photo = try makeImage("photo.png", in: folder).url
        var received: [URL] = []
        let provider = ServicesProvider { received = $0 }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ConverterTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([photo as NSURL])

        var error: NSString?
        provider.convertFiles(pasteboard, userData: nil, error: &error)
        XCTAssertNil(error)
        XCTAssertTrue(received.isEmpty, "returns to the requesting app before showing the menu")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(received.map(\.standardizedFileURL), [photo.standardizedFileURL])
    }

    @MainActor
    func testServiceWithoutFilesReportsAnError() {
        let provider = ServicesProvider { _ in XCTFail("no files to hand over") }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ConverterTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        var error: NSString?
        provider.convertFiles(pasteboard, userData: nil, error: &error)
        XCTAssertEqual(error, "Swivel needs files to convert.")
    }

    func testAppDeclaresTheService() throws {
        let services = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]])
        let service = try XCTUnwrap(services.first)
        XCTAssertEqual(service["NSMessage"] as? String, ServicesProvider.messageName)
        XCTAssertEqual((service["NSMenuItem"] as? [String: String])?["default"], "Convert with Swivel…")
        XCTAssertEqual(service["NSSendFileTypes"] as? [String], ["public.item"])
        XCTAssertNotNil(service["NSRequiredContext"], "without it the service starts disabled")
        XCTAssertTrue(ServicesProvider.instancesRespond(to: NSSelectorFromString("convertFiles:userData:error:")))
    }

    // MARK: Quick Action

    func testExtensionIsEmbeddedAsAFinderAction() throws {
        let appex = Bundle.main.builtInPlugInsURL!.appendingPathComponent("ConverterQuickAction.appex")
        let info = try XCTUnwrap(Bundle(url: appex)?.infoDictionary)
        let ext = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.services")
        XCTAssertEqual(ext["NSExtensionPrincipalClass"] as? String, "ConverterQuickAction.ActionRequestHandler")
        let attributes = try XCTUnwrap(ext["NSExtensionAttributes"] as? [String: Any])
        XCTAssertEqual(attributes["NSExtensionServiceAllowsFinderPreviewItem"] as? Bool, true)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, "Convert with Swivel")

        // The activation rule must accept a Finder selection of files.
        let rule = try XCTUnwrap(attributes["NSExtensionActivationRule"] as? String)
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(contentsOf: try makeImage("x.png", in: folder).url)!]
        let predicate = NSPredicate(format: rule)
        XCTAssertTrue(predicate.evaluate(with: ["extensionItems": [["attachments": item.attachments!.map {
            ["registeredTypeIdentifiers": $0.registeredTypeIdentifiers]
        }]]]))
    }

    func testExtensionFindsItsHostApp() {
        let appex = URL(fileURLWithPath: "/Applications/Swivel.app/Contents/PlugIns/ConverterQuickAction.appex")
        XCTAssertEqual(QuickActionSupport.hostApp(of: appex)?.path, "/Applications/Swivel.app")
        XCTAssertNil(QuickActionSupport.hostApp(of: URL(fileURLWithPath: "/tmp/Loose.appex")))
        let real = Bundle.main.builtInPlugInsURL!.appendingPathComponent("ConverterQuickAction.appex")
        XCTAssertEqual(QuickActionSupport.hostApp(of: real)?.standardizedFileURL, Bundle.main.bundleURL.standardizedFileURL)
    }

    func testExtensionReadsFileURLsFromFinderItems() async throws {
        let a = try makeImage("a.png", in: folder).url
        let sub = folder.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(contentsOf: a)!, NSItemProvider(contentsOf: sub)!,
                            NSItemProvider(item: "text" as NSString, typeIdentifier: UTType.plainText.identifier)]
        let urls = await QuickActionSupport.fileURLs(from: [item])
        XCTAssertEqual(urls.map(\.standardizedFileURL.path), [a.standardizedFileURL.path, sub.standardizedFileURL.path],
                       "files and folders, not text")
    }
}
