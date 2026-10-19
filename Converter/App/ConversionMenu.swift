import AppKit
import ConverterCore

/// How the conversions for a set of files are laid out: main formats,
/// "More Formats", then tools with their groups (e.g. "Resize"). The menus
/// here and the radial menu (milestone 3) both use this model.
struct ConversionMenuModel {
    enum Entry {
        case converter(any Converter)
        case group(title: String, converters: [any Converter])
    }

    var formats: [Entry] = []
    var tools: [Entry] = []

    static let moreFormatsTitle = "More Formats"

    /// `preferred` converter ids come first (even ones normally under
    /// "More Formats"), in the order given.
    init(converters: [any Converter], preferred: [String] = []) {
        let formatConverters = converters.filter { $0.role == .format }
        let favourites = preferred.compactMap { id in formatConverters.first { $0.id == id } }
        let others = formatConverters.filter { !preferred.contains($0.id) }
        formats = Self.entries(favourites + others.filter { !$0.isSecondary })
        let secondary = others.filter(\.isSecondary)
        if !secondary.isEmpty {
            formats.append(.group(title: Self.moreFormatsTitle, converters: secondary))
        }
        tools = Self.entries(converters.filter { $0.role == .tool })
        // Nothing but one group (a folder offers only "Archive"): show its
        // members directly rather than a single submenu.
        if formats.isEmpty, tools.count == 1, case .group(_, let members) = tools[0] {
            tools = members.map { .converter($0) }
        }
    }

    var isEmpty: Bool { formats.isEmpty && tools.isEmpty }

    /// Top-level converters in order; grouped ones collapse into one entry
    /// at the position of the first member.
    private static func entries(_ converters: [any Converter]) -> [Entry] {
        var result: [Entry] = []
        var groupIndex: [String: Int] = [:]
        for converter in converters {
            guard let group = converter.menuGroup else {
                result.append(.converter(converter))
                continue
            }
            if let index = groupIndex[group], case .group(let title, let members) = result[index] {
                result[index] = .group(title: title, converters: members + [converter])
            } else {
                groupIndex[group] = result.count
                result.append(.group(title: group, converters: [converter]))
            }
        }
        return result
    }
}

/// Builds the format picker shown after files are dropped or chosen.
@MainActor
enum ConversionMenu {
    /// Formats, then tools, then file actions (when `onAction` is given).
    static func make(for inputs: [InputFile], converters: [any Converter], preferred: [String] = [],
                     onPick: @escaping (any Converter) -> Void,
                     onAction: ((FileAction) -> Void)? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let heading = inputs.count == 1
            ? "Convert “\(inputs[0].url.lastPathComponent)”"
            : "Convert \(inputs.count) files"
        menu.addItem(header(heading))

        let model = ConversionMenuModel(converters: converters, preferred: preferred)
        if model.isEmpty {
            menu.addItem(disabledItem(inputs.count == 1 ? "No conversions for this file"
                                                        : "No conversion works for all of these files"))
        }
        defer {
            // Actions work for any file or folder, convertible or not.
            if let onAction {
                menu.addItem(.separator())
                menu.addItem(header("Actions"))
                // The system's Share item lists every service, so the
                // wheel's Share shortcuts aren't repeated here.
                menu.addItem(shareItem(inputs.map(\.url)))
                for action in FileAction.all where action.group == nil {
                    let item = ActionMenuItem(title: action.title) { onAction(action) }
                    MenuIcons.set(action.symbol, on: item)
                    menu.addItem(item)
                }
            }
        }
        if model.isEmpty { return menu }

        func add(_ entries: [ConversionMenuModel.Entry], to menu: NSMenu) {
            for entry in entries {
                switch entry {
                case .converter(let converter):
                    menu.addItem(item(for: converter, inputs: inputs, onPick: onPick))
                case .group(let title, let members):
                    let submenu = NSMenu(title: title)
                    submenu.autoenablesItems = false
                    members.forEach { submenu.addItem(item(for: $0, inputs: inputs, onPick: onPick)) }
                    let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    parent.submenu = submenu
                    menu.addItem(parent)
                }
            }
        }
        add(model.formats, to: menu)
        if !model.tools.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Tools"))
            add(model.tools, to: menu)
        }
        return menu
    }

    private static func item(for converter: any Converter, inputs: [InputFile],
                             onPick: @escaping (any Converter) -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title: converter.title) { onPick(converter) }
        if let name = OutputPreview.name(of: converter, for: inputs) {
            item.toolTip = "Saves “\(name)” next to the original"
        }
        return item
    }

    /// Share ›, with AirDrop, Mail, Messages, Notes and the rest.
    static func shareItem(_ urls: [URL]) -> NSMenuItem {
        let item = SharePicker.shared.menuItem(for: urls)
        if item.image == nil { MenuIcons.set(FileAction.shareMore.symbol, on: item) }
        return item
    }

    /// A section title: the system's section header from macOS 14, a
    /// greyed-out item before that.
    static func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return .sectionHeader(title: title) }
        return disabledItem(title)
    }

    static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

/// A menu item that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func run() {
        handler()
    }
}

/// The name a conversion will save, as shown before it runs. Several files
/// that each get their own output have no single name (nil).
enum OutputPreview {
    static func name(of converter: any Converter, for inputs: [InputFile]) -> String? {
        guard let first = inputs.first else { return nil }
        guard inputs.count == 1 || converter.combinesInputs else { return nil }
        let spec = converter.combinesInputs ? converter.output(for: inputs) : converter.output(for: first)
        return OutputNamer.firstAvailable(in: first.url.deletingLastPathComponent(),
                                          base: spec.baseName ?? first.baseName, spec: spec).lastPathComponent
    }
}

/// SF Symbols beside menu items, the way the system's own menus use them:
/// macOS 26 shows icons in menus; earlier versions don't, so no icon is set
/// there; on macOS 27 AppKit decides when to show them (the item's
/// `preferredImageVisibility` stays `.automatic`, usually hidden).
enum MenuIcons {
    static func set(_ symbol: String, on item: NSMenuItem) {
        guard #available(macOS 26.0, *) else { return }
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }
}
