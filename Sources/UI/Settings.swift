import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Preferences {
    private static let diskCacheKey = "diskCacheGigabytes"
    fileprivate static let handlersKey = "previousHandlers"
    fileprivate static let infoVisibleKey = "infoVisible"
    fileprivate static let deleteFollowsDirectionKey = "deleteFollowsDirection"
    fileprivate static let stripVisibleKey = "stripVisible"
    private static let stripPlacementKey = "stripPlacement"

    static var diskCacheGigabytes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: diskCacheKey)
            return value > 0 ? value : 2
        }
        set { UserDefaults.standard.set(newValue, forKey: diskCacheKey) }
    }

    static var diskCacheBytes: Int { diskCacheGigabytes * 1_000_000_000 }

    static var infoVisible: Bool {
        get { UserDefaults.standard.object(forKey: infoVisibleKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: infoVisibleKey) }
    }

    static var deleteFollowsDirection: Bool { UserDefaults.standard.bool(forKey: deleteFollowsDirectionKey) }

    static var stripVisible: Bool {
        get { UserDefaults.standard.object(forKey: stripVisibleKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: stripVisibleKey) }
    }

    /// nil until the user first moves the strip.
    static var stripPlacement: StripPlacement? {
        get {
            UserDefaults.standard.data(forKey: stripPlacementKey).flatMap { try? JSONDecoder().decode(StripPlacement.self, from: $0) }
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: stripPlacementKey) }
    }
}

/// Default-app state per format. The state shown is always read back from the system.
@MainActor
final class FileAssociations: ObservableObject {
    @Published private(set) var handlers: [String: String] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published var lastError: String?

    private let selfID = Bundle.main.bundleIdentifier ?? "com.yohan.betterview"

    init() { refresh() }

    func refresh() {
        for format in RawFormat.all {
            guard let type = UTType(format.uti) else { continue }
            let url = NSWorkspace.shared.urlForApplication(toOpen: type)
            handlers[format.uti] = url.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? ""
        }
    }

    func isEnabled(_ format: RawFormat) -> Bool { handlers[format.uti] == selfID }

    func appName(_ format: RawFormat) -> String {
        guard let id = handlers[format.uti], !id.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return "aucune" }
        return FileManager.default.displayName(atPath: url.path)
    }

    func setEnabled(_ format: RawFormat, _ enabled: Bool) {
        guard !busy.contains(format.uti), let type = UTType(format.uti) else { return }
        let effective = handlers[format.uti] ?? ""
        var saved = UserDefaults.standard.dictionary(forKey: Preferences.handlersKey) as? [String: String] ?? [:]
        let appURL: URL
        if enabled {
            if effective != selfID, !effective.isEmpty {
                saved[format.uti] = effective
                UserDefaults.standard.set(saved, forKey: Preferences.handlersKey)
            }
            appURL = Bundle.main.bundleURL
        } else {
            let available = saved[format.uti].map { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } ?? false
            guard let previous = Self.restoreTarget(effective: effective, me: selfID, saved: saved[format.uti], available: available),
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: previous)
            else {
                lastError = "Aucune app précédente à rétablir pour \(format.fileExtension.uppercased()) : choisis-en une avec « Lire les informations » dans le Finder."
                refresh()
                return
            }
            appURL = url
        }
        busy.insert(format.uti)
        NSWorkspace.shared.setDefaultApplication(at: appURL, toOpen: type) { [weak self] error in
            let message = error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy.remove(format.uti)
                    if let message { self.lastError = message }
                    self.refresh()
                }
            }
        }
    }

    /// The saved app comes back only while BetterView is still the effective default: if
    /// the user chose another app since, that choice wins.
    nonisolated static func restoreTarget(effective: String, me: String, saved: String?, available: Bool) -> String? {
        guard effective == me, let saved, available else { return nil }
        return saved
    }
}

/// Waits for one key press for the settings window, ahead of the menus: a key already used
/// by a menu can be chosen too.
@MainActor
final class KeyRecorder: ObservableObject {
    @Published private(set) var action: ShortcutAction?
    private var monitor: Any?

    func start(_ action: ShortcutAction, onKey: @escaping (KeyBinding) -> Void) {
        stop()
        self.action = action
        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let binding = KeyBinding(event: event)
            // In another window, this key was meant for something else.
            let elsewhere = event.window !== window
            MainActor.assumeIsolated {
                guard let self else { return }
                if elsewhere {
                    self.stop()
                } else if let binding {
                    self.stop()
                    onKey(binding)
                }
            }
            return elsewhere ? event : nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        action = nil
    }
}

struct SettingsView: View {
    @StateObject private var associations = FileAssociations()
    @StateObject private var recorder = KeyRecorder()
    @ObservedObject var shortcuts: ShortcutStore
    @State private var cacheGigabytes = Preferences.diskCacheGigabytes
    @State private var shortcutNotice: String?
    @AppStorage(Preferences.deleteFollowsDirectionKey) private var deleteFollowsDirection = false
    @AppStorage(Preferences.infoVisibleKey) private var infoVisible = true
    @AppStorage(Preferences.stripVisibleKey) private var stripVisible = true
    let onInfoVisibleChange: (Bool) -> Void
    let onStripVisibleChange: (Bool) -> Void
    let onCacheSizeChange: (Int) -> Void
    let onClearCache: () -> Void

    var body: some View {
        Form {
            Section("Affichage") {
                Toggle("Afficher les informations sur la photo", isOn: $infoVisible)
                    .onChange(of: infoVisible) { _, value in onInfoVisibleChange(value) }
                Toggle("Afficher la bande d'aperçu", isOn: $stripVisible)
                    .onChange(of: stripVisible) { _, value in onStripVisibleChange(value) }
                Toggle("Après une suppression, garder le sens de navigation", isOn: $deleteFollowsDirection)
            }
            Section {
                ForEach(ShortcutAction.allCases) { shortcutRow($0) }
                Button("Rétablir les raccourcis par défaut") {
                    recorder.stop()
                    shortcutNotice = nil
                    shortcuts.reset()
                }
            } header: {
                Text("Raccourcis")
            } footer: {
                if let shortcutNotice {
                    Text(shortcutNotice).foregroundStyle(.secondary)
                }
            }
            Section("Ouvrir par défaut avec BetterView") {
                ForEach(RawFormat.all) { format in
                    Toggle(isOn: Binding(
                        get: { associations.isEnabled(format) },
                        set: { associations.setEnabled(format, $0) }
                    )) {
                        HStack {
                            Text(".\(format.fileExtension.uppercased())").monospaced()
                            Text(format.brand).foregroundStyle(.secondary)
                            Spacer()
                            if !associations.isEnabled(format) {
                                Text(associations.appName(format)).foregroundStyle(.tertiary).font(.caption)
                            }
                        }
                    }
                    .disabled(associations.busy.contains(format.uti))
                }
            }
            Section("Cache disque") {
                Picker("Taille maximale", selection: $cacheGigabytes) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) Go").tag($0) }
                }
                .onChange(of: cacheGigabytes) { _, value in
                    Preferences.diskCacheGigabytes = value
                    onCacheSizeChange(value)
                }
                Button("Vider le cache", action: onClearCache)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 720)
        .onAppear { associations.refresh() }
        .onDisappear { recorder.stop() }
        .alert("Réglage non appliqué", isPresented: Binding(
            get: { associations.lastError != nil },
            set: { if !$0 { associations.lastError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(associations.lastError ?? "")
        }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        HStack(spacing: 6) {
            Text(action.title)
            Spacer()
            ForEach(shortcuts.map.keys(for: action), id: \.self) { binding in
                HStack(spacing: 3) {
                    Text(binding.label).monospaced()
                    Button {
                        shortcutNotice = nil
                        shortcuts.remove(binding)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Retirer ce raccourci")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            }
            if recorder.action == action {
                Button("Touche…") { recorder.stop() }
                    .help("Appuie sur la touche voulue, ou clique ici pour annuler")
            } else {
                Button {
                    shortcutNotice = nil
                    recorder.start(action) { record($0, for: action) }
                } label: {
                    Image(systemName: "plus")
                }
                .help("Ajouter un raccourci")
            }
        }
    }

    private func record(_ binding: KeyBinding, for action: ShortcutAction) {
        if binding.isReserved {
            shortcutNotice = "\(binding.label) est réservé par le menu de l'app."
        } else if let previous = shortcuts.assign(binding, to: action) {
            shortcutNotice = "\(binding.label) a été retiré de « \(previous.title) »."
        }
    }
}
