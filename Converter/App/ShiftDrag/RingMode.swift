import AppKit

/// The three rings the wheel can show while files are dragged.
enum RingMode: String, CaseIterable, Codable, Identifiable {
    case formats, tools, actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .formats: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }

    /// The ring `steps` away, wrapping around (used when scrolling).
    func advanced(by steps: Int) -> RingMode {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        return all[((index + steps) % all.count + all.count) % all.count]
    }
}

/// A modifier key that can open a ring when tapped during a drag.
enum ModifierKey: String, CaseIterable, Codable, Identifiable {
    case shift, command, control, option

    var id: String { rawValue }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .command: return "⌘"
        case .control: return "⌃"
        case .option: return "⌥"
        }
    }

    var title: String {
        switch self {
        case .shift: return "Shift"
        case .command: return "Command"
        case .control: return "Control"
        case .option: return "Option"
        }
    }

    static func pressed(in flags: NSEvent.ModifierFlags) -> Set<ModifierKey> {
        Set(allCases.filter { flags.contains($0.flag) })
    }
}

/// Which key opens which ring. Each key opens at most one ring; a ring
/// can have no key (it's still reachable by scrolling).
struct RingKeys: Equatable, Codable {
    private(set) var keys: [RingMode: ModifierKey]

    static let standard = RingKeys(keys: [.formats: .shift, .tools: .command, .actions: .control])

    func key(for mode: RingMode) -> ModifierKey? {
        keys[mode]
    }

    func mode(for key: ModifierKey) -> RingMode? {
        keys.first { $0.value == key }?.key
    }

    /// Gives `mode` this key. A ring that had it swaps to `mode`'s old key.
    mutating func assign(_ key: ModifierKey?, to mode: RingMode) {
        let previous = keys[mode]
        if let key, let other = self.mode(for: key), other != mode {
            keys[other] = previous
        }
        keys[mode] = key
    }
}
