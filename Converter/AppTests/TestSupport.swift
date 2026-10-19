import ConverterCore
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import ConverterApp

/// A fresh folder per test, outside iCloud-synced locations.
func makeTemporaryFolder(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes a solid red PNG (or another ImageIO type) and returns it as an input.
func makeImage(_ name: String, in folder: URL, width: Int = 320, height: Int = 200,
               type: String = "public.png") throws -> InputFile {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let url = folder.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return try InputFile(url: url)
}

func folderContents(_ folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
}

/// Waits until the queue has nothing running or waiting.
@MainActor
func waitUntilIdle(_ queue: JobQueue, timeout: TimeInterval = 15) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while queue.hasActiveJobs {
        guard Date() < deadline else { return XCTFail("queue still busy after \(timeout) s") }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

/// A converter that writes a partial file, then waits until the test opens
/// the gate (or the job is cancelled).
struct GatedConverter: Converter {
    let gate: Gate
    var id: String = "test.gated"
    var title: String { "Gated" }
    var role: ConverterRole { .format }
    var isAvailable: Bool { true }
    func accepts(_ input: InputFile) -> Bool { true }
    func output(for input: InputFile) -> OutputSpec { OutputSpec(fileExtension: "out") }
    func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        gate.started()
        try Data(repeating: 1, count: 1024).write(to: destination)
        while !gate.isOpen { try await Task.sleep(nanoseconds: 5_000_000) }
    }
}

/// Always fails after writing a partial file.
struct FailingConverter: Converter {
    var id: String { "test.failing" }
    var title: String { "Failing" }
    var role: ConverterRole { .format }
    var isAvailable: Bool { true }
    func accepts(_ input: InputFile) -> Bool { true }
    func output(for input: InputFile) -> OutputSpec { OutputSpec(fileExtension: "out") }
    func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        try Data(repeating: 1, count: 1024).write(to: destination)
        throw ConversionError.encoderFailed("simulated")
    }
}

final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var starts = 0
    var isOpen: Bool { lock.withLock { open } }
    var startCount: Int { lock.withLock { starts } }
    func openGate() { lock.withLock { open = true } }
    func started() { lock.withLock { starts += 1 } }
}
