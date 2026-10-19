import CoreGraphics
import ImageIO
import XCTest
@testable import ConverterCore

/// Crop presets (centred aspect ratios) and editor crops (a region, maybe
/// scaled to exact dimensions).
final class CropTests: XCTestCase {
    var root: URL!
    var fixtures: [String: Fixture] = [:]

    override func setUpWithError() throws {
        root = try makeTemporaryFolder("Crop")
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

    func properties(_ url: URL) throws -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(try ImageCodec.openSource(url), 0, nil) as? [CFString: Any] ?? [:]
    }

    func testCentredRegions() {
        XCTAssertEqual(CropRegion.centred(ratioWidth: 16, ratioHeight: 9, in: PixelSize(width: 4000, height: 3000)),
                       CropRegion(x: 0, y: 375, width: 4000, height: 2250))
        XCTAssertEqual(CropRegion.centred(ratioWidth: 1, ratioHeight: 1, in: PixelSize(width: 320, height: 200)),
                       CropRegion(x: 60, y: 0, width: 200, height: 200))
        XCTAssertEqual(CropRegion.centred(ratioWidth: 9, ratioHeight: 16, in: PixelSize(width: 1920, height: 1080)),
                       CropRegion(x: 656, y: 0, width: 608, height: 1080))
    }

    func testRegionsAreKeptInsideTheImage() {
        let size = PixelSize(width: 320, height: 200)
        XCTAssertEqual(CropRegion(x: 300, y: -5, width: 100, height: 500).clamped(to: size),
                       CropRegion(x: 220, y: 0, width: 100, height: 200))
        XCTAssertEqual(CropRegion(x: 10, y: 10, width: 0, height: 0).clamped(to: size),
                       CropRegion(x: 10, y: 10, width: 1, height: 1))
    }

    func testSquarePresetCropsTheMiddle() async throws {
        let output = try await JobRunner.run(CropImageConverter(.aspect(width: 1, height: 1)), on: input("photo.jpg"))
        XCTAssertEqual(output.lastPathComponent, "photo (square).jpg")
        let pixels = try Pixels(url: output)
        XCTAssertEqual(pixels.width, 200)
        XCTAssertEqual(pixels.height, 200)
        // The card's red quadrant is x < 160, y < 100; the crop starts at x = 60.
        XCTAssertTrue(pixels.isRed(10, 10))
        XCTAssertTrue(pixels.isRed(90, 90))
        XCTAssertTrue(pixels.isBlue(110, 50))
        XCTAssertTrue(pixels.isBlue(50, 150))
    }

    func testPresetsAreOfferedOnlyWhenTheyChangeTheShape() throws {
        let folder = try makeTemporaryFolder("CropShape")
        defer { try? FileManager.default.removeItem(at: folder) }
        let wide = folder.appendingPathComponent("wide.png")
        try Samples.write([Samples.testCard(width: 320, height: 180)], type: "public.png", to: wide)
        let input = try InputFile(url: wide)
        XCTAssertFalse(CropImageConverter(.aspect(width: 16, height: 9)).accepts(input), "already 16:9")
        XCTAssertTrue(CropImageConverter(.aspect(width: 1, height: 1)).accepts(input))

        let ids = ConverterRegistry.standard.converters(for: [input]).map(\.id)
        XCTAssertTrue(ids.contains("image.crop.1x1"))
        XCTAssertFalse(ids.contains("image.crop.16x9"))
        XCTAssertFalse(ids.contains("image.crop.region"), "editor crops aren't in the menus")
    }

    func testPresetTitlesAndNames() throws {
        let photo = try input("photo.jpg")
        XCTAssertEqual(CropImageConverter.presets.map(\.title), ["Square", "4:3", "3:2", "16:9", "3:4", "2:3", "9:16"])
        XCTAssertEqual(CropImageConverter(.aspect(width: 16, height: 9)).output(for: photo).nameSuffix, " (16x9)")
        XCTAssertTrue(CropImageConverter.presets.allSatisfy { $0.menuGroup == "Crop" && $0.role == .tool })
    }

    func testRegionUsesUprightPixels() async throws {
        // rotated.jpg displays as 200×320 with its red quadrant top-right.
        let crop = CropImageConverter(.region(CropRegion(x: 100, y: 0, width: 100, height: 160), size: nil))
        let output = try await JobRunner.run(crop, on: input("rotated.jpg"))
        XCTAssertEqual(output.lastPathComponent, "rotated (cropped).jpg")
        let pixels = try Pixels(url: output)
        XCTAssertEqual(pixels.width, 100)
        XCTAssertEqual(pixels.height, 160)
        XCTAssertTrue(pixels.isRed(5, 5))
        XCTAssertTrue(pixels.isRed(95, 155))
        XCTAssertEqual((try properties(output)[kCGImagePropertyOrientation] as? Int) ?? 1, 1)
    }

    func testRegionScaledToExactSizeKeepsMetadata() async throws {
        let crop = CropImageConverter(.region(CropRegion(x: 0, y: 0, width: 160, height: 100),
                                              size: PixelSize(width: 64, height: 40)))
        let output = try await JobRunner.run(crop, on: input("photo.jpg"))
        XCTAssertEqual(output.lastPathComponent, "photo (64x40).jpg")
        let pixels = try Pixels(url: output)
        XCTAssertEqual(pixels.width, 64)
        XCTAssertEqual(pixels.height, 40)
        XCTAssertTrue(pixels.isRed(2, 2))
        XCTAssertTrue(pixels.isRed(61, 37))
        let props = try properties(output)
        XCTAssertNotNil(props[kCGImagePropertyGPSDictionary], "metadata is kept by default")
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNotEqual(exif[kCGImagePropertyExifPixelXDimension] as? Int, 160, "no stale size from the original")
    }

    func testTransparencyIsKept() async throws {
        let crop = CropImageConverter(.region(CropRegion(x: 160, y: 100, width: 160, height: 100), size: nil))
        let output = try await JobRunner.run(crop, on: input("alpha.png"))
        XCTAssertEqual(output.pathExtension, "png")
        XCTAssertEqual(try Pixels(url: output).rgba(80, 50).a, 0, "the clear quadrant stays clear")
    }

    func testAnimationsAreCroppedFrameByFrame() async throws {
        let original = try input("anim.gif")
        let output = try await JobRunner.run(CropImageConverter(.aspect(width: 1, height: 1)), on: original)
        let source = try ImageCodec.openSource(output)
        XCTAssertEqual(CGImageSourceGetCount(source), original.image?.frameCount)
        let info = try XCTUnwrap(InputFile(url: output).image)
        XCTAssertEqual(info.width, info.height)
    }
}
