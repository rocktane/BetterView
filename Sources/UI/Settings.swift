import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Preferences {
    private static let diskCacheKey = "diskCacheGigabytes"
    fileprivate static let handlersKey = "previousHandlers"

    static var diskCacheGigabytes: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: diskCacheKey)
            return value > 0 ? value : 2
        }
        set { UserDefaults.standard.set(newValue, forKey: diskCacheKey) }
    }

    static var diskCacheBytes: Int { diskCacheGigabytes * 1_000_000_000 }
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

struct SettingsView: View {
    @StateObject private var associations = FileAssociations()
    @State private var cacheGigabytes = Preferences.diskCacheGigabytes
    let onCacheSizeChange: (Int) -> Void
    let onClearCache: () -> Void

    var body: some View {
        Form {
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
            Section("Raccourcis") {
                shortcut("← →", "Précédente, suivante")
                shortcut("⌫ ou X", "Mettre à la corbeille")
                shortcut("⌘Z", "Annuler la suppression")
                shortcut("Z, double-clic", "100 % ou ajusté")
                shortcut("F", "Plein écran")
                shortcut("I", "Informations")
                shortcut("↖ ↘", "Première, dernière")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 680)
        .onAppear { associations.refresh() }
        .alert("Réglage non appliqué", isPresented: Binding(
            get: { associations.lastError != nil },
            set: { if !$0 { associations.lastError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(associations.lastError ?? "")
        }
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        HStack {
            Text(action)
            Spacer()
            Text(keys).foregroundStyle(.secondary).monospaced()
        }
    }
}
