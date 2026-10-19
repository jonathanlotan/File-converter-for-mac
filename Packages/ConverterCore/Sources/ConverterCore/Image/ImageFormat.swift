import Foundation

/// An image format Converter can write.
public struct ImageFormat: Sendable, Hashable {
    enum Writer: Sendable, Hashable {
        /// `CGImageDestination` for `typeIdentifier`.
        case imageIO
        /// One PDF page per image, drawn with a Core Graphics PDF context.
        case pdf
        /// One square image per size, largest no bigger than the source allows.
        /// ImageIO's ICO writer takes at most 6 images, and its ICNS writer
        /// drops 64 px and 1024 px (both probed on macOS 26).
        case icon(sizes: [Int])
    }

    public let id: String
    public let title: String
    public let typeIdentifier: String
    public let fileExtension: String
    public let supportsAlpha: Bool
    public let isLossy: Bool
    /// Keeps every frame of an animated source.
    public let supportsAnimation: Bool
    /// Keeps every page of a multi-page source (TIFF).
    public let supportsMultiplePages: Bool
    /// Can carry EXIF/GPS/IPTC metadata.
    public let carriesMetadata: Bool
    public let isSecondary: Bool
    let writer: Writer

    /// The encoder exists on this system.
    public var isWritable: Bool {
        writer == .pdf || ImageCodec.writableTypes.contains(typeIdentifier)
    }

    /// True if an input of ImageIO type `typeIdentifier` is already this format.
    func matches(_ inputType: String) -> Bool {
        if inputType == typeIdentifier { return true }
        let heifFamily: Set<String> = ["public.heic", "public.heif"]
        return heifFamily.contains(inputType) && heifFamily.contains(typeIdentifier)
    }

    public static let jpeg = ImageFormat(id: "jpeg", title: "JPEG", typeIdentifier: "public.jpeg", fileExtension: "jpg",
                                         supportsAlpha: false, isLossy: true, supportsAnimation: false, supportsMultiplePages: false,
                                         carriesMetadata: true, isSecondary: false, writer: .imageIO)
    public static let png = ImageFormat(id: "png", title: "PNG", typeIdentifier: "public.png", fileExtension: "png",
                                        supportsAlpha: true, isLossy: false, supportsAnimation: false, supportsMultiplePages: false,
                                        carriesMetadata: true, isSecondary: false, writer: .imageIO)
    public static let heic = ImageFormat(id: "heic", title: "HEIC", typeIdentifier: "public.heic", fileExtension: "heic",
                                         supportsAlpha: true, isLossy: true, supportsAnimation: false, supportsMultiplePages: false,
                                         carriesMetadata: true, isSecondary: false, writer: .imageIO)
    public static let avif = ImageFormat(id: "avif", title: "AVIF", typeIdentifier: "public.avif", fileExtension: "avif",
                                         supportsAlpha: true, isLossy: true, supportsAnimation: false, supportsMultiplePages: false,
                                         carriesMetadata: true, isSecondary: false, writer: .imageIO)
    public static let tiff = ImageFormat(id: "tiff", title: "TIFF", typeIdentifier: "public.tiff", fileExtension: "tiff",
                                         supportsAlpha: true, isLossy: false, supportsAnimation: false, supportsMultiplePages: true,
                                         carriesMetadata: true, isSecondary: false, writer: .imageIO)
    public static let gif = ImageFormat(id: "gif", title: "GIF", typeIdentifier: "com.compuserve.gif", fileExtension: "gif",
                                        supportsAlpha: true, isLossy: false, supportsAnimation: true, supportsMultiplePages: false,
                                        carriesMetadata: false, isSecondary: false, writer: .imageIO)
    public static let pdf = ImageFormat(id: "pdf", title: "PDF", typeIdentifier: "com.adobe.pdf", fileExtension: "pdf",
                                        supportsAlpha: true, isLossy: false, supportsAnimation: false, supportsMultiplePages: true,
                                        carriesMetadata: false, isSecondary: false, writer: .pdf)
    public static let bmp = ImageFormat(id: "bmp", title: "BMP", typeIdentifier: "com.microsoft.bmp", fileExtension: "bmp",
                                        supportsAlpha: false, isLossy: false, supportsAnimation: false, supportsMultiplePages: false,
                                        carriesMetadata: false, isSecondary: true, writer: .imageIO)
    public static let jpeg2000 = ImageFormat(id: "jp2", title: "JPEG 2000", typeIdentifier: "public.jpeg-2000", fileExtension: "jp2",
                                             supportsAlpha: true, isLossy: true, supportsAnimation: false, supportsMultiplePages: false,
                                             carriesMetadata: true, isSecondary: true, writer: .imageIO)
    public static let icns = ImageFormat(id: "icns", title: "ICNS", typeIdentifier: "com.apple.icns", fileExtension: "icns",
                                         supportsAlpha: true, isLossy: false, supportsAnimation: false, supportsMultiplePages: false,
                                         carriesMetadata: false, isSecondary: true, writer: .icon(sizes: [16, 32, 48, 128, 256, 512]))
    public static let ico = ImageFormat(id: "ico", title: "ICO", typeIdentifier: "com.microsoft.ico", fileExtension: "ico",
                                        supportsAlpha: true, isLossy: false, supportsAnimation: false, supportsMultiplePages: false,
                                        carriesMetadata: false, isSecondary: true, writer: .icon(sizes: [16, 32, 48, 64, 128, 256]))
    public static let psd = ImageFormat(id: "psd", title: "PSD", typeIdentifier: "com.adobe.photoshop-image", fileExtension: "psd",
                                        supportsAlpha: true, isLossy: false, supportsAnimation: false, supportsMultiplePages: false,
                                        carriesMetadata: true, isSecondary: true, writer: .imageIO)
    public static let tga = ImageFormat(id: "tga", title: "TGA", typeIdentifier: "com.truevision.tga-image", fileExtension: "tga",
                                        supportsAlpha: true, isLossy: false, supportsAnimation: false, supportsMultiplePages: false,
                                        carriesMetadata: false, isSecondary: true, writer: .imageIO)

    /// Menu order: main ring first, then secondary formats.
    public static let all: [ImageFormat] = [jpeg, png, heic, avif, tiff, gif, pdf, bmp, jpeg2000, icns, ico, psd, tga]

    /// The writable format an input already is, for tools that keep the
    /// format (resize, compress). Icons and PDFs aren't reused.
    static func existing(for inputType: String) -> ImageFormat? {
        all.first { $0.matches(inputType) && $0.isWritable && $0.writer == .imageIO }
    }
}
