import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var viewer: ViewerController!
    private var settingsWindow: NSWindow?
    private var terminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Runs alongside the first preview: no photo depends on the other finishing first.
        Decoders.warmUp()
        viewer = ViewerController(diskDirectory: Benchmark.diskDirectory ?? DiskCache.defaultDirectory)
        NSApp.mainMenu = buildMenu()
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
        let root = SettingsView(
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

    @objc private func undo(_ sender: Any?) { viewer.undo() }
    @objc private func deleteCurrent(_ sender: Any?) {
        if NSApp.currentEvent?.isARepeat != true { viewer.deleteCurrent() }
    }
    @objc private func next(_ sender: Any?) { viewer.step(1) }
    @objc private func previous(_ sender: Any?) { viewer.step(-1) }
    @objc private func zoom(_ sender: Any?) { viewer.toggleZoom() }
    @objc private func zoomToFocus(_ sender: Any?) { viewer.zoomToFocus() }
    @objc private func fullScreen(_ sender: Any?) { viewer.window.toggleFullScreen(nil) }

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

        let quit = NSMenuItem(title: "Quitter BetterView", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        submenu("BetterView", [
            item("Réglages…", #selector(showSettings), ","),
            .separator(),
            quit,
        ])
        submenu("Fichier", [
            item("Ouvrir…", #selector(openPanel), "o"),
            item("Mettre à la corbeille", #selector(deleteCurrent), "\u{8}"),
            .separator(),
            NSMenuItem(title: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ])
        submenu("Édition", [
            item("Annuler la suppression", #selector(undo), "z"),
        ])
        submenu("Présentation", [
            item("Suivante", #selector(next), String(UnicodeScalar(NSRightArrowFunctionKey)!), []),
            item("Précédente", #selector(previous), String(UnicodeScalar(NSLeftArrowFunctionKey)!), []),
            .separator(),
            item("100 % / Ajusté", #selector(zoom), "z", []),
            item("100 % sur le point AF enregistré", #selector(zoomToFocus), "a", []),
            item("Plein écran", #selector(fullScreen), "f", []),
        ])
        return main
    }
}
