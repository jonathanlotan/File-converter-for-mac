import Foundation
import XCTest
@testable import ConverterCore

/// The guarantees every conversion relies on: output beside the original,
/// never overwritten, original untouched, nothing left behind on failure or
/// cancellation.
final class JobRunnerTests: XCTestCase {
    var folder: URL!
    var source: InputFile!

    override func setUpWithError() throws {
        folder = try makeTemporaryFolder("JobRunner")
        let url = folder.appendingPathComponent("photo.png")
        try Samples.write([Samples.testCard()], type: "public.png", to: url)
        source = try InputFile(url: url)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    func testNamesFollowFinderStyle() {
        XCTAssertEqual(OutputNamer.name(base: "photo", fileExtension: "jpg", attempt: 1), "photo.jpg")
        XCTAssertEqual(OutputNamer.name(base: "photo", fileExtension: "jpg", attempt: 2), "photo 2.jpg")
        XCTAssertEqual(OutputNamer.name(base: "photo", suffix: " (50%)", fileExtension: "jpg", attempt: 3), "photo (50%) 3.jpg")
        XCTAssertEqual(OutputNamer.name(base: "archive", fileExtension: "", attempt: 2), "archive 2")
    }

    func testOutputGoesBesideTheOriginalAndNeverOverwrites() async throws {
        let existing = folder.appendingPathComponent("photo.jpg")
        try Data("keep me".utf8).write(to: existing)
        let jpeg = try XCTUnwrap(ConverterRegistry.standard.converter(id: "image.jpeg"))

        let first = try await JobRunner.run(jpeg, on: source)
        let second = try await JobRunner.run(jpeg, on: source)

        XCTAssertEqual(first.lastPathComponent, "photo 2.jpg")
        XCTAssertEqual(second.lastPathComponent, "photo 3.jpg")
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep me".utf8), "existing file was overwritten")
        XCTAssertEqual(try folderContents(folder), ["photo 2.jpg", "photo 3.jpg", "photo.jpg", "photo.png"])
    }

    func testOriginalIsNeverModified() async throws {
        let before = try Data(contentsOf: source.url)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: source.url.path)
        for id in ["image.jpeg", "image.heic", "image.resize.50pct", "image.stripMetadata"] {
            try await JobRunner.run(XCTUnwrap(ConverterRegistry.standard.converter(id: id)), on: source)
        }
        XCTAssertEqual(try Data(contentsOf: source.url), before)
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: source.url.path)
        XCTAssertEqual(attributesBefore[.modificationDate] as? Date, attributesAfter[.modificationDate] as? Date)
    }

    func testFailureLeavesNoPartialFile() async throws {
        let recorder = DestinationRecorder()
        let failing = TestConverter(recorder: recorder) { destination in
            try Data(repeating: 7, count: 4096).write(to: destination)
            throw ConversionError.encoderFailed("simulated failure")
        }
        do {
            try await JobRunner.run(failing, on: source)
            XCTFail("expected an error")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .encoderFailed("simulated failure"))
        }
        XCTAssertEqual(try folderContents(folder), ["photo.png"])
        let staged = try XCTUnwrap(recorder.destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path),
                       "temporary folder wasn't removed")
    }

    func testCancellationLeavesNoPartialFile() async throws {
        let recorder = DestinationRecorder()
        let slow = TestConverter(recorder: recorder) { destination in
            try Data(repeating: 7, count: 4096).write(to: destination)
            while true { try await Task.sleep(nanoseconds: 5_000_000) } // until cancelled
        }
        let input = try XCTUnwrap(source)
        let job = Task { try await JobRunner.run(slow, on: input) }
        while recorder.destination == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        job.cancel()

        do {
            _ = try await job.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(try folderContents(folder), ["photo.png"])
        let staged = try XCTUnwrap(recorder.destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    func testCancellationOfARealConversion() async throws {
        let big = folder.appendingPathComponent("big.tiff")
        let page = Samples.testCard(width: 3000, height: 2000)
        try Samples.write(Array(repeating: page, count: 12), type: "public.tiff", to: big)
        let input = try InputFile(url: big)
        let pdf = try XCTUnwrap(ConverterRegistry.standard.converter(id: "image.pdf"))

        let started = DestinationRecorder()
        let job = Task {
            try await JobRunner.run(pdf, on: input) { fraction in if fraction > 0 { started.mark() } }
        }
        while !started.marked { try await Task.sleep(nanoseconds: 1_000_000) }
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("expected cancellation; the conversion finished before it could be cancelled")
        } catch is CancellationError {}
        XCTAssertEqual(try folderContents(folder), ["big.tiff", "photo.png"])
    }

    func testReadOnlyFolderFailsCleanly() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        let jpeg = try XCTUnwrap(ConverterRegistry.standard.converter(id: "image.jpeg"))
        do {
            try await JobRunner.run(jpeg, on: source)
            XCTFail("expected an error")
        } catch let error as ConversionError {
            guard case .destinationNotWritable = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertEqual(try folderContents(folder), ["photo.png"])
    }

    func testBatchReportsEachFile() async throws {
        let broken = folder.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        let jpeg = try XCTUnwrap(ConverterRegistry.standard.converter(id: "image.jpeg"))
        let progress = ProgressLog()
        let results = await JobRunner.run(jpeg, on: [source, try InputFile(url: broken)]) { progress.append($0) }

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(try results[0].get().lastPathComponent, "photo.jpg")
        XCTAssertThrowsError(try results[1].get())
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertEqual(progress.values, progress.values.sorted(), "progress went backwards")
    }
}

// MARK: - Test doubles

/// Thread-safe holder for values set from inside a running conversion.
final class DestinationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _destination: URL?
    private var _marked = false

    var destination: URL? { lock.withLock { _destination } }
    var marked: Bool { lock.withLock { _marked } }
    func record(_ url: URL) { lock.withLock { _destination = url } }
    func mark() { lock.withLock { _marked = true } }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Double] = []
    var values: [Double] { lock.withLock { _values } }
    func append(_ value: Double) { lock.withLock { _values.append(value) } }
}

/// A converter whose body is supplied by the test.
struct TestConverter: Converter {
    let recorder: DestinationRecorder
    let body: @Sendable (URL) async throws -> Void

    init(recorder: DestinationRecorder, body: @escaping @Sendable (URL) async throws -> Void) {
        self.recorder = recorder
        self.body = body
    }

    var id: String { "test" }
    var title: String { "Test" }
    var role: ConverterRole { .format }
    var isAvailable: Bool { true }
    func accepts(_ input: InputFile) -> Bool { true }
    func output(for input: InputFile) -> OutputSpec { OutputSpec(fileExtension: "out") }
    func convert(_ input: InputFile, to destination: URL, options: ConversionOptions, progress: ProgressHandler) async throws {
        recorder.record(destination)
        try await body(destination)
    }
}
