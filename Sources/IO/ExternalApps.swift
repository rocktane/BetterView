import AppKit

/// The other apps photos can be sent to: Lightroom first, then whatever opens the file.
@MainActor
enum ExternalApps {
    struct App: Equatable {
        let url: URL
        let name: String
        let bundleIdentifier: String?

        /// Lightroom Classic works from a catalog: it shows its import window with the files.
        var importsFirst: Bool { bundleIdentifier == ExternalApps.lightroomClassic }

        /// Any Lightroom, wherever it is installed: sending photos to one is always confirmed.
        var isLightroom: Bool { bundleIdentifier.map(ExternalApps.lightroomIdentifiers.contains) ?? false }
    }

    enum OpenFailure: Equatable, Sendable {
        /// A file is no longer the revision the user saw: nothing was sent.
        case changed
        case refused(String)
    }

    nonisolated static let lightroomClassic = "com.adobe.LightroomClassicCC7"
    /// Classic first: it is the one that sorts and develops a folder of RAW files.
    nonisolated static let lightroomIdentifiers = [lightroomClassic, "com.adobe.lightroomCC"]

    static func lightroom() -> App? {
        lightroomIdentifiers.lazy
            .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first.map { app(at: $0) }
    }

    /// The apps that open this file, the default one first, without BetterView itself.
    static func apps(opening file: URL) -> [App] {
        let own = Bundle.main.bundleURL.standardizedFileURL
        var seen: Set<URL> = [own]
        let preferred = NSWorkspace.shared.urlForApplication(toOpen: file)
        let all = (preferred.map { [$0] } ?? []) + NSWorkspace.shared.urlsForApplications(toOpen: file)
        return all.filter { seen.insert($0.standardizedFileURL).inserted }
            .map { app(at: $0) }
            .sorted { a, b in
                if a.url == preferred { return true }
                if b.url == preferred { return false }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }

    static func app(at url: URL) -> App {
        let bundle = Bundle(url: url)
        var name = FileManager.default.displayName(atPath: url.path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        return App(url: url, name: name, bundleIdentifier: bundle?.bundleIdentifier)
    }

    static func icon(of app: App) -> NSImage {
        let image = NSWorkspace.shared.icon(forFile: app.url.path)
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// Sends the photos only if every file is still the revision the user saw and confirmed:
    /// a file replaced meanwhile, at the same path, is not what they chose. The check reads
    /// the disk, so it runs off the main thread.
    static func open(_ photos: [PhotoKey], with app: App, failed: @escaping @MainActor (OpenFailure) -> Void) {
        let appURL = app.url
        DispatchQueue.global(qos: .userInitiated).async {
            guard photos.allSatisfy({ PhotoKey.read(path: $0.path) == $0 }) else {
                Task { @MainActor in failed(.changed) }
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(photos.map(\.url), withApplicationAt: appURL, configuration: configuration) { _, error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor in failed(.refused(message)) }
            }
        }
    }
}

/// A menu item that runs a closure: context menus are built for one click and thrown away.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, image: NSImage? = nil, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.image = image
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
