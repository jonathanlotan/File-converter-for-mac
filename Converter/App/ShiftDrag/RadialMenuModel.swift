import ConverterCore
import Foundation

/// What the wheel shows for the files being dragged, and what the cursor is
/// over. It has three rings: formats to convert to, file tools, and file
/// actions. The first two come from `ConversionMenuModel`, so they match the
/// menu bar picker.
@MainActor
final class RadialMenuModel: ObservableObject {
    enum Phase: Equatable {
        /// Shown, but the drag hasn't entered the panel yet, so the files
        /// aren't known.
        case waiting
        case ready
        case unavailable(String)
    }

    /// What a drop on a slice does.
    enum Target {
        case convert(any Converter)
        case action(FileAction)

        var id: String {
            switch self {
            case .convert(let converter): return converter.id
            case .action(let action): return action.id
            }
        }

        var title: String {
            switch self {
            case .convert(let converter): return converter.title
            case .action(let action): return action.title
            }
        }
    }

    struct Slice: Identifiable {
        let id: Int
        let title: String
        let symbol: String?
        /// Set for a single conversion.
        var converter: (any Converter)?
        /// Set for a file action.
        var action: FileAction?
        /// Members of a group ("More Formats", "Resize", "Share"); empty otherwise.
        var members: [Target] = []

        var isGroup: Bool { converter == nil && action == nil }
    }

    let geometry: RadialGeometry
    let registry: ConverterRegistry
    /// Converter ids the user put first (read each time the ring fills).
    let preferred: () -> [String]
    /// Which key opens which ring, for the hint in the middle.
    var ringKeys: () -> RingKeys = { .standard }
    /// The file actions that work for the dragged files on this Mac.
    var availableActions: ([URL]) -> [FileAction] = { FileAction.available(for: $0) }
    /// Drives the appear and disappear animation.
    @Published var isPresented = false
    @Published private(set) var phase: Phase = .waiting
    @Published private(set) var mode: RingMode = .formats
    @Published private(set) var hit: RadialGeometry.Hit = .outside
    /// Index of the group slice whose sub-ring is open.
    @Published private(set) var openGroup: Int?
    private(set) var inputs: [InputFile] = []
    private var rings: [RingMode: [Slice]] = [:]

    init(geometry: RadialGeometry = RadialGeometry(), registry: ConverterRegistry = .standard,
         preferred: @escaping () -> [String] = { [] }) {
        self.geometry = geometry
        self.registry = registry
        self.preferred = preferred
    }

    /// The slices of the ring on show.
    var slices: [Slice] { rings[mode] ?? [] }

    func reset(mode: RingMode = .formats) {
        phase = .waiting
        rings = [:]
        inputs = []
        self.mode = mode
        hit = .outside
        openGroup = nil
    }

    /// Shows another ring; keeps the loaded files.
    func setMode(_ mode: RingMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        hit = .outside
        openGroup = nil
    }

    /// Fills all three rings for the dragged files.
    func load(_ urls: [URL]) {
        let inputs = urls.compactMap { try? InputFile(url: $0) }
        self.inputs = inputs
        hit = .outside
        openGroup = nil
        guard !inputs.isEmpty else {
            rings = [:]
            phase = .unavailable("Nothing to work with")
            return
        }
        let menu = ConversionMenuModel(converters: registry.converters(for: inputs), preferred: preferred())
        rings[.formats] = Self.slices(from: menu.formats)
        rings[.tools] = Self.slices(from: menu.tools)
        rings[.actions] = Self.slices(from: availableActions(inputs.map(\.url)))
        phase = .ready
    }

    private static func slices(from entries: [ConversionMenuModel.Entry]) -> [Slice] {
        entries.enumerated().map { index, entry in
            switch entry {
            case .converter(let converter):
                return Slice(id: index, title: converter.title, symbol: symbol(for: converter), converter: converter)
            case .group(let title, let members):
                // Slices are narrow: the menu bar's "More Formats" is just "More" here.
                let short = title == ConversionMenuModel.moreFormatsTitle ? "More" : title
                return Slice(id: index, title: short, symbol: symbol(forGroup: title), members: members.map(Target.convert))
            }
        }
    }

    /// One slice per action, with grouped actions ("Share") in a sub-ring.
    private static func slices(from actions: [FileAction]) -> [Slice] {
        var slices: [Slice] = []
        for action in actions {
            guard let group = action.group else {
                slices.append(Slice(id: slices.count, title: action.title, symbol: action.symbol, action: action))
                continue
            }
            if let index = slices.firstIndex(where: { $0.isGroup && $0.title == group }) {
                slices[index].members.append(.action(action))
            } else {
                slices.append(Slice(id: slices.count, title: group, symbol: symbol(forGroup: group), members: [.action(action)]))
            }
        }
        return slices
    }

    var openGroupMembers: [Target] {
        openGroup.map { slices[$0].members } ?? []
    }

    /// Updates what's under the cursor (y-up point relative to the centre).
    /// Returns the group slice to open after a short dwell, if the cursor
    /// just moved onto one.
    @discardableResult
    func hover(at point: CGPoint) -> Int? {
        let open = openGroup.map { (parent: $0, members: slices[$0].members.count) }
        let newHit = geometry.hit(point, count: phase == .ready ? slices.count : 0, openGroup: open)
        defer { hit = newHit }
        switch newHit {
        case .slice(let index):
            if index != openGroup { openGroup = nil }
            return slices[index].isGroup && index != openGroup && newHit != hit ? index : nil
        case .center:
            openGroup = nil
            return nil
        case .subSlice, .outside:
            return nil
        }
    }

    func openGroup(_ index: Int) {
        guard slices.indices.contains(index), slices[index].isGroup, hit == .slice(index) else { return }
        openGroup = index
    }

    func clearHover() {
        hit = .outside
    }

    /// What a drop at the current position would do; nil means it cancels.
    var target: Target? {
        switch hit {
        case .slice(let index):
            guard slices.indices.contains(index) else { return nil }
            if let converter = slices[index].converter { return .convert(converter) }
            return slices[index].action.map(Target.action)
        case .subSlice(let index):
            let members = openGroupMembers
            return members.indices.contains(index) ? members[index] : nil
        case .center, .outside:
            return nil
        }
    }

    /// Text for the middle of the ring.
    var caption: (title: String, detail: String?) {
        switch phase {
        case .waiting:
            return (mode.title, nil)
        case .unavailable(let message):
            return (message, nil)
        case .ready:
            if hit == .center { return ("Cancel", nil) }
            if slices.isEmpty { return (emptyMessage, "Scroll for more") }
            switch target {
            case .convert(let converter):
                return (converter.title, OutputPreview.name(of: converter, for: inputs) ?? "\(inputs.count) files")
            case .action(let action):
                let title = action == .shareMore ? "Share…" : action.title
                return (title, inputs.count == 1 ? inputs[0].url.lastPathComponent : "\(inputs.count) items")
            case nil:
                if case .slice(let index) = hit, slices[index].isGroup { return (slices[index].title, nil) }
                return (inputs.count == 1 ? inputs[0].url.lastPathComponent : "\(inputs.count) items", nil)
            }
        }
    }

    private var emptyMessage: String {
        switch mode {
        case .formats: return inputs.count == 1 ? "No formats for this" : "No common format"
        case .tools: return inputs.count == 1 ? "No tools for this" : "No common tool"
        case .actions: return "No actions"
        }
    }

    private static func symbol(for converter: any Converter) -> String? {
        switch converter.id {
        case "image.compress", "video.compress", "audio.compress", "pdf.compress": return "arrow.down.right.and.arrow.up.left"
        case "image.stripMetadata", "video.stripMetadata", "pdf.stripMetadata": return "eye.slash"
        case let id where id.hasPrefix("image.crop."): return "crop"
        case "ocr.text": return "text.viewfinder"
        case "video.removeAudio": return "speaker.slash"
        case "pdf.split", "pdf.merge", "image.combinePDF": return "doc.on.doc"
        case "image.pdf", "document.pdf": return "doc"
        case "archive.extract": return "archivebox"
        case "video.frame": return "camera"
        case let id where id.hasPrefix("image.video."): return "film"
        default: return nil
        }
    }

    private static func symbol(forGroup title: String) -> String? {
        switch title {
        case "Resize": return "arrow.up.left.and.arrow.down.right"
        case "Crop": return "crop"
        case FileAction.shareGroup: return "square.and.arrow.up"
        case "Audio": return "waveform"
        case "Archive": return "archivebox"
        default: return "ellipsis"
        }
    }
}
