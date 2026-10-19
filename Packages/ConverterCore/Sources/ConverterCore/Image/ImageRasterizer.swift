import Foundation
import os
import UniformTypeIdentifiers

/// Renders a file ImageIO can't read (such as SVG) into image data it can.
/// ConverterCore has no UI imports, so renderers that need AppKit live in
/// the app and register here at launch.
public protocol ImageRasterizer: Sendable {
    /// Types this rasterizer handles, e.g. `UTType.svg`.
    var supportedTypes: [UTType] { get }
    /// PNG (or any ImageIO-readable) data for the file.
    func rasterize(_ url: URL) throws -> Data
}

public enum ImageRasterizers {
    private static let registered = OSAllocatedUnfairLock<[any ImageRasterizer]>(initialState: [])

    public static func register(_ rasterizer: any ImageRasterizer) {
        registered.withLock { $0.append(rasterizer) }
    }

    /// Removes every registered rasterizer (for tests).
    public static func removeAll() {
        registered.withLock { $0.removeAll() }
    }

    static func rasterizer(for type: UTType) -> (any ImageRasterizer)? {
        registered.withLock { list in
            list.first { rasterizer in rasterizer.supportedTypes.contains { type.conforms(to: $0) } }
        }
    }
}
