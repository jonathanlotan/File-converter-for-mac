import AVFoundation
import CoreGraphics
import XCTest
@testable import ConverterCore

/// What the metadata window shows for images, media, PDFs and folders.
final class MetadataTests: XCTestCase {
    var root: URL!
    var fixtures: [String: Fixture] = [:]

    override func setUpWithError() throws {
        root = try makeTemporaryFolder("Metadata")
        let samples = root.appendingPathComponent("samples", isDirectory: true)
        try FileManager.default.createDirectory(at: samples, withIntermediateDirectories: true)
        for fixture in try Samples.makeAll(in: samples) { fixtures[fixture.name] = fixture }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func sections(_ url: URL) async -> [String: MetadataSection] {
        Dictionary(uniqueKeysWithValues: await FileMetadata.sections(for: url).map { ($0.title, $0) })
    }

    func testPhotoShowsCameraAndLocation() async throws {
        let url = try XCTUnwrap(fixtures["photo.jpg"]).url
        let ordered = await FileMetadata.sections(for: url).map(\.title)
        XCTAssertEqual(ordered, ["File", "Image", "Camera", "Location"], "empty sections are left out")

        let info = await sections(url)
        XCTAssertEqual(info["Image"]?["Dimensions"], "320 × 200 pixels")
        XCTAssertEqual(info["Image"]?["Transparency"], "No")
        XCTAssertEqual(info["Camera"]?["Make"], "TestCam")
        XCTAssertEqual(info["Camera"]?["Model"], "One")
        XCTAssertEqual(info["Camera"]?["Lens"], "Test Lens 50mm")
        let taken = try XCTUnwrap(info["Camera"]?["Taken"])
        XCTAssertFalse(taken.contains("2024:05"), "the EXIF date is shown as a date, not raw")
        XCTAssertEqual(info["Location"]?["Latitude"], "32.080000° N")
        XCTAssertEqual(info["Location"]?["Longitude"], "34.780000° E")
        XCTAssertEqual(info["Location"]?["Coordinates"], "32.080000, 34.780000")
        XCTAssertTrue(info["File"]?["Size"]?.hasSuffix("bytes)") ?? false)
        XCTAssertNotNil(info["File"]?["Kind"])
    }

    func testCameraSettingsAreReadable() async throws {
        let url = root.appendingPathComponent("settings.jpg")
        let exif: [CFString: Any] = [kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifExposureTime: 0.004,
                                     kCGImagePropertyExifISOSpeedRatings: [200], kCGImagePropertyExifFocalLength: 50,
                                     kCGImagePropertyExifFocalLenIn35mmFilm: 75, kCGImagePropertyExifFlash: 16,
                                     kCGImagePropertyExifExposureBiasValue: -0.7]
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 33.9, kCGImagePropertyGPSLatitudeRef: "S",
                                    kCGImagePropertyGPSLongitude: 18.4, kCGImagePropertyGPSLongitudeRef: "E",
                                    kCGImagePropertyGPSAltitude: 25, kCGImagePropertyGPSAltitudeRef: 0]
        try Samples.write([Samples.testCard()], type: "public.jpeg", to: url,
                          frameProperties: [kCGImagePropertyExifDictionary: exif, kCGImagePropertyGPSDictionary: gps])
        let camera = await sections(url)["Camera"]
        XCTAssertEqual(camera?["Aperture"], "f/2.8")
        XCTAssertEqual(camera?["Exposure"], "1/250 s")
        XCTAssertEqual(camera?["ISO"], "ISO 200")
        XCTAssertEqual(camera?["Focal Length"], "50 mm (75 mm in 35 mm terms)")
        XCTAssertEqual(camera?["Flash"], "Did not fire")
        XCTAssertEqual(camera?["Exposure Bias"], "-0.7 EV")
        let location = await sections(url)["Location"]
        XCTAssertEqual(location?["Coordinates"], "-33.900000, 18.400000")
        XCTAssertEqual(location?["Altitude"], "25 m")
    }

    func testRotatedPhotoShowsItsUprightSize() async throws {
        let image = await sections(try XCTUnwrap(fixtures["rotated.jpg"]).url)["Image"]
        XCTAssertEqual(image?["Dimensions"], "200 × 320 pixels")
        XCTAssertEqual(image?["Orientation"], "Rotated 90° clockwise")
    }

    func testImageWithoutMetadataHasNoCameraSection() async throws {
        let info = await sections(try XCTUnwrap(fixtures["alpha.png"]).url)
        XCTAssertNil(info["Camera"])
        XCTAssertNil(info["Location"])
        XCTAssertEqual(info["Image"]?["Transparency"], "Yes")
    }

    func testVideoAndAudioTracks() async throws {
        let movie = root.appendingPathComponent("clip.mov")
        try await MediaSamples.writeVideo(to: movie, width: 64, height: 48, seconds: 1)
        let video = await sections(movie)
        XCTAssertEqual(video["Media"]?["Duration"], "0:01")
        XCTAssertEqual(video["Video"]?["Dimensions"], "64 × 48 pixels")
        XCTAssertEqual(video["Video"]?["Codec"], "H.264")
        XCTAssertEqual(video["Video"]?["Frame Rate"], "30 fps")

        let tone = root.appendingPathComponent("tone.wav")
        try MediaSamples.writeTone(to: tone, seconds: 2, bits: 16)
        let audio = await sections(tone)
        XCTAssertEqual(audio["Media"]?["Duration"], "0:02")
        XCTAssertEqual(audio["Audio"]?["Codec"], "PCM")
        XCTAssertEqual(audio["Audio"]?["Sample Rate"], "44.1 kHz")
        XCTAssertEqual(audio["Audio"]?["Channels"], "Stereo")
        XCTAssertNil(audio["Video"])
    }

    func testPDFDocumentInfo() async throws {
        let url = root.appendingPathComponent("report.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let docInfo: [CFString: Any] = [kCGPDFContextTitle: "Quarterly Report", kCGPDFContextAuthor: "Sam"]
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, docInfo as CFDictionary))
        for _ in 0..<3 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()

        let info = await sections(url)
        let pdf = info["PDF"]
        XCTAssertEqual(pdf?["Pages"], "3")
        XCTAssertEqual(pdf?["Title"], "Quarterly Report")
        XCTAssertEqual(pdf?["Author"], "Sam")
        XCTAssertEqual(pdf?["Security"], "None")
        XCTAssertNotNil(pdf?["Page Size"])
        XCTAssertNil(info["Image"], "a PDF isn't described as an image")
    }

    func testFolderAndDownloadSource() async throws {
        let folder = root.appendingPathComponent("stuff", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("a.txt")
        try "a".write(to: file, atomically: true, encoding: .utf8)
        try "b".write(to: folder.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        let folderInfo = await FileMetadata.sections(for: folder)
        XCTAssertEqual(folderInfo.map(\.title), ["File"])
        XCTAssertEqual(folderInfo.first?["Contents"], "2 items")

        let froms = try PropertyListSerialization.data(fromPropertyList: ["https://example.com/a.txt", ""],
                                                       format: .binary, options: 0)
        let status = froms.withUnsafeBytes {
            setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", $0.baseAddress, froms.count, 0, 0)
        }
        XCTAssertEqual(status, 0)
        let fileInfo = await sections(file)
        XCTAssertEqual(fileInfo["File"]?["Downloaded From"], "https://example.com/a.txt")
    }

    func testTextForCopying() async throws {
        let text = FileMetadata.text(await FileMetadata.sections(for: try XCTUnwrap(fixtures["photo.jpg"]).url))
        XCTAssertTrue(text.hasPrefix("File\nKind: "))
        XCTAssertTrue(text.contains("\n\nCamera\nMake: TestCam\nModel: One"))
    }
}
