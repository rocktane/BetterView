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
        let disk = viewer.pipeline.disk
        let viewer = viewer!
        let root = SettingsView(
            shortcuts: shortcuts,
            onInfoVisibleChange: { viewer.setInfoVisible($0) },
            onStripVisibleChange: { viewer.setStripVisible($0) },
            onCacheSizeChange: { disk.setBudget($0 * 1_000_000_000) },
            onClearCache: { disk.clear() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Réglages"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    @objc private func performShortcut(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let action = ShortcutAction(rawValue: name) else { return }
        if action.repeats || NSApp.currentEvent?.isARepeat != true { viewer.perform(action) }
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
            action(.first),
            action(.last),
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
