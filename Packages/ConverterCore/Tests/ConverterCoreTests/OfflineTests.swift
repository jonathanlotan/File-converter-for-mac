import Foundation
import XCTest

/// Swivel must never touch the network. This checks the built CLI (which
/// links all of ConverterCore) for networking symbols.
final class OfflineTests: XCTestCase {
    func testCLIUsesNoNetworkingAPIs() throws {
        let buildFolder = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = buildFolder.appendingPathComponent("swivel")
        guard FileManager.default.fileExists(atPath: cli.path) else {
            throw XCTSkip("swivel isn't built next to the tests (\(cli.path)); run `swift build` first")
        }
        let nm = Process()
        nm.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        nm.arguments = ["-u", cli.path]
        let pipe = Pipe()
        nm.standardOutput = pipe
        try nm.run()
        let symbols = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        nm.waitUntilExit()
        XCTAssertEqual(nm.terminationStatus, 0)

        let forbidden = ["URLSession", "NSURLConnection", "CFNetwork", "CFHTTP", "CFSocket", "_nw_", "getaddrinfo", "_connect"]
        let hits = symbols.split(separator: "\n").filter { line in forbidden.contains { line.contains($0) } }
        XCTAssertTrue(hits.isEmpty, "networking symbols found:\n\(hits.joined(separator: "\n"))")
    }
}
