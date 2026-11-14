import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var viewer: ViewerController!
    private var settingsWindow: NSWindow?
    private var historyWindow: HistoryWindowController?
    private let shortcuts = ShortcutStore()
    private var shortcutItems: [(action: ShortcutAction, item: NSMenuItem)] = []
    private var terminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Runs alongside the first preview: no photo depends on the other finishing first.
        Decoders.warmUp()
        // The benchmark deletes clones into a fake Trash: they stay out of the real history.
        let journal = Benchmark.diskDirectory == nil ? DeletionJournal(url: DeletionJournal.defaultURL) : nil
        viewer = ViewerController(
            session: LibrarySession(journal: journal),
            diskDirectory: Benchmark.diskDirectory ?? DiskCache.defaultDirectory
        )
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
        viewer.showOpenPanel()
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

    @objc private func showHistory(_ sender: Any?) {
        if historyWindow == nil {
            let session = viewer.session
            historyWindow = HistoryWindowController(session: session) {
                session.folderPath ?? Self.lastOpenedFolder()
            }
        }
        historyWindow?.show()
    }

    /// The folder of the most recent item in Open Recent, without touching the disk: a RAW is
    /// a file, anything else was opened as a folder.
    private static func lastOpenedFolder() -> String? {
        guard let url = NSDocumentController.shared.recentDocumentURLs.first else { return nil }
        let isPhoto = RawFormat.extensions.contains(url.pathExtension.lowercased())
        return (isPhoto ? url.deletingLastPathComponent() : url).standardizedFileURL.path
    }

    @objc private func performShortcut(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let action = ShortcutAction(rawValue: name) else { return }
        // By key, the same decision as the viewer's: a held key acts once unless the command
        // is navigation. By click, the command simply runs.
        guard let event = NSApp.currentEvent, event.type == .keyDown else {
            viewer.perform(action)
            return
        }
        switch shortcuts.map.decide(KeyBinding(event: event), isRepeat: event.isARepeat) {
        case .perform(let decided, let repeating) where decided == action:
            viewer.perform(action, repeating: repeating)
        case .swallow:
            return
        default:
            // The menu matched a key the map resolves differently: apply the rule to the item.
            if action.repeats || !event.isARepeat { viewer.perform(action, repeating: event.isARepeat) }
        }
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
            item("Suppressions du dossier…", #selector(showHistory), "y"),
        ])
        submenu("Présentation", [
            action(.next),
            action(.previous),
            action(.jumpForward),
            action(.jumpBackward),
            action(.first),
            action(.last),
            .separator(),
            action(.extendNext),
            action(.extendPrevious),
            action(.toggleSelection),
            .separator(),
            action(.toggleZoom),
            action(.zoomToFocus),
            action(.zoomIn),
            action(.zoomOut),
            action(.zoomFit),
            action(.toggleInfo),
            action(.toggleStrip),
            .separator(),
            action(.compare),
        ])
        return main
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Photo commands need the viewer in front: a key typed in the settings window never
    /// reaches a photo, even one that is also a menu key.
    /// Annuler la suppression stays available everywhere: it only puts a photo back, and the
    /// history window is where one looks for it.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(performShortcut(_:)),
              let name = item.representedObject as? String, let action = ShortcutAction(rawValue: name)
        else { return true }
        // A toggle shows its state, as in any Mac app.
        if action == .toggleInfo { item.state = viewer.isInfoVisible ? .on : .off }
        return action == .undo || (viewer.window.isKeyWindow && viewer.isAvailable(action))
    }
}
