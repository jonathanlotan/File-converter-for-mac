import AppKit
import SwiftUI
import XCTest
@testable import ConverterApp

/// Renders the radial menu offscreen to PNGs for a visual check, in light
/// and dark mode. Writes to ~/Library/Caches/Converter/Snapshots.
@MainActor
final class RadialSnapshotTests: XCTestCase {
    func testRenderSnapshots() async throws {
        let folder = try makeTemporaryFolder("Snapshot")
        defer { try? FileManager.default.removeItem(at: folder) }
        // Encoding a large HEIC on the main thread trips XCTest's main-thread checker.
        let photo = try await Task.detached {
            try makeImage("IMG_2041.heic", in: folder, width: 4032, height: 3024, type: "public.heic").url
        }.value
        let out = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Converter/Snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let model = RadialMenuModel()
        model.isPresented = true // as after the appear animation
        model.load([photo])
        let g = model.geometry
        let r = (g.innerRadius + g.outerRadius) / 2
        func ringPoint(_ index: Int) -> CGPoint {
            let a = g.centerAngle(ofSlice: index, count: model.slices.count)
            return CGPoint(x: r * CGFloat(sin(a)), y: r * CGFloat(cos(a)))
        }

        // 1. Hovering the first format.
        model.hover(at: ringPoint(0))
        try render(model, to: out.appendingPathComponent("radial-hover"))

        // 2. "Resize" open with a member highlighted (tools ring).
        model.setMode(.tools)
        let resize = try XCTUnwrap(model.slices.firstIndex { $0.title == "Resize" })
        model.hover(at: ringPoint(resize))
        model.openGroup(resize)
        let a = g.subCenterAngle(member: 1, members: model.openGroupMembers.count, parent: resize, count: model.slices.count)
        let sr = (g.subInnerRadius + g.subOuterRadius) / 2
        model.hover(at: CGPoint(x: sr * CGFloat(sin(a)), y: sr * CGFloat(cos(a))))
        try render(model, to: out.appendingPathComponent("radial-subring"))

        // 3. The actions ring, hovering Copy Path.
        model.setMode(.actions)
        model.hover(at: ringPoint(try XCTUnwrap(model.slices.firstIndex { $0.title == "Copy Path" })))
        try render(model, to: out.appendingPathComponent("radial-actions"))

        // 4. Share open, hovering Mail.
        model.hover(at: ringPoint(0))
        model.openGroup(0)
        let mail = g.subCenterAngle(member: 1, members: model.openGroupMembers.count, parent: 0, count: model.slices.count)
        model.hover(at: CGPoint(x: sr * CGFloat(sin(mail)), y: sr * CGFloat(cos(mail))))
        try render(model, to: out.appendingPathComponent("radial-share"))

        // 5. Crop open (tools ring).
        model.setMode(.tools)
        let crop = try XCTUnwrap(model.slices.firstIndex { $0.title == "Crop" })
        model.hover(at: ringPoint(crop))
        model.openGroup(crop)
        try render(model, to: out.appendingPathComponent("radial-crop"))
        model.setMode(.actions)

        // 6. Over the centre (cancel).
        model.hover(at: .zero)
        try render(model, to: out.appendingPathComponent("radial-cancel"))
        print("snapshots in \(out.path)")
    }

    private func render(_ model: RadialMenuModel, to base: URL) throws {
        for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                let view = RadialMenuView(model: model)
                    .background(suffix == "dark" ? Color(white: 0.16) : Color(white: 0.93))
                    .environment(\.colorScheme, suffix == "dark" ? .dark : .light)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation {
                    data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
                }
            }
            let png = try XCTUnwrap(data, "rendering failed")
            try png.write(to: base.appendingPathExtension("\(suffix).png"))
        }
    }
}

/// The middle of the wheel shrinks long names, and shortens a word only as
/// a last resort, instead of breaking it across lines ("IMG_2041.he / ic").
@MainActor
final class CentreCaptionTests: XCTestCase {
    private final class Results {
        var fitted: [(string: String, size: CGFloat)] = []
    }

    func testLongNamesFitWithoutBreakingWords() throws {
        let results = Results()
        let canvas = Canvas { context, _ in
            for name in ["JPEG", "IMG_2041.heic", "Screenshot_2026-10-19_at_22.41.07.png", "IMG_2041 (square).heic"] {
                results.fitted.append(RadialMenuView.fit(name, width: 80, size: 12, minimum: 9.5, weight: .semibold,
                                                         in: context))
            }
        }
        .frame(width: 10, height: 10)
        XCTAssertNotNil(ImageRenderer(content: canvas).cgImage)
        XCTAssertEqual(results.fitted.count, 4)
        XCTAssertEqual(results.fitted[0].string, "JPEG")
        XCTAssertEqual(results.fitted[0].size, 12, "short names keep the full size")
        XCTAssertEqual(results.fitted[1].string, "IMG_2041.heic", "shrunk, not cut")
        XCTAssertLessThan(results.fitted[1].size, 12)
        XCTAssertTrue(results.fitted[2].string.contains("…"), "too long even when small: shortened in the middle")
        XCTAssertTrue(results.fitted[2].string.hasSuffix(".png"))
        XCTAssertEqual(results.fitted[3].string, "IMG_2041 (square).heic", "words that fit are left whole")
    }
}
