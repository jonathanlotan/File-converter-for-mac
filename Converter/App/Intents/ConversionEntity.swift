import AppIntents
import ConverterCore

/// One of Swivel's conversions as Shortcuts sees it: the Convert File
/// action's "Conversion" parameter. Identified by the converter's stable
/// id (`image.jpeg`, `image.resize.1920`), shown with its group ("Resize ›
/// 1920 px") and the kind of file it applies to ("Images"), since several
/// kinds have a "Compress" or a "PDF".
struct ConversionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversion")
    static let defaultQuery = ConversionQuery()

    let id: String
    /// The title with its group: "JPEG", "Resize › 1920 px", "Crop › Square".
    let name: String
    /// What the conversion applies to, from the id's prefix: "Images", "Video", ...
    let kind: String?
    private let symbolName: String

    init(_ converter: any Converter) {
        id = converter.id
        name = converter.menuGroup.map { "\($0) › \(converter.title)" } ?? converter.title
        let family = Family(id: converter.id)
        kind = family?.title
        symbolName = family?.symbolName ?? "arrow.triangle.2.circlepath"
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: kind.map { "\($0)" },
                              image: .init(systemName: symbolName))
    }

    /// The kinds of file the converter ids are grouped by.
    private enum Family {
        case images, animatedImages, video, audio, documents, pdfs, archives, scans

        init?(id: String) {
            if id.hasPrefix("image.video.") { self = .animatedImages }
            else if id.hasPrefix("image.") { self = .images }
            else if id.hasPrefix("video.") { self = .video }
            else if id.hasPrefix("audio.") { self = .audio }
            else if id.hasPrefix("document.") { self = .documents }
            else if id.hasPrefix("pdf.") { self = .pdfs }
            else if id.hasPrefix("archive.") { self = .archives }
            else if id.hasPrefix("ocr.") { self = .scans }
            else { return nil }
        }

        var title: String {
            switch self {
            case .images: return "Images"
            case .animatedImages: return "Animated images"
            case .video: return "Video"
            case .audio: return "Audio"
            case .documents: return "Documents"
            case .pdfs: return "PDFs"
            case .archives: return "Archives"
            case .scans: return "Images and PDFs"
            }
        }

        var symbolName: String {
            switch self {
            case .images: return "photo"
            case .animatedImages: return "photo.stack"
            case .video: return "film"
            case .audio: return "waveform"
            case .documents: return "doc.text"
            case .pdfs: return "doc.richtext"
            case .archives: return "archivebox"
            case .scans: return "text.viewfinder"
            }
        }
    }
}

/// Finds conversions for Shortcuts: by id when a shortcut runs, by name as
/// the user types in the picker, and a suggested set for the picker's
/// first page. Lists what the app's registry can run on this Mac, minus
/// tools that open a window (Crop › Custom…): an action must not show UI.
///
/// App Intents can only narrow a picker by the files already chosen
/// through `@IntentParameterDependency`, which needs macOS 14; the app
/// runs on 13, so the Convert File action checks the files when it runs
/// instead, and says which one a conversion can't be made from.
struct ConversionQuery: EntityQuery, EntityStringQuery {
    /// The picker's first page, in the wheel's order.
    static let suggestedIDs = [
        "image.jpeg", "image.png", "image.heic", "video.mp4", "audio.m4a", "image.pdf", "document.pdf",
        "image.compress", "video.compress", "image.stripMetadata",
    ]

    func entities(for identifiers: [String]) async throws -> [ConversionEntity] {
        let all = await IntentSupport.conversions()
        return identifiers.compactMap { id in all.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [ConversionEntity] {
        try await entities(for: Self.suggestedIDs)
    }

    func entities(matching string: String) async throws -> [ConversionEntity] {
        await IntentSupport.conversions().filter { entity in
            entity.name.localizedCaseInsensitiveContains(string)
                || entity.kind?.localizedCaseInsensitiveContains(string) == true
        }
    }
}

/// From macOS 14 the picker can list every conversion, not only the
/// suggested ones.
@available(macOS 14, *)
extension ConversionQuery: EnumerableEntityQuery {
    func allEntities() async throws -> [ConversionEntity] {
        await IntentSupport.conversions()
    }
}
