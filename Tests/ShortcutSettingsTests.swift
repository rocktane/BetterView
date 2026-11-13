import AppKit
import XCTest
@testable import BetterView

final class ShortcutDecisionTests: XCTestCase {
    private func event(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], repeat isRepeat: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: isRepeat, keyCode: keyCode)!
    }

    func testDefaultKeysBelongToOneCommandEach() {
        var owners: [KeyBinding: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            for binding in action.defaultBindings {
                XCTAssertNil(owners[binding], "\(binding.label) : \(action) et \(String(describing: owners[binding]))")
                XCTAssertFalse(binding.isReserved, action.rawValue)
                owners[binding] = action
            }
        }
        XCTAssertEqual(Set(ShortcutAction.allCases.map(\.spec.group)), Set(ShortcutAction.Group.allCases), "no empty group")
    }

    func testFirstAndLastAreHomeAndEnd() {
        XCTAssertEqual(ShortcutMap.defaults.decide(.code(115), isRepeat: false), .perform(.first, repeating: false))
        XCTAssertEqual(ShortcutMap.defaults.decide(.code(119), isRepeat: false), .perform(.last, repeating: false))
        // Keys stored by an older build that had them are taken back as they were.
        let stored = try! JSONEncoder().encode(["first": [KeyBinding.code(115)], "delete": [KeyBinding.character("d")]])
        let map = ShortcutMap.decoded(from: stored)
        XCTAssertEqual(map.decide(.code(115), isRepeat: false), .perform(.first, repeating: false))
        XCTAssertEqual(map.decide(.character("d"), isRepeat: false), .perform(.delete, repeating: false))
    }

    func testLettersFollowTheLayout() {
        let map = ShortcutMap.defaults
        // QWERTY: Z is key code 6. AZERTY: the key labelled Z is key code 13.
        XCTAssertEqual(map.decide(KeyBinding(event: event(6, "z")), isRepeat: false), .perform(.toggleZoom, repeating: false))
        XCTAssertEqual(map.decide(KeyBinding(event: event(13, "z")), isRepeat: false), .perform(.toggleZoom, repeating: false))
        XCTAssertEqual(map.decide(KeyBinding(event: event(6, "w")), isRepeat: false), .pass)
        XCTAssertEqual(map.decide(KeyBinding(event: event(13, "z", .command)), isRepeat: false), .perform(.undo, repeating: false))
    }

    /// Holding a key acts once, whatever key a command is given, except for navigation.
    func testHoldingAKeyActsOnceExceptForNavigation() {
        let map = ShortcutMap.defaults
        for action in ShortcutAction.allCases {
            for binding in map.keys(for: action) {
                let decision = map.decide(binding, isRepeat: true)
                XCTAssertEqual(decision, action.repeats ? .perform(action, repeating: true) : .swallow, "\(action) \(binding.label)")
            }
        }
        XCTAssertEqual(Set(ShortcutAction.allCases.filter(\.repeats)), [.next, .previous, .jumpForward, .jumpBackward, .extendNext, .extendPrevious, .zoomIn, .zoomOut])
    }

    func testDeleteActsOnceWhateverKeyItIsGiven() {
        var map = ShortcutMap.defaults
        for binding: KeyBinding in [.character("a"), .code(49), .code(124), .character("d", modifiers: .command)] {
            map.assign(binding, to: .delete)
            XCTAssertEqual(map.decide(binding, isRepeat: false), .perform(.delete, repeating: false))
            XCTAssertEqual(map.decide(binding, isRepeat: true), .swallow, binding.label)
        }
    }

    func testResetOneCommand() {
        var map = ShortcutMap.defaults
        map.assign(.character("x"), to: .toggleInfo)
        map.remove(.code(51))
        XCTAssertTrue(map.isCustomized(.delete))
        // X now belongs to Informations: resetting Corbeille leaves it there and says so.
        let kept = map.reset(.delete)
        XCTAssertEqual(kept.map(\.0), [.character("x")])
        XCTAssertEqual(kept.map(\.1), [.toggleInfo])
        XCTAssertEqual(map.decide(.code(51), isRepeat: false), .perform(.delete, repeating: false))
        XCTAssertEqual(map.decide(.character("x"), isRepeat: false), .perform(.toggleInfo, repeating: false))
        map.reset(.toggleInfo)
        map.reset(.delete)
        XCTAssertEqual(map, .defaults)
        XCTAssertFalse(ShortcutAction.allCases.contains { map.isCustomized($0) })
    }

    func testResolutionCost() {
        let map = ShortcutMap.defaults
        let arrow = event(124, "\u{F703}", [.function, .numericPad])
        let letter = event(13, "z")
        let count = 100_000
        var performed = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<count {
            if case .perform = map.decide(KeyBinding(event: index & 1 == 0 ? arrow : letter), isRepeat: false) { performed += 1 }
        }
        let perPress = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(count)
        XCTAssertEqual(performed, count)
        XCTAssertLessThan(perPress, 20_000)
        print("Résolution d'une touche : \(Int(perPress)) ns")
    }
}

@MainActor
final class KeyRecorderTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var settings: NSWindow!
    private var viewer: NSWindow!

    override func setUp() async throws {
        suite = "betterview.recorder.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        viewer = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        viewer.isReleasedWhenClosed = false
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func key(_ characters: String, _ keyCode: UInt16, in window: NSWindow, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: keyCode)!
    }

    func testRecordsOnlyKeysTypedInTheSettingsWindow() {
        let store = ShortcutStore(defaults: defaults)
        let recorder = KeyRecorder(store: store)
        recorder.start(.delete, in: settings)
        NSApp.sendEvent(key("a", 0, in: viewer))
        XCTAssertNil(recorder.target)
        XCTAssertFalse(recorder.isListening)
        XCTAssertEqual(store.map, .defaults)

        recorder.start(.delete, in: settings)
        NSApp.sendEvent(key("g", 5, in: settings))
        XCTAssertNil(recorder.target)
        XCTAssertEqual(store.map.action(for: .character("g")), .delete)
    }

    func testConflictWaitsForAnAnswer() {
        let store = ShortcutStore(defaults: defaults)
        let recorder = KeyRecorder(store: store)
        recorder.start(.delete, in: settings)
        NSApp.sendEvent(key("z", 6, in: settings))
        XCTAssertEqual(recorder.conflict?.owner, .toggleZoom)
        XCTAssertFalse(recorder.isCapturing)
        NSApp.sendEvent(key("q", 12, in: settings))
        XCTAssertEqual(recorder.conflict?.owner, .toggleZoom, "other keys wait for the answer")
        XCTAssertEqual(store.map, .defaults, "nothing moves before Remplacer")
        recorder.replace()
        XCTAssertEqual(store.map.action(for: .character("z")), .delete)
        XCTAssertTrue(store.map.keys(for: .toggleZoom).isEmpty)
        XCTAssertFalse(recorder.isListening)
    }

    func testAPendingConflictEndsWithEscapeOrAnotherWindow() {
        let store = ShortcutStore(defaults: defaults)
        let recorder = KeyRecorder(store: store)
        recorder.start(.delete, in: settings)
        NSApp.sendEvent(key("z", 6, in: settings))
        NSApp.sendEvent(key("\u{1B}", 53, in: settings))
        XCTAssertNil(recorder.conflict)
        XCTAssertNil(recorder.target)
        XCTAssertFalse(recorder.isListening)

        recorder.start(.delete, in: settings)
        NSApp.sendEvent(key("z", 6, in: settings))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: settings)
        XCTAssertNil(recorder.conflict)
        XCTAssertFalse(recorder.isListening)

        recorder.start(.delete, in: settings)
        NSApp.sendEvent(key("z", 6, in: settings))
        NSApp.sendEvent(key("a", 0, in: viewer))
        XCTAssertNil(recorder.conflict)
        XCTAssertEqual(store.map, .defaults)
    }

    func testReplacingAKeyAndEscape() {
        let store = ShortcutStore(defaults: defaults)
        let recorder = KeyRecorder(store: store)
        recorder.start(.delete, replacing: .character("x"), in: settings)
        NSApp.sendEvent(key("d", 2, in: settings))
        XCTAssertEqual(store.map.action(for: .character("d")), .delete)
        XCTAssertNil(store.map.action(for: .character("x")))

        recorder.start(.toggleInfo, in: settings)
        NSApp.sendEvent(key("\u{1B}", 53, in: settings))
        XCTAssertNil(recorder.target)
        XCTAssertEqual(store.map.keys(for: .toggleInfo), [.character("i")])
    }

    func testLeavingTheSettingsWindowEndsTheCapture() {
        let recorder = KeyRecorder(store: ShortcutStore(defaults: defaults))
        recorder.start(.toggleInfo, in: settings)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: settings)
        XCTAssertNil(recorder.target)
        XCTAssertFalse(recorder.isListening)
    }
}
