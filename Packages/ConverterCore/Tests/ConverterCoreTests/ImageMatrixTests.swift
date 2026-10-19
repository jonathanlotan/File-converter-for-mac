import AVFoundation
import CoreGraphics
import ImageIO
import XCTest
@testable import ConverterCore

/// Converts every generated sample to every format the registry offers for
/// it, and checks each output's type, size, frame or page count, or duration.
final class ImageMatrixTests: XCTestCase {
    var root: URL!
    var fixtures: [Fixture] = []

    override func setUpWithError() throws {
        root = try makeTemporaryFolder("ImageMatrix")
        let samples = root.appendingPathComponent("samples", isDirectory: true)
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        fixtures = try Samples.makeAll(in: samples)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testFixturesAreReadable() throws {
        for fixture in fixtures {
            let input = try InputFile(url: fixture.url)
            let info = try XCTUnwrap(input.image, "\(fixture) isn't readable by ImageIO")
            XCTAssertEqual(info.width, fixture.width, "\(fixture) width")
            XCTAssertEqual(info.height, fixture.height, "\(fixture) height")
            XCTAssertEqual(info.isAnimated, fixture.animated, "\(fixture) animated")
            XCTAssertEqual(info.frameCount, fixture.frames, "\(fixture) frames")
        }
    }

    func testEveryFormatPair() async throws {
        let formatConverters = ConverterRegistry.standard.available.filter { $0.role == .format && $0.id.hasPrefix("image.") }
        var exercised = Set<String>()
        var lines: [String] = []

        for fixture in fixtures {
            let original = try InputFile(url: fixture.url)
            let applicable = formatConverters.filter { $0.accepts(original) }
            XCTAssertFalse(applicable.isEmpty, "no formats offered for \(fixture)")

            for converter in applicable {
                let input = try isolatedCopy(of: fixture, in: root)
                let before = try Data(contentsOf: input.url)
                let label = "\(fixture.name) → \(converter.title)"
                do {
                    let output = try await JobRunner.run(converter, on: input)
                    XCTAssertEqual(output.deletingLastPathComponent(), input.url.deletingLastPathComponent(),
                                   "\(label): output not beside the original")
                    XCTAssertEqual(try Data(contentsOf: input.url), before, "\(label): original was modified")
                    let problems = try await check(output, of: fixture, made: converter)
                    problems.forEach { XCTFail("\(label): \($0)") }
                    lines.append("\(problems.isEmpty ? "ok  " : "FAIL") \(label)  (\(output.lastPathComponent))")
                } catch where Self.mayDecline(fixture, converter) {
                    lines.append("ok   \(label)  (declined on this macOS: \(error.localizedDescription))")
                } catch {
                    XCTFail("\(label): \(error.localizedDescription)")
                    lines.append("FAIL \(label)  (\(error.localizedDescription))")
                }
                exercised.insert(converter.id)
            }
        }

        let unexercised = Set(formatConverters.map(\.id)).subtracting(exercised)
        XCTAssertTrue(unexercised.isEmpty, "formats never tested: \(unexercised.sorted())")
        // Written next to the test bundle (the build folder) for review.
        let report = "Image format matrix (\(lines.count) pairs)\n" + lines.joined(separator: "\n") + "\n"
        let reportURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("image-matrix.txt")
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
        print("Image format matrix: \(lines.count) pairs, report at \(reportURL.path)")
    }

    /// Runs every single-file image tool on every sample it's offered for,
    /// plus a large noisy photo so Fit to Size has something to do. Presets
    /// of one tool (Resize 3840 px) can't all apply to small samples, so
    /// coverage is checked per kind of tool.
    func testEveryTool() async throws {
        let tools = ConverterRegistry.standard.available.filter {
            $0.role == .tool && $0.id.hasPrefix("image.") && $0.minimumInputs == 1
        }
        let large = root.appendingPathComponent("samples/large.jpg")
        try Samples.write([ImageEditTests.noise(width: 1200, height: 800)], type: "public.jpeg", to: large,
                          frameProperties: [kCGImageDestinationLossyCompressionQuality: 0.95])
        let all = fixtures + [Fixture(url: large, width: 1200, height: 800, frames: 1, animated: false, dpi: 72, duration: 0)]
        var exercised = Set<String>()
        var lines: [String] = []

        for fixture in all {
            let original = try InputFile(url: fixture.url)
            for tool in tools where tool.accepts(original) {
                let input = try isolatedCopy(of: fixture, in: root)
                let before = try Data(contentsOf: input.url)
                let label = "\(fixture.name) → \(tool.title) [\(tool.id)]"
                do {
                    let output = try await JobRunner.run(tool, on: input)
                    XCTAssertEqual(output.deletingLastPathComponent(), input.url.deletingLastPathComponent(),
                                   "\(label): output not beside the original")
                    let problems = checkTool(output, of: fixture, made: tool, spec: tool.output(for: input))
                    problems.forEach { XCTFail("\(label): \($0)") }
                    lines.append("\(problems.isEmpty ? "ok  " : "FAIL") \(label)  (\(output.lastPathComponent))")
                } catch let ConversionError.nothingToDo(reason) where tool is RemoveBackgroundConverter {
                    // A test card may have nothing that looks like a subject.
                    lines.append("ok   \(label)  (declined: \(reason))")
                } catch {
                    XCTFail("\(label): \(error.localizedDescription)")
                    lines.append("FAIL \(label)  (\(error.localizedDescription))")
                }
                XCTAssertEqual(try Data(contentsOf: input.url), before, "\(label): original was modified")
                exercised.insert(String(describing: type(of: tool)))
            }
        }

        let kinds = Set(tools.map { String(describing: type(of: $0)) })
        XCTAssertTrue(kinds.subtracting(exercised).isEmpty, "tools never tested: \(kinds.subtracting(exercised).sorted())")
        let report = "Image tool matrix (\(lines.count) runs)\n" + lines.joined(separator: "\n") + "\n"
        let reportURL = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("image-tool-matrix.txt")
        try report.write(to: reportURL, atomically: true, encoding: .utf8)
    }

    /// Everything that's wrong with a tool's `output`: it must open as the
    /// promised format, and rotations and size limits must hold.
    func checkTool(_ output: URL, of fixture: Fixture, made tool: any Converter, spec: OutputSpec) -> [String] {
        guard output.pathExtension == spec.fileExtension else {
            return ["saved as .\(output.pathExtension), expected .\(spec.fileExtension)"]
        }
        guard let source = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), nil)
        else { return ["not a readable image"] }
        var problems: [String] = []
        switch tool {
        case let tool as RotateImageConverter:
            let (w, h) = tool.turn.isQuarterTurn ? (fixture.height, fixture.width) : (fixture.width, fixture.height)
            if image.width != w || image.height != h {
                problems.append("\(image.width)×\(image.height), expected \(w)×\(h)")
            }
            if fixture.animated && CGImageSourceGetCount(source) != fixture.frames {
                problems.append("\(CGImageSourceGetCount(source)) frames, expected \(fixture.frames)")
            }
        case let tool as FitImageConverter:
            let size = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
            if size > tool.limit { problems.append("\(size) bytes, over the \(tool.limit) limit") }
        case is RemoveBackgroundConverter:
            if !ImageCodec.hasAlpha(image) { problems.append("no transparency") }
        default:
            break
        }
        return problems
    }

    /// Pairs a macOS version can't write, which the converter refuses
    /// rather than leaving a broken file: before macOS 26, ImageIO writes an
    /// unreadable PSD for a 1×1 image.
    static func mayDecline(_ fixture: Fixture, _ converter: any Converter) -> Bool {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26,
              let converter = converter as? ImageFormatConverter else { return false }
        return converter.format == .psd && fixture.width == 1 && fixture.height == 1
    }

    /// Everything that's wrong with `output`, or an empty list.
    func check(_ output: URL, of fixture: Fixture, made converter: any Converter) async throws -> [String] {
        switch converter {
        case let converter as ImageFormatConverter:
            return checkImage(output, of: fixture, format: converter.format)
        case is AnimatedImageToVideoConverter:
            return try await checkVideo(output, of: fixture)
        default:
            return ["no check for \(converter.id)"]
        }
    }

    func checkImage(_ output: URL, of fixture: Fixture, format: ImageFormat) -> [String] {
        if format.writer == .pdf {
            guard let pdf = CGPDFDocument(output as CFURL) else { return ["not a readable PDF"] }
            var problems: [String] = []
            let expectedPages = fixture.name.hasSuffix(".tiff") ? fixture.frames : 1
            if pdf.numberOfPages != expectedPages { problems.append("\(pdf.numberOfPages) pages, expected \(expectedPages)") }
            if let box = pdf.page(at: 1)?.getBoxRect(.mediaBox) {
                let w = Double(fixture.width) * 72 / fixture.dpi, h = Double(fixture.height) * 72 / fixture.dpi
                if abs(box.width - w) > 0.5 || abs(box.height - h) > 0.5 {
                    problems.append("page \(box.width)×\(box.height) pt, expected \(w)×\(h)")
                }
            }
            return problems
        }

        guard let source = CGImageSourceCreateWithURL(output as CFURL, nil),
              let type = CGImageSourceGetType(source) as String? else { return ["not a readable image"] }
        var problems: [String] = []
        if type != format.typeIdentifier { problems.append("type \(type), expected \(format.typeIdentifier)") }

        let count = CGImageSourceGetCount(source)
        let sizes = (0..<count).map { index -> (Int, Int) in
            let p = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            if let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 {
                return (w, h)
            }
            // macOS 15 leaves the size out of a 1×1 PSD's properties; measure the decoded image.
            let image = CGImageSourceCreateImageAtIndex(source, index, nil)
            return (image?.width ?? 0, image?.height ?? 0)
        }

        if case .icon(let standardSizes) = format.writer {
            let expected = ImageCodec.iconSizes(standardSizes, forLongestSide: max(fixture.width, fixture.height))
            let largest = sizes.map(\.0).max() ?? 0
            if largest != expected.max() { problems.append("largest icon \(largest) px, expected \(expected.max()!)") }
            if sizes.contains(where: { $0.0 != $0.1 }) { problems.append("icon images aren't square: \(sizes)") }
            return problems
        }

        let expectedFrames = fixture.animated && format.supportsAnimation ? fixture.frames
            : (fixture.name.hasSuffix(".tiff") && format.supportsMultiplePages ? fixture.frames : 1)
        if count != expectedFrames { problems.append("\(count) frames, expected \(expectedFrames)") }
        let primary = sizes[CGImageSourceGetPrimaryImageIndex(source)]
        if primary.0 != fixture.width || primary.1 != fixture.height {
            problems.append("\(primary.0)×\(primary.1), expected \(fixture.width)×\(fixture.height)")
        }
        return problems
    }

    func checkVideo(_ output: URL, of fixture: Fixture) async throws -> [String] {
        let asset = AVURLAsset(url: output)
        var problems: [String] = []
        let duration = try await asset.load(.duration).seconds
        if abs(duration - fixture.duration) > 0.05 { problems.append("duration \(duration) s, expected \(fixture.duration) s") }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return problems + ["no video track"] }
        let size = try await track.load(.naturalSize)
        if Int(size.width) != fixture.width & ~1 || Int(size.height) != fixture.height & ~1 {
            problems.append("\(Int(size.width))×\(Int(size.height)), expected \(fixture.width & ~1)×\(fixture.height & ~1)")
        }
        return problems
    }
}
