import AppKit

/// Everything a key can trigger. The keyboard, the menus and the shortcuts settings all come
/// from here. Adding a command: a case, its line in `spec`, and what it does in
/// `ViewerController.perform` (the compiler asks for the last two).
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case next, previous, jumpForward, jumpBackward
    case delete, undo, revealInFinder
    case toggleZoom, zoomToFocus, toggleInfo, toggleStrip, exit
    case compare, keepSelected

    /// Groups of the shortcuts settings, in display order.
    enum Group: String, CaseIterable, Sendable {
        case navigation = "Navigation"
        case sorting = "Tri"
        case display = "Affichage"
        case comparison = "Comparaison"
    }

    struct Spec: Sendable {
        let title: String
        let group: Group
        let keys: [KeyBinding]
        /// Holding the key repeats the command. Only navigation does: holding a delete key
        /// must never wipe a folder, and a toggle must toggle once.
        var repeats = false
    }

    /// One line per command. The raw value is stored with the user's keys: never rename a case.
    var spec: Spec {
        switch self {
        case .next: Spec(title: "Photo suivante", group: .navigation, keys: [.code(124), .code(125), .code(49)], repeats: true)
        case .previous: Spec(title: "Photo précédente", group: .navigation, keys: [.code(123), .code(126)], repeats: true)
        case .jumpForward: Spec(title: "Avancer de 10 photos", group: .navigation, keys: [.code(121)], repeats: true)
        case .jumpBackward: Spec(title: "Reculer de 10 photos", group: .navigation, keys: [.code(116)], repeats: true)
        case .delete: Spec(title: "Mettre à la corbeille", group: .sorting, keys: [.code(51), .code(117), .character("x"), .code(51, modifiers: .command)])
        case .undo: Spec(title: "Annuler la suppression", group: .sorting, keys: [.character("z", modifiers: .command)])
        case .revealInFinder: Spec(title: "Afficher dans le Finder", group: .sorting, keys: [.character("r")])
        case .toggleZoom: Spec(title: "100 % ou ajusté", group: .display, keys: [.character("z")])
        case .zoomToFocus: Spec(title: "100 % sur le point AF enregistré", group: .display, keys: [.character("a")])
        case .toggleInfo: Spec(title: "Informations", group: .display, keys: [.character("i")])
        case .toggleStrip: Spec(title: "Bande d'aperçu", group: .display, keys: [.character("b")])
        case .exit: Spec(title: "Quitter le zoom ou la comparaison", group: .display, keys: [.code(53)])
        case .compare: Spec(title: "Comparer les photos", group: .comparison, keys: [.character("c")])
        case .keepSelected: Spec(title: "Comparaison : garder la photo choisie", group: .comparison, keys: [.code(36), .code(76)])
        }
    }

    var id: String { rawValue }
    var title: String { spec.title }
    var repeats: Bool { spec.repeats }
    var defaultBindings: [KeyBinding] { spec.keys }

    /// Never given a plain key in the menu: it would also fire while typing in the settings window.
    var isDestructive: Bool { self == .delete || self == .keepSelected }
}

/// One key with its modifiers. Letters are stored as the typed character so they work on any
/// layout (AZERTY included); arrows and other special keys are stored as key codes.
struct KeyBinding: Hashable, Codable, Sendable {
    var keyCode: UInt16?
    var character: String?
    var modifiers: UInt

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    static func code(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> KeyBinding {
        KeyBinding(keyCode: keyCode, character: nil, modifiers: modifiers.rawValue)
    }

    static func character(_ character: String, modifiers: NSEvent.ModifierFlags = []) -> KeyBinding {
        KeyBinding(keyCode: nil, character: character, modifiers: modifiers.rawValue)
    }

    private init(keyCode: UInt16?, character: String?, modifiers: UInt) {
        self.keyCode = keyCode
        self.character = character
        self.modifiers = modifiers
    }

    /// nil for an event that produces no usable key, such as a dead key.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(Self.relevantModifiers)
        if Self.specialKeys[event.keyCode] != nil {
            self = .code(event.keyCode, modifiers: flags)
        } else if let typed = event.charactersIgnoringModifiers?.lowercased(), !typed.isEmpty {
            self = .character(typed, modifiers: flags)
        } else {
            return nil
        }
    }

    private struct SpecialKey: Sendable {
        let label: String
        let menuKey: Int
        init(_ label: String, _ menuKey: Int) {
            self.label = label
            self.menuKey = menuKey
        }
    }

    private static let specialKeys: [UInt16: SpecialKey] = {
        var keys: [UInt16: SpecialKey] = [
            123: SpecialKey("←", NSLeftArrowFunctionKey),
            124: SpecialKey("→", NSRightArrowFunctionKey),
            125: SpecialKey("↓", NSDownArrowFunctionKey),
            126: SpecialKey("↑", NSUpArrowFunctionKey),
            51: SpecialKey("⌫", 0x08),
            117: SpecialKey("⌦", NSDeleteFunctionKey),
            53: SpecialKey("⎋", 0x1B),
            115: SpecialKey("↖", NSHomeFunctionKey),
            119: SpecialKey("↘", NSEndFunctionKey),
            116: SpecialKey("⇞", NSPageUpFunctionKey),
            121: SpecialKey("⇟", NSPageDownFunctionKey),
            36: SpecialKey("↩", 0x0D),
            76: SpecialKey("⌅", 0x03),
            48: SpecialKey("⇥", 0x09),
            49: SpecialKey("Espace", 0x20),
        ]
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (offset, code) in functionKeys.enumerated() {
            keys[code] = SpecialKey("F\(offset + 1)", NSF1FunctionKey + offset)
        }
        return keys
    }()

    var hasModifiers: Bool { modifiers != 0 }

    var label: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        if let keyCode, let special = Self.specialKeys[keyCode] { return text + special.label }
        return text + (character?.uppercased() ?? "?")
    }

    /// What an NSMenuItem needs to show and answer to this key.
    var menuEquivalent: (key: String, modifiers: NSEvent.ModifierFlags)? {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if let keyCode {
            guard let special = Self.specialKeys[keyCode], let scalar = UnicodeScalar(special.menuKey) else { return nil }
            return (String(Character(scalar)), flags)
        }
        return character.map { ($0, flags) }
    }

    /// Keys the app menu keeps for itself: taking them would leave no way to quit or open.
    private static let reserved: Set<KeyBinding> = [
        .character("q", modifiers: .command),
        .character("w", modifiers: .command),
        .character("o", modifiers: .command),
        .character(",", modifiers: .command),
    ]

    var isReserved: Bool { Self.reserved.contains(self) }
}

/// The key assigned to each action. A key belongs to one action at most.
struct ShortcutMap: Equatable, Sendable {
    private(set) var bindings: [ShortcutAction: [KeyBinding]] = [:]
    private var lookup: [KeyBinding: ShortcutAction] = [:]

    static let defaults = ShortcutMap(assigning: Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, $0.defaultBindings) }))

    private init(assigning assignments: [ShortcutAction: [KeyBinding]]) {
        for action in ShortcutAction.allCases {
            for binding in assignments[action] ?? [] where lookup[binding] == nil && !binding.isReserved {
                bindings[action, default: []].append(binding)
                lookup[binding] = action
            }
        }
    }

    func action(for binding: KeyBinding) -> ShortcutAction? { lookup[binding] }

    enum Decision: Equatable {
        /// Not a shortcut: the key goes on to the menu or the responder chain.
        case pass
        /// A shortcut held down whose command must act once per press.
        case swallow
        case perform(ShortcutAction, repeating: Bool)
    }

    /// The whole cost of a key press: one dictionary lookup. Every key path (viewer,
    /// comparison, menu) goes through here, so the repeat rule holds whatever the key.
    func decide(_ binding: KeyBinding?, isRepeat: Bool) -> Decision {
        guard let binding, let action = lookup[binding] else { return .pass }
        if isRepeat, !action.repeats { return .swallow }
        return .perform(action, repeating: isRepeat)
    }

    func isCustomized(_ action: ShortcutAction) -> Bool { keys(for: action) != action.defaultBindings }

    func keys(for action: ShortcutAction) -> [KeyBinding] { bindings[action] ?? [] }

    /// The key shown in the menu. A destructive command only takes a key with a modifier: a
    /// plain key in the menu would also fire while typing in the settings window.
    func menuBinding(for action: ShortcutAction) -> KeyBinding? {
        action.isDestructive ? keys(for: action).first(where: \.hasModifiers) : keys(for: action).first
    }

    /// Assigns the key to `action`, taking it away from any other. Returns that other action.
    @discardableResult
    mutating func assign(_ binding: KeyBinding, to action: ShortcutAction) -> ShortcutAction? {
        guard !binding.isReserved, lookup[binding] != action else { return nil }
        let previous = lookup[binding]
        if let previous { bindings[previous]?.removeAll { $0 == binding } }
        bindings[action, default: []].append(binding)
        lookup[binding] = action
        return previous
    }

    /// Gives `action` its default keys back. A default key another command took stays there;
    /// those keys are returned so the settings can say so.
    @discardableResult
    mutating func reset(_ action: ShortcutAction) -> [(KeyBinding, ShortcutAction)] {
        for binding in keys(for: action) { lookup[binding] = nil }
        bindings[action] = nil
        var kept: [(KeyBinding, ShortcutAction)] = []
        for binding in action.defaultBindings where !binding.isReserved {
            if let owner = lookup[binding] {
                kept.append((binding, owner))
            } else {
                bindings[action, default: []].append(binding)
                lookup[binding] = action
            }
        }
        return kept
    }

    mutating func remove(_ binding: KeyBinding) {
        guard let action = lookup[binding] else { return }
        bindings[action]?.removeAll { $0 == binding }
        lookup[binding] = nil
    }

    // MARK: Storage

    func encoded() -> Data? {
        let stored = Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0.rawValue, keys(for: $0)) })
        return try? JSONEncoder().encode(stored)
    }

    /// Actions missing from the stored data, such as ones added by an update, get their
    /// default keys unless another action already owns them.
    static func decoded(from data: Data?) -> ShortcutMap {
        guard let data, let stored = try? JSONDecoder().decode([String: [KeyBinding]].self, from: data) else { return defaults }
        var assignments: [ShortcutAction: [KeyBinding]] = [:]
        for (name, keys) in stored {
            if let action = ShortcutAction(rawValue: name) { assignments[action] = keys }
        }
        var map = ShortcutMap(assigning: assignments)
        for action in ShortcutAction.allCases where assignments[action] == nil {
            for binding in action.defaultBindings where map.action(for: binding) == nil {
                map.assign(binding, to: action)
            }
        }
        return map
    }
}

/// Holds the user's shortcuts for the settings window, and saves every change.
@MainActor
final class ShortcutStore: ObservableObject {
    private static let defaultsKey = "shortcuts"

    @Published private(set) var map: ShortcutMap
    var onChange: (ShortcutMap) -> Void = { _ in }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        map = ShortcutMap.decoded(from: defaults.data(forKey: Self.defaultsKey))
    }

    @discardableResult
    func assign(_ binding: KeyBinding, to action: ShortcutAction) -> ShortcutAction? {
        let previous = map.assign(binding, to: action)
        saved()
        return previous
    }

    func remove(_ binding: KeyBinding) {
        map.remove(binding)
        saved()
    }

    func reset() {
        map = .defaults
        saved()
    }

    @discardableResult
    func reset(_ action: ShortcutAction) -> [(KeyBinding, ShortcutAction)] {
        let kept = map.reset(action)
        saved()
        return kept
    }

    private func saved() {
        defaults.set(map.encoded(), forKey: Self.defaultsKey)
        onChange(map)
    }
}
