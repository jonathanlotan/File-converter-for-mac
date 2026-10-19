import AVFoundation
import ImageIO
import XCTest
@testable import ConverterCore

/// Converts every generated video, audio, document, PDF and archive sample
/// with every converter that accepts it, and checks each output: codec,
/// duration and size for media; text for documents; pages for PDFs; the
/// file tree for archives.
final class MediaMatrixTests: XCTestCase {
    var root: URL!
    var samples: [SampleFile] = []

    override func setUp() async throws {
        root = try makeTemporaryFolder("MediaMatrix")
        let folder = root.appendingPathComponent("samples", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        samples = try await MediaSamples.makeAll(in: folder)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEveryPair() async throws {
        // Converters that need several files (merge, combine) have their own tests.
        let converters = ConverterRegistry.standard.available.filter { !$0.id.hasPrefix("image.") && $0.minimumInputs == 1 }
        var exercised = Set<String>()
        var lines: [String] = []

        for sample in samples {
            let original = try InputFile(url: sample.url)
            let applicable = converters.filter { $0.accepts(original) }
            XCTAssertFalse(applicable.isEmpty, "nothing offered for \(sample)")
            for converter in applicable {
                let input = try copyAlone(sample.url)
                let label = "\(sample.name) → \(converter.title) [\(converter.id)]"
                let expectFailure = converter is AudioConverter && sample.kind == .video && !sample.hasAudio
                do {
                    let output = try await JobRunner.run(converter, on: input)
                    if expectFailure {
                        XCTFail("\(label): expected “no sound”")
                        lines.append("FAIL \(label)  (should have failed)")
                        continue
                    }
                    let problems = try await check(output, from: sample, made: converter)
                    problems.forEach { XCTFail("\(label): \($0)") }
                    lines.append("\(problems.isEmpty ? "ok  " : "FAIL") \(label)  (\(output.lastPathComponent))")
                } catch {
                    if expectFailure, error.localizedDescription.contains("has no sound") {
                        lines.append("ok   \(label)  (refused: no sound, as expected)")
                    } else if case ConversionError.nothingToDo(let reason)? = error as? ConversionError,
                              Self.mayDecline(converter, sample) {
                        lines.append("ok   \(label)  (declined: \(reason))")
                    } else {
                        XCTFail("\(label): \(error.localizedDescription)")
                        lines.append("FAIL \(label)  (\(error.localizedDescription))")
                    }
                }
                XCTAssertEqual(try Data(contentsOf: input.url), try Data(contentsOf: sample.url), "\(label): original changed")
                exercised.insert(converter.id)
            }
        }

        let missed = Set(converters.map(\.id)).subtracting(exercised)
        XCTAssertTrue(missed.isEmpty, "converters never tested: \(missed.sorted())")
        let report = "Media, document and archive matrix (\(lines.count) pairs)\n" + lines.joined(separator: "\n") + "\n"
        let reportURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("media-matrix.txt")
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
    }

    /// Tools that rightly decline these small samples: they never enlarge,
    /// and don't save a "compressed" file that isn't smaller. Each is
    /// checked on suitable input in the behaviour tests.
    static func mayDecline(_ converter: any Converter, _ sample: SampleFile) -> Bool {
        converter is ResizeVideoConverter || converter is CompressVideoConverter || converter is CompressPDFConverter
            || (converter is RemoveAudioConverter && !sample.hasAudio)
    }

    // MARK: - Checks

    private func copyAlone(_ url: URL) throws -> InputFile {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return try InputFile(url: copy)
    }

    func check(_ output: URL, from sample: SampleFile, made converter: any Converter) async throws -> [String] {
        switch converter {
        case let converter as VideoConverter:
            return try await checkVideo(output, from: sample, codec: [
                VideoFormat.mp4HEVC.id: "hvc1", VideoFormat.proRes.id: "apcn",
            ][converter.format.id] ?? "avc1")
        case is CompressVideoConverter:
            return try await checkVideo(output, from: sample, codec: "hvc1")
        case is ResizeVideoConverter:
            return ["a 320×240 sample can't be resized down to these presets"]
        case is RemoveAudioConverter:
            var silent = sample
            silent.hasAudio = false
            return try await checkVideo(output, from: silent, codec: "avc1")
        case is SplitPDFConverter:
            let names = (try? FileManager.default.contentsOfDirectory(atPath: output.path).sorted()) ?? []
            let pages = names.map { PDFFiles.pageCount(output.appendingPathComponent($0)) }
            return names.count == sample.pages && pages.allSatisfy({ $0 == 1 }) ? [] : ["split into \(names) with pages \(pages)"]
        case is CompressPDFConverter:
            return PDFFiles.pageCount(output) == sample.pages ? [] : ["page count changed"]
        case is RecognizeTextConverter:
            let text = try String(contentsOf: output, encoding: .utf8)
            return text.contains("Page 1") ? [] : ["recognised \(text.prefix(60).debugDescription)"]
        case is VideoToGIFConverter:
            return checkImage(output, type: "com.compuserve.gif", width: sample.width, height: sample.height,
                              frames: VideoToGIFConverter.frameCount(duration: sample.duration, fps: 10))
        case is VideoFrameConverter:
            return checkImage(output, type: "public.png", width: sample.width, height: sample.height, frames: 1)
        case let converter as AudioConverter:
            return try await checkAudio(output, from: sample, format: converter.format)
        case is TextDocumentConverter:
            let text = try await plainText(of: output)
            return text.contains(MediaSamples.phrase) ? [] : ["text missing; got \(text.prefix(80).debugDescription)"]
        case is PDFTextConverter:
            let text = try String(contentsOf: output, encoding: .utf8)
            return text.contains("Page \(sample.pages) of the \(MediaSamples.phrase)") ? [] : ["text missing"]
        case let converter as PDFToImagesConverter:
            return checkPages(output, from: sample, format: converter.format)
        case is ExtractArchiveConverter:
            return try checkTree(output, expected: sample.archiveContents, flatten: false)
        case is ConvertArchiveConverter, is CreateArchiveConverter:
            let extracted = root.appendingPathComponent("check-\(UUID().uuidString)", isDirectory: true)
            guard let kind = ArchiveKind.detect(try InputFile(url: output))?.kind else { return ["not an archive"] }
            try await Archives.extract(kind, from: output, into: extracted)
            if converter is CreateArchiveConverter {
                let names = try FileManager.default.contentsOfDirectory(atPath: extracted.path)
                return names == [sample.name] ? [] : ["archive holds \(names), expected [\(sample.name)]"]
            }
            return try checkTree(extracted, expected: sample.archiveContents, flatten: true)
        default:
            return ["no check for \(converter.id)"]
        }
    }

    func checkVideo(_ output: URL, from sample: SampleFile, codec: String) async throws -> [String] {
        let asset = AVURLAsset(url: output)
        var problems: [String] = []
        let duration = try await asset.load(.duration).seconds
        if abs(duration - sample.duration) > 0.1 { problems.append("duration \(duration), expected \(sample.duration)") }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return ["no video track"] }
        let size = try await track.load(.naturalSize)
        if Int(size.width) != sample.width || Int(size.height) != sample.height {
            problems.append("\(Int(size.width))×\(Int(size.height)), expected \(sample.width)×\(sample.height)")
        }
        if let description = try await track.load(.formatDescriptions).first {
            let actual = fourCC(CMFormatDescriptionGetMediaSubType(description))
            if actual != codec { problems.append("codec \(actual), expected \(codec)") }
        }
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        if hasAudio != sample.hasAudio { problems.append("audio track \(hasAudio), expected \(sample.hasAudio)") }
        return problems
    }

    func checkAudio(_ output: URL, from sample: SampleFile, format: AudioFormat) async throws -> [String] {
        guard let info = AudioInfo(url: output) else { return ["AudioToolbox can't open it"] }
        var problems: [String] = []
        if info.formatID != format.formatID { problems.append("codec \(fourCC(info.formatID)), expected \(fourCC(format.formatID))") }
        if info.channels != 2 { problems.append("\(info.channels) channels") }
        if format.isLossless && info.bitsPerSample != sample.bitsPerSample {
            problems.append("\(info.bitsPerSample)-bit, expected \(sample.bitsPerSample)-bit")
        }
        // AudioToolbox reads the exact length (FLAC STREAMINFO, M4A packet
        // table); AVFoundation rounds FLAC up to whole 4608-sample blocks.
        // ADTS records no length at all: AudioToolbox only estimates it from
        // the bit rate, so decode it instead. An ADTS *source* also can't mark
        // its encoder delay, so its decoded audio really is ~0.05 s longer.
        let duration = format == .aac ? try await AVURLAsset(url: output).load(.duration).seconds : info.duration
        let tolerance = format == .aac || sample.name.hasSuffix(".aac") ? 0.1 : 0.02
        if abs(duration - sample.duration) > tolerance {
            problems.append("duration \(duration), expected \(sample.duration)")
        }
        return problems
    }

    func checkImage(_ url: URL, type: String, width: Int, height: Int, frames: Int) -> [String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return ["not an image"] }
        var problems: [String] = []
        if CGImageSourceGetType(source) as String? != type { problems.append("type \(CGImageSourceGetType(source) as String? ?? "?")") }
        if CGImageSourceGetCount(source) != frames { problems.append("\(CGImageSourceGetCount(source)) frames, expected \(frames)") }
        let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
        if w != width || h != height { problems.append("\(w)×\(h), expected \(width)×\(height)") }
        return problems
    }

    func checkPages(_ output: URL, from sample: SampleFile, format: ImageFormat) -> [String] {
        // Letter pages at 150 dpi.
        let (w, h) = (1275, 1650)
        if sample.pages == 1 { return checkImage(output, type: format.typeIdentifier, width: w, height: h, frames: 1) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: output.path).sorted()) ?? []
        let expected = (1...sample.pages).map { "\(sample.url.deletingPathExtension().lastPathComponent) \($0).\(format.fileExtension)" }
        guard names == expected else { return ["folder holds \(names), expected \(expected)"] }
        return names.flatMap { checkImage(output.appendingPathComponent($0), type: format.typeIdentifier, width: w, height: h, frames: 1) }
    }

    func checkTree(_ output: URL, expected: [String: String], flatten: Bool) throws -> [String] {
        if Array(expected.keys) == [""] { // a single decompressed file
            let text = try String(contentsOf: output, encoding: .utf8)
            return text == expected[""] ? [] : ["decompressed text differs"]
        }
        var folder = output
        let top = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        if flatten, top.count == 1 { folder = folder.appendingPathComponent(top[0]) }
        let actual = try tree(of: folder)
        return actual == expected ? [] : ["tree \(actual.keys.sorted()), expected \(expected.keys.sorted())"]
    }

    func tree(of folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
            result[relative] = try String(contentsOf: url, encoding: .utf8)
        }
        return result
    }

    func plainText(of url: URL) async throws -> String {
        let output = try await Subprocess.run("/usr/bin/textutil", ["-convert", "txt", "-stdout", url.path])
        return String(decoding: output.stdout, as: UTF8.self)
    }
}

func fourCC(_ code: UInt32) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "\(code)"
}
