import Foundation
import XCTest
@testable import ConverterCore

/// Saved options survive the addition of new ones.
final class ConversionOptionsTests: XCTestCase {
    func testRoundTrip() throws {
        var options = ConversionOptions()
        options.compressionAudioBitRate = 96
        options.videoCompression = .better
        let data = try JSONEncoder().encode(options)
        XCTAssertEqual(try JSONDecoder().decode(ConversionOptions.self, from: data), options)
    }

    func testOptionsSavedBeforeAnOptionExistedKeepTheirValues() throws {
        // What the app stored before "Compress audio" had a bit rate.
        let saved = Data("""
        {"imageQuality":0.7,"compressionQuality":0.6,"keepMetadata":false,"audioBitRate":320,
         "gifFrameRate":15,"gifMaxSide":640,"pdfRenderDPI":300,"videoCompression":"smaller"}
        """.utf8)
        let options = try JSONDecoder().decode(ConversionOptions.self, from: saved)
        XCTAssertEqual(options.imageQuality, 0.7)
        XCTAssertFalse(options.keepMetadata)
        XCTAssertEqual(options.audioBitRate, 320)
        XCTAssertEqual(options.videoCompression, .smaller)
        XCTAssertEqual(options.compressionAudioBitRate, 128, "the new option takes its default")
    }
}
