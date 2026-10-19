import Foundation
import XCTest

/// Converter promises to work offline: neither the app (which links all of
/// ConverterCore) nor the Quick Action extension may call networking APIs.
final class OfflineAppTests: XCTestCase {
    static let networking = ["URLSession", "NSURLConnection", "CFNetwork", "CFHTTP", "CFSocket", "_nw_",
                             "getaddrinfo", "_connect", "WKWebView", "SFSafari"]

    private func undefinedSymbols(of binary: URL) throws -> [String] {
        let nm = Process()
        nm.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        nm.arguments = ["-u", binary.path]
        let pipe = Pipe()
        nm.standardOutput = pipe
        try nm.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        nm.waitUntilExit()
        XCTAssertEqual(nm.terminationStatus, 0)
        return output.split(separator: "\n").map(String.init)
    }

    func testAppAndExtensionUseNoNetworkingAPIs() throws {
        let app = try XCTUnwrap(Bundle.main.executableURL)
        let appex = try XCTUnwrap(Bundle.main.builtInPlugInsURL?
            .appendingPathComponent("ConverterQuickAction.appex/Contents/MacOS/ConverterQuickAction"))
        for binary in [app, appex] {
            let hits = try undefinedSymbols(of: binary).filter { symbol in Self.networking.contains { symbol.contains($0) } }
            XCTAssertTrue(hits.isEmpty, "\(binary.lastPathComponent) uses networking:\n\(hits.joined(separator: "\n"))")
        }
    }

    func testNoNetworkEntitlements() throws {
        // Not sandboxed (by design), so there are no network entitlements to
        // grant; the extension is sandboxed without the client entitlement.
        let appex = try XCTUnwrap(Bundle.main.builtInPlugInsURL?.appendingPathComponent("ConverterQuickAction.appex"))
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["-d", "--entitlements", "-", "--xml", appex.path]
        let pipe = Pipe()
        codesign.standardOutput = pipe
        codesign.standardError = FileHandle.nullDevice
        try codesign.run()
        let xml = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        codesign.waitUntilExit()
        XCTAssertTrue(xml.contains("com.apple.security.app-sandbox"))
        XCTAssertFalse(xml.contains("com.apple.security.network.client"))
    }
}
