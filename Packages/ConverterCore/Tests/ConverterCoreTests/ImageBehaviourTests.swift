import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ConverterCore

/// Image details beyond "the output opens": orientation, transparency,
/// metadata, and the resize / compress / strip-metadata tools.
final class ImageBehaviourTests: XCTestCase {
    var root: URL!
    var fixtures: [String: Fixture] = [:]

    override func setUpWithError() throws {
        root = try makeTemporaryFolder("ImageBehaviour")
        let samples = root.appendingPathComponent("samples", isDirectory: true)
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        for fixture in try Samples.makeAll(in: samples) { fixtures[fixture.name] = fixture }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func input(_ name: String) throws -> InputFile {
        try isolatedCopy(of: XCTUnwrap(fixtures[name], "missing fixture \(name)"), in: root)
    }

    func converter(_ id: String) throws -> any Converter {
        try XCTUnwrap(ConverterRegistry.standard.converter(id: id), "missing converter \(id)")
    }

    func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try ImageCodec.openSource(url)
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    // MARK: Format conversions

    func testOrientationIsAppliedToPixels() async throws {
        // Stored image: red top-left quadrant. Orientation 6 rotates it 90°
        // clockwise for display, so red ends up top-right.
        let output = try await JobRunner.run(converter("image.png"), on: input("rotated.jpg"))
        let pixels = try Pixels(url: output)
        XCTAssertEqual(pixels.width, 200)
        XCTAssertEqual(pixels.height, 320)
        XCTAssertTrue(pixels.isRed(150, 80), "top-right should be red")
        XCTAssertTrue(pixels.isBlue(50, 80), "top-left should be blue")
        XCTAssertEqual((try properties(output)[kCGImagePropertyOrientation] as? Int) ?? 1, 1)
    }

    func testTransparencyBecomesWhiteInJPEG() async throws {
        let output = try await JobRunner.run(converter("image.jpeg"), on: input("alpha.png"))
        let pixels = try Pixels(url: output)
        XCTAssertTrue(pixels.isWhite(300, 190), "transparent corner should be white, got \(pixels.rgba(300, 190))")
        XCTAssertTrue(pixels.isRed(10, 10))
    }

    func testTransparencyIsKeptInHEIC() async throws {
        let output = try await JobRunner.run(converter("image.heic"), on: input("alpha.png"))
        let pixels = try Pixels(url: output)
        XCTAssertLessThan(pixels.rgba(300, 190).a, 10, "transparent corner should stay transparent")
    }

    func testMetadataIsKeptByDefault() async throws {
        let output = try await JobRunner.run(converter("image.heic"), on: input("photo.jpg"))
        let props = try properties(output)
        XCTAssertNotNil(props[kCGImagePropertyGPSDictionary], "GPS should be kept")
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "TestCam")
    }

    func testMetadataCanBeDropped() async throws {
        let options = ConversionOptions(keepMetadata: false)
        let output = try await JobRunner.run(converter("image.heic"), on: input("photo.jpg"), options: options)
        let props = try properties(output)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary])
        XCTAssertNil((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake])
    }

    func testAnimatedGIFStaysAnimatedWhenResized() async throws {
        let output = try await JobRunner.run(converter("image.resize.50pct"), on: input("anim.gif"))
        XCTAssertEqual(output.lastPathComponent, "anim (50%).gif")
        let source = try ImageCodec.openSource(output)
        XCTAssertEqual(CGImageSourceGetCount(source), 4)
        let info = try XCTUnwrap(InputFile(url: output).image)
        XCTAssertEqual(info.width, 60)
        XCTAssertEqual(info.height, 40)
        XCTAssertEqual(ImageCodec.frameDelay(ImageCodec.properties(source, 1)), 0.1, accuracy: 0.001)
    }

    func testFormatsAreNotOfferedForTheSameFormat() throws {
        let ids = ConverterRegistry.standard.converters(for: [try input("photo.jpg")]).map(\.id)
        XCTAssertFalse(ids.contains("image.jpeg"))
        XCTAssertTrue(ids.contains("image.png"))
        let heicIDs = ConverterRegistry.standard.converters(for: [try input("photo.heic")]).map(\.id)
        XCTAssertFalse(heicIDs.contains("image.heic"))
    }

    func testMixedSelectionOffersOnlySharedConversions() throws {
        let both = [try input("photo.jpg"), try input("alpha.png")]
        let ids = ConverterRegistry.standard.converters(for: both).map(\.id)
        XCTAssertFalse(ids.contains("image.jpeg"))
        XCTAssertFalse(ids.contains("image.png"))
        XCTAssertTrue(ids.contains("image.heic"))
        XCTAssertFalse(ids.contains("image.compress"), "PNG can't be compressed lossily")
    }

    func testAVIFIsOfferedOnlyWhenTheSystemCanEncodeIt() throws {
        let converter = ImageFormatConverter(format: .avif)
        XCTAssertEqual(converter.isAvailable, ImageCodec.writableTypes.contains("public.avif"))
        XCTAssertEqual(ConverterRegistry.standard.converter(id: "image.avif") != nil, converter.isAvailable)
    }

    func testRegisteredRasterizerMakesUnreadableTypesConvertible() async throws {
        struct FakeRasterizer: ImageRasterizer {
            var supportedTypes: [UTType] { [UTType(filenameExtension: "fakevector")!] }
            func rasterize(_ url: URL) throws -> Data {
                let data = NSMutableData()
                let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, Samples.testCard(alpha: true), nil)
                CGImageDestinationFinalize(destination)
                return data as Data
            }
        }
        let folder = try makeTemporaryFolder("Rasterizer")
        defer { try? FileManager.default.removeItem(at: folder) }
        let vector = folder.appendingPathComponent("logo.fakevector")
        try Data("<vector/>".utf8).write(to: vector)
        XCTAssertNil(try InputFile(url: vector).image, "ImageIO shouldn't read this on its own")

        ImageRasterizers.register(FakeRasterizer())
        defer { ImageRasterizers.removeAll() }
        let input = try InputFile(url: vector)
        let info = try XCTUnwrap(input.image)
        XCTAssertEqual(info.typeIdentifier, input.contentType.identifier, "keeps its own type, not PNG")
        let ids = ConverterRegistry.standard.converters(for: [input]).map(\.id)
        XCTAssertTrue(ids.contains("image.png"))
        XCTAssertFalse(ids.contains("image.stripMetadata"), "can't write the source format back")

        let output = try await JobRunner.run(converter("image.png"), on: input)
        XCTAssertEqual(output.lastPathComponent, "logo.png")
        let pixels = try Pixels(url: output)
        XCTAssertEqual(pixels.width, 320)
        XCTAssertTrue(pixels.isRed(10, 10))
    }

    // MARK: Resize

    func testResizeByPercent() async throws {
        let output = try await JobRunner.run(converter("image.resize.25pct"), on: input("photo.jpg"))
        XCTAssertEqual(output.lastPathComponent, "photo (25%).jpg")
        let info = try XCTUnwrap(InputFile(url: output).image)
        XCTAssertEqual(info.width, 80)
        XCTAssertEqual(info.height, 50)
    }

    func testResizeToLongestSideAndNeverEnlarge() async throws {
        let folder = try makeTemporaryFolder("Resize")
        defer { try? FileManager.default.removeItem(at: folder) }
        let big = folder.appendingPathComponent("big.png")
        try Samples.write([Samples.testCard(width: 2000, height: 1000)], type: "public.png", to: big)
        let input = try InputFile(url: big)

        let output = try await JobRunner.run(converter("image.resize.1920"), on: input)
        XCTAssertEqual(output.lastPathComponent, "big (1920px).png")
        let info = try XCTUnwrap(InputFile(url: output).image)
        XCTAssertEqual(info.width, 1920)
        XCTAssertEqual(info.height, 960)

        XCTAssertFalse(try converter("image.resize.3840").accepts(input), "must not enlarge")
        XCTAssertFalse(try converter("image.resize.640").accepts(try self.input("photo.jpg")))
    }

    func testResizeKeepsOrientationUpright() async throws {
        let output = try await JobRunner.run(converter("image.resize.50pct"), on: input("rotated.jpg"))
        let pixels = try Pixels(url: output)
        XCTAssertEqual(pixels.width, 100)
        XCTAssertEqual(pixels.height, 160)
        XCTAssertTrue(pixels.isRed(75, 40))
    }

    func testResizeOfUnwritableFormatFallsBack() async throws {
        let webp = try input("alpha.webp")
        // 1×1 can't shrink; use a format we can't write but can resize: none
        // here is larger than 1 px, so check the naming rule directly.
        let spec = ResizeImageConverter(.percent(50)).output(for: webp)
        XCTAssertEqual(spec.fileExtension, "png", "transparent WebP should resize to PNG")
        let opaque = ResizeImageConverter(.percent(50)).output(for: try input("tiny.webp"))
        XCTAssertEqual(opaque.fileExtension, "jpg", "opaque WebP should resize to JPEG")
    }

    // MARK: Compress

    func testCompressMakesASmallerFileInTheSameFormat() async throws {
        let original = try input("photo.jpg")
        let output = try await JobRunner.run(converter("image.compress"), on: original,
                                             options: ConversionOptions(compressionQuality: 0.2))
        XCTAssertEqual(output.lastPathComponent, "photo (compressed).jpg")
        let before = try XCTUnwrap(original.url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let after = try XCTUnwrap(output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(after, before)
        XCTAssertEqual(CGImageSourceGetType(try ImageCodec.openSource(output)) as String?, "public.jpeg")
    }

    // MARK: Strip metadata

    func testStripMetadataRemovesCameraAndGPSWithoutReencoding() async throws {
        let original = try input("photo.jpg")
        let output = try await JobRunner.run(converter("image.stripMetadata"), on: original)
        XCTAssertEqual(output.lastPathComponent, "photo (no metadata).jpg")
        let props = try properties(output)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "GPS should be gone")
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(exif[kCGImagePropertyExifLensModel])
        XCTAssertNil((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake])
        XCTAssertTrue(try Pixels(url: output) == Pixels(url: original.url), "JPEG pixels should be untouched")
    }

    func testStripMetadataKeepsOrientation() async throws {
        let output = try await JobRunner.run(converter("image.stripMetadata"), on: input("rotated.jpg"))
        XCTAssertEqual(try properties(output)[kCGImagePropertyOrientation] as? Int, 6)
    }

    func testStripMetadataReencodesHEIC() async throws {
        let folder = try makeTemporaryFolder("StripHEIC")
        defer { try? FileManager.default.removeItem(at: folder) }
        let heic = folder.appendingPathComponent("gps.heic")
        try Samples.write([Samples.testCard()], type: "public.heic", to: heic, frameProperties: Samples.cameraMetadata)
        XCTAssertNotNil(try properties(heic)[kCGImagePropertyGPSDictionary], "fixture should have GPS")

        let output = try await JobRunner.run(converter("image.stripMetadata"), on: InputFile(url: heic))
        XCTAssertEqual(output.pathExtension, "heic")
        XCTAssertNil(try properties(output)[kCGImagePropertyGPSDictionary])
    }
}
