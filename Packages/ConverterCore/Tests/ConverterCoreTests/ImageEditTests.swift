import CoreGraphics
import ImageIO
import XCTest
@testable import ConverterCore

/// Rotate and flip, Remove Background and Fit to Size.
final class ImageEditTests: XCTestCase {
    var root: URL!
    var fixtures: [String: Fixture] = [:]

    override func setUpWithError() throws {
        root = try makeTemporaryFolder("ImageEdit")
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

    /// A new file in its own folder, made by `write`.
    func make(_ name: String, _ write: (URL) throws -> Void) throws -> InputFile {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try write(url)
        return try InputFile(url: url)
    }

    func turn(_ turn: RotateImageConverter.Turn, _ name: String) async throws -> URL {
        try await JobRunner.run(RotateImageConverter(turn), on: input(name))
    }

    func fileSize(_ url: URL) throws -> Int {
        try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    // MARK: Rotate and flip

    // The test card is 320×200, blue with a red top-left quadrant.

    func testRotateRightTurnsThePixelsClockwise() async throws {
        let output = try await turn(.right, "photo.jpg")
        XCTAssertEqual(output.lastPathComponent, "photo (rotated right).jpg")
        let pixels = try Pixels(url: output)
        XCTAssertEqual(pixels.width, 200)
        XCTAssertEqual(pixels.height, 320)
        XCTAssertTrue(pixels.isRed(150, 80), "red should now be top-right")
        XCTAssertTrue(pixels.isBlue(50, 80))
        XCTAssertTrue(pixels.isBlue(150, 240))
    }

    func testRotateLeftTurnsThePixelsAnticlockwise() async throws {
        let output = try await turn(.left, "photo.jpg")
        XCTAssertEqual(output.lastPathComponent, "photo (rotated left).jpg")
        let pixels = try Pixels(url: output)
        XCTAssertEqual(pixels.width, 200)
        XCTAssertEqual(pixels.height, 320)
        XCTAssertTrue(pixels.isRed(50, 240), "red should now be bottom-left")
        XCTAssertTrue(pixels.isBlue(50, 80))
    }

    func testHalfTurnAndFlips() async throws {
        let half = try Pixels(url: try await turn(.halfTurn, "photo.jpg"))
        XCTAssertEqual(half.width, 320)
        XCTAssertTrue(half.isRed(240, 150), "red should now be bottom-right")
        XCTAssertTrue(half.isBlue(80, 50))

        let mirrored = try Pixels(url: try await turn(.flipHorizontal, "photo.jpg"))
        XCTAssertTrue(mirrored.isRed(240, 50), "red should now be top-right")
        XCTAssertTrue(mirrored.isBlue(80, 50))

        let upsideDown = try Pixels(url: try await turn(.flipVertical, "photo.jpg"))
        XCTAssertTrue(upsideDown.isRed(80, 150), "red should now be bottom-left")
        XCTAssertTrue(upsideDown.isBlue(80, 50))
    }

    func testRotationStartsFromHowThePhotoIsShown() async throws {
        // Displayed 200×320 with red top-right; a left turn takes red to the top-left.
        let output = try await turn(.left, "rotated.jpg")
        let pixels = try Pixels(url: output)
        XCTAssertEqual(pixels.width, 320)
        XCTAssertEqual(pixels.height, 200)
        XCTAssertTrue(pixels.isRed(80, 50))
        XCTAssertTrue(pixels.isBlue(240, 50))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try ImageCodec.openSource(output), 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1, "saved upright")
    }

    func testRotationKeepsMetadata() async throws {
        let output = try await turn(.right, "photo.jpg")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try ImageCodec.openSource(output), 0, nil) as? [CFString: Any])
        XCTAssertNotNil(props[kCGImagePropertyGPSDictionary], "GPS should be kept")
        XCTAssertEqual((props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String, "TestCam")
    }

    func testFlippingTwiceGivesTheSamePixels() async throws {
        let once = try await JobRunner.run(RotateImageConverter(.flipHorizontal), on: input("alpha.png"))
        let twice = try await JobRunner.run(RotateImageConverter(.flipHorizontal), on: InputFile(url: once))
        XCTAssertTrue(try Pixels(url: twice) == Pixels(url: fixtures["alpha.png"]!.url), "nothing should be resampled")
        // The transparent bottom-right quadrant is now bottom-left.
        let flipped = try Pixels(url: once)
        XCTAssertLessThan(flipped.rgba(10, 190).a, 10)
        XCTAssertEqual(flipped.rgba(300, 190).a, 255)
    }

    func testAnimationsStayAnimated() async throws {
        let output = try await turn(.right, "anim.gif")
        XCTAssertEqual(output.lastPathComponent, "anim (rotated right).gif")
        let source = try ImageCodec.openSource(output)
        XCTAssertEqual(CGImageSourceGetCount(source), 4)
        let info = try XCTUnwrap(InputFile(url: output).image)
        XCTAssertEqual(info.width, 80)
        XCTAssertEqual(info.height, 120)
    }

    func testRotatePresets() throws {
        XCTAssertEqual(RotateImageConverter.presets.map(\.title), ["Left", "Right", "180°", "Flip Horizontal", "Flip Vertical"])
        XCTAssertEqual(RotateImageConverter.presets.map(\.id), [
            "image.rotate.left", "image.rotate.right", "image.rotate.180", "image.flip.horizontal", "image.flip.vertical",
        ])
        XCTAssertTrue(RotateImageConverter.presets.allSatisfy { $0.menuGroup == "Rotate" && $0.role == .tool })
    }

    // MARK: Remove Background

    /// A red disc on a light grey background.
    static func subject(width: Int = 640, height: Int = 480) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: Samples.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(Samples.red)
        context.fillEllipse(in: CGRect(x: width / 2 - 120, y: height / 2 - 120, width: 240, height: 240))
        return context.makeImage()!
    }

    func testRemoveBackgroundIsOfferedFromMacOS14() {
        let available = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0))
        XCTAssertEqual(RemoveBackgroundConverter().isAvailable, available)
        XCTAssertEqual(ConverterRegistry.standard.converter(id: "image.removeBackground") != nil, available)
    }

    func testRemoveBackgroundKeepsTheSubject() async throws {
        let converter = RemoveBackgroundConverter()
        try XCTSkipUnless(converter.isAvailable, "needs macOS 14")
        let input = try make("disc.jpg") { try Samples.write([Self.subject()], type: "public.jpeg", to: $0) }
        let output = try await JobRunner.run(converter, on: input)
        XCTAssertEqual(output.lastPathComponent, "disc (no background).png")
        XCTAssertEqual(CGImageSourceGetType(try ImageCodec.openSource(output)) as String?, "public.png")
        let pixels = try Pixels(url: output)
        XCTAssertEqual(pixels.width, 640)
        XCTAssertEqual(pixels.height, 480)
        XCTAssertTrue(pixels.isRed(320, 240), "the disc should stay, got \(pixels.rgba(320, 240))")
        XCTAssertEqual(pixels.rgba(320, 240).a, 255)
        for (x, y) in [(5, 5), (634, 5), (5, 474), (634, 474), (100, 240)] {
            XCTAssertLessThan(pixels.rgba(x, y).a, 10, "background at \(x), \(y) should be transparent")
        }
    }

    func testRemoveBackgroundWorksOnTheUprightPhoto() async throws {
        let converter = RemoveBackgroundConverter()
        try XCTSkipUnless(converter.isAvailable, "needs macOS 14")
        // Stored sideways and tagged "rotate 90° clockwise".
        let input = try make("sideways.jpg") {
            try Samples.write([Self.subject(width: 480, height: 640)], type: "public.jpeg", to: $0,
                              frameProperties: [kCGImagePropertyOrientation: 6])
        }
        let output = try await JobRunner.run(converter, on: input)
        let pixels = try Pixels(url: output)
        XCTAssertEqual(pixels.width, 640)
        XCTAssertEqual(pixels.height, 480)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try ImageCodec.openSource(output), 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyOrientation] as? Int ?? 1, 1)
    }

    func testRemoveBackgroundIsNotOfferedForTinyOrAnimatedImages() throws {
        let converter = RemoveBackgroundConverter()
        XCTAssertFalse(converter.accepts(try input("tiny.webp")))
        XCTAssertFalse(converter.accepts(try input("anim.gif")))
        XCTAssertTrue(converter.accepts(try input("photo.heic")))
        XCTAssertEqual(converter.output(for: try input("photo.heic")).fileExtension, "png")
    }

    // MARK: Fit to Size

    /// Coloured noise, which compresses badly, so its file is large.
    static func noise(width: Int, height: Int, alpha: Bool = false) -> CGImage {
        var state: UInt64 = 0x5EED
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let r = UInt8(truncatingIfNeeded: state >> 56), g = UInt8(truncatingIfNeeded: state >> 48)
            let b = UInt8(truncatingIfNeeded: state >> 40)
            // Opaque, or (with alpha) a left half that's half transparent.
            let a: UInt8 = alpha && (i / 4) % width < width / 2 ? 128 : 255
            bytes[i] = UInt8(Int(r) * Int(a) / 255)
            bytes[i + 1] = UInt8(Int(g) * Int(a) / 255)
            bytes[i + 2] = UInt8(Int(b) * Int(a) / 255)
            bytes[i + 3] = a
        }
        let info = (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Samples.sRGB, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }

    func noisyJPEG(_ name: String = "noise.jpg", width: Int = 1600, height: Int = 1200) throws -> InputFile {
        try make(name) {
            var props = Samples.cameraMetadata
            props[kCGImageDestinationLossyCompressionQuality] = 0.95
            try Samples.write([Self.noise(width: width, height: height)], type: "public.jpeg", to: $0, frameProperties: props)
        }
    }

    /// `fraction` of the file's size, rounded down to whole kilobytes.
    func limit(_ input: InputFile, _ fraction: Double) throws -> Int {
        Int(Double(try fileSize(input.url)) * fraction) / 1000 * 1000
    }

    func testFitLowersTheQualityFirst() async throws {
        let input = try noisyJPEG()
        let fit = FitImageConverter(bytes: try limit(input, 0.6))
        XCTAssertTrue(fit.accepts(input))
        let output = try await JobRunner.run(fit, on: input)
        XCTAssertEqual(output.lastPathComponent, "noise (under \(fit.title)).jpg")
        XCTAssertLessThanOrEqual(try fileSize(output), fit.limit)
        let info = try XCTUnwrap(InputFile(url: output).image)
        XCTAssertEqual(info.width, 1600, "quality alone should be enough")
        XCTAssertEqual(info.height, 1200)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(try ImageCodec.openSource(output), 0, nil) as? [CFString: Any])
        XCTAssertNotNil(props[kCGImagePropertyGPSDictionary], "metadata should be kept")
    }

    func testFitMakesThePictureSmallerWhenQualityIsNotEnough() async throws {
        let input = try noisyJPEG()
        let fit = FitImageConverter(bytes: try limit(input, 0.2))
        let output = try await JobRunner.run(fit, on: input)
        XCTAssertLessThanOrEqual(try fileSize(output), fit.limit)
        let info = try XCTUnwrap(InputFile(url: output).image)
        XCTAssertLessThan(info.width, 1600)
        XCTAssertGreaterThanOrEqual(info.width, FitImageConverter.smallestSide)
        XCTAssertEqual(Double(info.width) / Double(info.height), 4.0 / 3.0, accuracy: 0.01, "shape kept")
    }

    func testFitRefusesRatherThanRuinThePicture() async throws {
        let input = try noisyJPEG()
        let fit = FitImageConverter(bytes: 20_000)
        do {
            _ = try await JobRunner.run(fit, on: input)
            XCTFail("a 20 KB noise picture isn't worth saving")
        } catch let error as ConversionError {
            guard case .nothingToDo(let message) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(message.contains("under 20 KB"), message)
        }
        XCTAssertEqual(try folderContents(input.url.deletingLastPathComponent()), ["noise.jpg"], "nothing left behind")
    }

    func testFitIsOnlyOfferedForFilesOverTheLimit() async throws {
        let small = try input("photo.jpg")
        let fit = FitImageConverter(megabytes: 1)
        XCTAssertFalse(fit.accepts(small))
        XCTAssertFalse(fit.accepts(try input("anim.gif")), "animations aren't offered")
        do {
            // JobRunner wouldn't run it at all; the converter checks too.
            let destination = root.appendingPathComponent("never.jpg")
            try await fit.convert(small, to: destination, options: .default) { _ in }
            XCTFail("photo.jpg is already under 1 MB")
        } catch let error as ConversionError {
            XCTAssertEqual(error, .nothingToDo("photo.jpg is already under 1 MB."))
        }
    }

    func testFitTurnsOpaqueLosslessImagesIntoJPEG() async throws {
        let input = try make("noise.png") { try Samples.write([Self.noise(width: 1200, height: 900)], type: "public.png", to: $0) }
        let fit = FitImageConverter(bytes: try limit(input, 0.5))
        XCTAssertEqual(fit.output(for: input).fileExtension, "jpg")
        let output = try await JobRunner.run(fit, on: input)
        XCTAssertEqual(output.pathExtension, "jpg")
        XCTAssertLessThanOrEqual(try fileSize(output), fit.limit)
    }

    func testFitKeepsTransparencyByMakingPNGsSmaller() async throws {
        let input = try make("noise.png") {
            try Samples.write([Self.noise(width: 1600, height: 1200, alpha: true)], type: "public.png", to: $0)
        }
        let fit = FitImageConverter(bytes: try limit(input, 0.5))
        let output = try await JobRunner.run(fit, on: input)
        XCTAssertEqual(output.pathExtension, "png")
        XCTAssertLessThanOrEqual(try fileSize(output), fit.limit)
        let pixels = try Pixels(url: output)
        XCTAssertLessThan(pixels.width, 1600)
        XCTAssertEqual(Double(pixels.rgba(5, 5).a), 128, accuracy: 3, "half-transparent half kept")
    }

    func testFitPresets() {
        XCTAssertEqual(FitImageConverter.presets.map(\.title), ["1 MB", "5 MB", "8 MB", "25 MB"])
        XCTAssertEqual(FitImageConverter.presets.map(\.id), ["image.fit.1mb", "image.fit.5mb", "image.fit.8mb", "image.fit.25mb"])
        XCTAssertEqual(FitImageConverter.presets[0].limit, 1_000_000)
        XCTAssertTrue(FitImageConverter.presets.allSatisfy { $0.menuGroup == "Fit to Size" && $0.role == .tool })
        XCTAssertEqual(FitImageConverter(bytes: 250_000).title, "250 KB")
    }
}
