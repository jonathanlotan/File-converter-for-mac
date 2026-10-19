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
        model.hover(at: ringPoint(4))
        try render(model, to: out.appendingPathComponent("radial-actions"))

        // 4. Over the centre (cancel).
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
