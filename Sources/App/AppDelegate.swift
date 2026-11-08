import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var viewer: ViewerController!
    private var settingsWindow: NSWindow?
    private let shortcuts = ShortcutStore()
    private var shortcutItems: [(action: ShortcutAction, item: NSMenuItem)] = []
    private var terminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Runs alongside the first preview: no photo depends on the other finishing first.
        Decoders.warmUp()
        viewer = ViewerController(diskDirectory: Benchmark.diskDirectory ?? DiskCache.defaultDirectory)
        NSApp.mainMenu = buildMenu()
        applyShortcuts(shortcuts.map)
        shortcuts.onChange = { [weak self] in self?.applyShortcuts($0) }
        viewer.session.onDrained = { [weak self] in
            guard let self, self.terminating else { return }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewer.showWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        viewer.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting waits for queued deletions so an accepted delete always happens.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard viewer.session.hasPendingIO else { return .terminateNow }
        terminating = true
        return .terminateLater
    }

    // MARK: Menu actions

    @objc private func openPanel(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = RawFormat.all.compactMap { UTType($0.uti) } + [.folder]
        panel.beginSheetModal(for: viewer.window) { [weak self] response in
            MainActor.assumeIsolated {
                if response == .OK { self?.viewer.open(panel.urls) }
            }
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = SettingsWindow.make(shortcuts: shortcuts, disk: viewer.pipeline.disk, viewer: viewer)
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    @objc private func performShortcut(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let action = ShortcutAction(rawValue: name) else { return }
        // Same rule as the keyboard: a held key acts once unless the command is navigation.
        let event = NSApp.currentEvent
        let isRepeat = event?.type == .keyDown && event?.isARepeat == true
        if action.repeats || !isRepeat { viewer.perform(action, repeating: isRepeat) }
    }

    /// The view and the menu always answer to the keys chosen in the settings.
    private func applyShortcuts(_ map: ShortcutMap) {
        viewer.setShortcuts(map)
        for (action, item) in shortcutItems {
            let equivalent = map.menuBinding(for: action)?.menuEquivalent
            item.keyEquivalent = equivalent?.key ?? ""
            item.keyEquivalentModifierMask = equivalent?.modifiers ?? []
        }
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let main = NSMenu()

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.target = self
            return entry
        }
        func action(_ action: ShortcutAction, title: String? = nil) -> NSMenuItem {
            let entry = NSMenuItem(title: title ?? action.title, action: #selector(performShortcut), keyEquivalent: "")
            entry.target = self
            entry.representedObject = action.rawValue
            shortcutItems.append((action, entry))
            return entry
        }

        let quit = NSMenuItem(title: "Quitter BetterView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        submenu("BetterView", [
            item("Réglages…", #selector(showSettings), ","),
            .separator(),
            quit,
        ])
        submenu("Fichier", [
            item("Ouvrir…", #selector(openPanel), "o"),
            action(.delete),
            action(.revealInFinder),
            .separator(),
            NSMenuItem(title: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ])
        submenu("Édition", [
            action(.undo),
        ])
        submenu("Présentation", [
            action(.next),
            action(.previous),
            action(.jumpForward),
            action(.jumpBackward),
            .separator(),
            action(.toggleZoom),
            action(.zoomToFocus),
            action(.toggleInfo),
            action(.toggleStrip),
            .separator(),
            action(.compare),
            action(.keepSelected),
        ])
        return main
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Photo commands need the viewer in front: a key typed in the settings window never
    /// reaches a photo, even one that is also a menu key.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(performShortcut(_:)) else { return true }
        return viewer.window.isKeyWindow
    }
}
