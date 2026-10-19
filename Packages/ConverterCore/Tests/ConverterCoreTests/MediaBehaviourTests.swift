import AVFoundation
import CoreGraphics
import XCTest
@testable import ConverterCore

/// Details beyond the matrix: naming of archives, path-escape safety,
/// "same format" rules, failure messages and cancelling a video export.
final class MediaBehaviourTests: XCTestCase {
    var folder: URL!

    override func setUp() async throws {
        folder = try makeTemporaryFolder("MediaBehaviour")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func converter(_ id: String) throws -> any Converter {
        try XCTUnwrap(ConverterRegistry.standard.converter(id: id), "missing \(id)")
    }

    private func write(_ text: String, _ name: String) throws -> InputFile {
        let url = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try InputFile(url: url)
    }

    private func ids(for input: InputFile) -> [String] {
        ConverterRegistry.standard.converters(for: [input]).map(\.id)
    }

    // MARK: Archives

    func testSeveralFilesMakeOneArchive() async throws {
        let a = try write("alpha", "a.txt"), b = try write("bravo", "b.txt")
        let zipper = try converter("archive.create.zip")
        let results = await JobRunner.run(zipper, on: [a, b])
        XCTAssertEqual(results.count, 1, "one archive for the selection")
        let zip = try XCTUnwrap(results.first).get()
        XCTAssertEqual(zip.lastPathComponent, "Archive.zip")
        let out = folder.appendingPathComponent("out")
        try await Archives.extract(.zip, from: zip, into: out)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(), ["a.txt", "b.txt"])
    }

    func testSingleItemsKeepTheirFullName() async throws {
        let report = try write("text", "report.pdf.txt")
        let zip = try await JobRunner.run(converter("archive.create.zip"), on: report)
        XCTAssertEqual(zip.lastPathComponent, "report.pdf.txt.zip")

        _ = try write("x", "photos/one.txt")
        let photos = try InputFile(url: folder.appendingPathComponent("photos"))
        XCTAssertTrue(photos.isDirectory)
        let tgz = try await JobRunner.run(converter("archive.create.tar.gz"), on: photos)
        XCTAssertEqual(tgz.lastPathComponent, "photos.tar.gz")
        let extracted = try await JobRunner.run(converter("archive.extract"), on: InputFile(url: tgz))
        XCTAssertEqual(extracted.lastPathComponent, "photos 2", "photos/ already exists, so the next free name")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: extracted.path), ["one.txt"],
                       "a single top-level folder isn't nested twice")
    }

    func testArchivesCantWriteOutsideTheirFolder() async throws {
        let inner = folder.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        let payload = inner.appendingPathComponent("payload.txt")
        try "escape".write(to: payload, atomically: true, encoding: .utf8)
        // bsdtar's -s rewrites the stored name to "../payload.txt".
        for (name, format) in [("evil.tar", "ustar"), ("evil.zip", "zip")] {
            try await Subprocess.run("/usr/bin/tar", ["--format", format, "-cf", inner.appendingPathComponent(name).path,
                                                      "-s", ",^,../,", "-C", inner.path, "payload.txt"])
        }
        let extract = try converter("archive.extract")
        let tar = await JobRunner.run(extract, on: [try InputFile(url: inner.appendingPathComponent("evil.tar"))])
        XCTAssertThrowsError(try tar[0].get(), "tar refuses '..' entries, so the extraction fails")
        _ = try? await JobRunner.run(extract, on: InputFile(url: inner.appendingPathComponent("evil.zip")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("payload.txt").path),
                       "nothing may land outside the extraction folder")
    }

    // MARK: Same-format rules

    func testSameFormatIsNotOffered() async throws {
        let wav = folder.appendingPathComponent("tone.wav")
        try MediaSamples.writeTone(to: wav, seconds: 0.5, bits: 16)
        let aac = folder.appendingPathComponent("tone.m4a"), alac = folder.appendingPathComponent("lossless.m4a")
        try await Subprocess.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", wav.path, aac.path])
        try await Subprocess.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "alac", wav.path, alac.path])

        XCTAssertFalse(ids(for: try InputFile(url: wav)).contains("audio.wav"))
        XCTAssertFalse(ids(for: try InputFile(url: aac)).contains("audio.m4a"), "AAC → AAC is pointless")
        XCTAssertTrue(ids(for: try InputFile(url: aac)).contains("audio.alac"))
        XCTAssertTrue(ids(for: try InputFile(url: alac)).contains("audio.m4a"), "Lossless → AAC is useful")
        XCTAssertFalse(ids(for: try InputFile(url: alac)).contains("audio.alac"))

        XCTAssertFalse(ids(for: try write("x", "a.txt")).contains("document.txt"))
        let rtf = folder.appendingPathComponent("a.rtf")
        try await Subprocess.run("/usr/bin/textutil", ["-convert", "rtf", "-output", rtf.path, folder.appendingPathComponent("a.txt").path])
        XCTAssertFalse(ids(for: try InputFile(url: rtf)).contains("document.rtf"))
    }

    func testSourceCodeAndSpreadsheetsAreNotTextDocuments() throws {
        for name in ["main.swift", "table.csv", "script.sh"] {
            XCTAssertFalse(ids(for: try write("x", name)).contains("document.rtf"), name)
        }
        XCTAssertTrue(ids(for: try write("# Title", "notes.md")).contains("document.rtf"))
    }

    func testLosslessAudioKeepsItsExactLength() async throws {
        // 1.5 s at 44.1 kHz = 66150 frames, which isn't a whole number of
        // 4608-frame FLAC blocks.
        let wav = folder.appendingPathComponent("tone.wav"), flac = folder.appendingPathComponent("tone.flac")
        try MediaSamples.writeTone(to: wav, seconds: 1.5, bits: 16)
        try await Subprocess.run("/usr/bin/afconvert", ["-f", "flac", "-d", "flac", wav.path, flac.path])
        let input = try InputFile(url: flac)
        XCTAssertEqual(input.audio?.exactFrames, 66150, "FLAC records its true length")

        let output = try await JobRunner.run(converter("audio.aiff"), on: input)
        XCTAssertEqual(AudioInfo(url: output)?.exactFrames, 66150, "no padding from FLAC's last block")
    }

    // MARK: Failures

    func testVideoWithoutSoundSaysSo() async throws {
        let silent = folder.appendingPathComponent("silent.mov")
        try await MediaSamples.writeVideo(to: silent, width: 64, height: 64, seconds: 0.5)
        do {
            try await JobRunner.run(converter("video.audio.m4a"), on: InputFile(url: silent))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "silent.mov has no sound.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["silent.mov"])
    }

    func testScannedPDFHasNoText() async throws {
        let pdf = folder.appendingPathComponent("scan.pdf")
        try Samples.write([Samples.testCard()], type: "com.adobe.pdf", to: pdf)
        do {
            try await JobRunner.run(converter("pdf.txt"), on: InputFile(url: pdf))
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("has no text"), error.localizedDescription)
        }
    }

    // MARK: Cancelling

    func testCancellingAVideoExportLeavesNothing() async throws {
        let clip = folder.appendingPathComponent("long.mov")
        try await MediaSamples.writeVideo(to: clip, width: 1280, height: 720, seconds: 8)
        let input = try InputFile(url: clip)
        let hevc = try converter("video.mp4-hevc")
        let started = ProgressLog()
        let job = Task { try await JobRunner.run(hevc, on: input) { started.append($0) } }
        while started.values.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        try await Task.sleep(nanoseconds: 150_000_000)
        job.cancel()
        do {
            _ = try await job.value
            XCTFail("the export finished before it could be cancelled")
        } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["long.mov"])
    }
}
