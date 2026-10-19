import ConverterCore
import ImageIO
import XCTest
@testable import ConverterApp

final class SVGRasterizerTests: XCTestCase {
    var folder: URL!
    var svg: URL!

    override func setUpWithError() throws {
        folder = try makeTemporaryFolder("SVG")
        svg = folder.appendingPathComponent("logo.svg")
        let markup = """
        <svg xmlns="http://www.w3.org/2000/svg" width="40" height="20" viewBox="0 0 40 20">
          <rect width="20" height="20" fill="#ff0000"/>
        </svg>
        """
        try markup.write(to: svg, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRendersAtLeast1024PixelsWithTransparency() throws {
        let data = try SVGRasterizer().rasterize(svg)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 512)

        // Left half is the red square, right half is transparent.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        func sample(_ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * image.width + x) * 4
            return Array(pixels[i..<i + 4])
        }
        let left = sample(256, 256), right = sample(768, 256)
        XCTAssertGreaterThan(left[0], 240)
        XCTAssertLessThan(left[1], 20)
        XCTAssertLessThan(right[3], 10, "outside the square should stay transparent")
    }

    func testSVGConvertsThroughTheRegistry() async throws {
        // The app registers SVGRasterizer at launch; tests run inside the app.
        let input = try InputFile(url: svg)
        let info = try XCTUnwrap(input.image, "SVG rasterizer isn't registered")
        XCTAssertEqual(info.typeIdentifier, "public.svg-image")
        let ids = ConverterRegistry.standard.converters(for: [input]).map(\.id)
        XCTAssertTrue(ids.contains("image.png"))
        XCTAssertTrue(ids.contains("image.jpeg"))

        let png = try XCTUnwrap(ConverterRegistry.standard.converter(id: "image.png"))
        let output = try await JobRunner.run(png, on: input)
        XCTAssertEqual(output.lastPathComponent, "logo.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 1024)
    }
}
