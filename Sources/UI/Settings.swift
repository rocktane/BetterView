import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Preferences {
    private static let diskCacheKey = "diskCacheGigabytes"
    fileprivate static let handlersKey = "previousHandlers"
    static let infoVisibleKey = "infoVisible"
    static let deleteFollowsDirectionKey = "deleteFollowsDirection"
    static let stripVisibleKey = "stripVisible"
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

// MARK: - Default apps

/// Default-app state per format. The state shown is always read back from the system.
@MainActor
final class FileAssociations: ObservableObject {
    @Published private(set) var handlers: [String: String] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published var lastError: String?

    private let selfID = Bundle.main.bundleIdentifier ?? "com.yohan.betterview"
    /// Formats still to change in a “all formats” request, one system call at a time.
    private var queued: [RawFormat] = []
    private var queuedErrors: [String] = []
    private var missingPrevious: [String] = []

    init() { refresh() }

    func refresh() {
        for format in RawFormat.all {
            guard let type = UTType(format.uti) else { continue }
            let url = NSWorkspace.shared.urlForApplication(toOpen: type)
            handlers[format.uti] = url.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? ""
        }
    }

    func isEnabled(_ format: RawFormat) -> Bool { handlers[format.uti] == selfID }

    var enabledCount: Int { RawFormat.all.filter(isEnabled).count }
    var isWorking: Bool { !busy.isEmpty || !queued.isEmpty }

    func appName(_ format: RawFormat) -> String {
        guard let id = handlers[format.uti], !id.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        else { return "aucune app" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// One line under the global switch, read from the system like the rest.
    var summary: String {
        let total = RawFormat.all.count
        let others = RawFormat.all.filter { !isEnabled($0) }
        switch others.count {
        case 0: return "Les \(total) formats s'ouvrent avec BetterView."
        case total: return "Aucun format ne s'ouvre avec BetterView."
        case 1, 2:
            let detail = others.map { "\($0.fileExtension.uppercased()) s'ouvre avec \(appName($0))" }.joined(separator: ", ")
            return "\(total - others.count) formats sur \(total). \(detail)."
        default:
            return "\(total - others.count) formats sur \(total)."
        }
    }

    func setEnabled(_ format: RawFormat, _ enabled: Bool) {
        guard !isWorking else { return }
        missingPrevious = []
        queuedErrors = []
        queued = [format]
        applyNext(enabled)
    }

    /// Changes every format that differs, sequentially, so the system never sees two
    /// requests at once and errors come back as a single alert.
    func setAll(_ enabled: Bool) {
        guard !isWorking else { return }
        missingPrevious = []
        queuedErrors = []
        queued = RawFormat.all.filter { isEnabled($0) != enabled }
        applyNext(enabled)
    }

    private func applyNext(_ enabled: Bool) {
        guard !queued.isEmpty else {
            finishBatch()
            return
        }
        let format = queued.removeFirst()
        guard let type = UTType(format.uti) else { return applyNext(enabled) }
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
                missingPrevious.append(format.fileExtension.uppercased())
                return applyNext(enabled)
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
                    if let message { self.queuedErrors.append("\(format.fileExtension.uppercased()) : \(message)") }
                    self.refresh()
                    self.applyNext(enabled)
                }
            }
        }
    }

    private func finishBatch() {
        refresh()
        var lines = queuedErrors
        if !missingPrevious.isEmpty {
            lines.append("Aucune app précédente à rétablir pour \(missingPrevious.joined(separator: ", ")) : choisis-en une avec « Lire les informations » dans le Finder.")
        }
        if !lines.isEmpty { lastError = lines.joined(separator: "\n") }
        queuedErrors = []
        missingPrevious = []
    }

    /// The saved app comes back only while BetterView is still the effective default: if
    /// the user chose another app since, that choice wins.
    nonisolated static func restoreTarget(effective: String, me: String, saved: String?, available: Bool) -> String? {
        guard effective == me, let saved, available else { return nil }
        return saved
    }
}

// MARK: - Disk cache

@MainActor
final class CacheSettings: ObservableObject {
    @Published var gigabytes = Preferences.diskCacheGigabytes {
        didSet {
            guard gigabytes != oldValue else { return }
            Preferences.diskCacheGigabytes = gigabytes
            disk?.setBudget(gigabytes * 1_000_000_000)
            refresh()
        }
    }
    @Published private(set) var usage: String = "…"
    private weak var disk: DiskCache?

    init(disk: DiskCache?) {
        self.disk = disk
        refresh()
    }

    func refresh() {
        disk?.measureUsage { [weak self] bytes, files in
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            self?.usage = files == 0 ? "Vide" : "\(size) · \(files.formatted()) rendus"
        }
    }

    func clear() {
        disk?.clear()
        refresh()
    }
}

// MARK: - Général

struct GeneralSettingsView: View {
    @ObservedObject var associations: FileAssociations
    @ObservedObject var cache: CacheSettings
    @AppStorage("settingsShowsFormats") private var showsFormats = false
    @AppStorage(Preferences.deleteFollowsDirectionKey) private var deleteFollowsDirection = false
    @AppStorage(Preferences.infoVisibleKey) private var infoVisible = true
    @AppStorage(Preferences.stripVisibleKey) private var stripVisible = true
    @State private var confirmsClear = false
    let onInfoVisibleChange: (Bool) -> Void
    let onStripVisibleChange: (Bool) -> Void

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
                Toggle(isOn: Binding(
                    get: { associations.enabledCount == RawFormat.all.count },
                    set: { associations.setAll($0) }
                )) {
                    Text("Ouvrir les RAW avec BetterView")
                    Text(associations.summary)
                }
                .disabled(associations.isWorking)
                DisclosureGroup("Détail par format", isExpanded: $showsFormats) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: 4), alignment: .leading, spacing: 8) {
                        ForEach(RawFormat.all) { format in
                            formatToggle(format)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Formats RAW")
            } footer: {
                Text("État relu dans macOS à chaque ouverture. Décocher un format rend l'app qui l'ouvrait avant, si elle existe encore.")
                    .settingsFooter()
            }

            Section {
                Picker("Taille maximale", selection: $cache.gigabytes) {
                    ForEach([1, 2, 5, 10], id: \.self) { Text("\($0) Go").tag($0) }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Utilisé")
                        Text(cache.usage).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Vider le cache…") { confirmsClear = true }
                }
            } header: {
                Text("Cache disque")
            } footer: {
                Text("Rendus RAW déjà calculés, pour rouvrir un dossier sans attendre. Vider le cache ne touche pas aux photos.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            associations.refresh()
            cache.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            associations.refresh()
        }
        .confirmationDialog("Vider le cache disque ?", isPresented: $confirmsClear) {
            Button("Vider le cache", role: .destructive) { cache.clear() }
        } message: {
            Text("Les rendus seront recalculés à la demande. Les photos ne sont pas touchées.")
        }
        .alert("Réglage non appliqué", isPresented: Binding(
            get: { associations.lastError != nil },
            set: { if !$0 { associations.lastError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(associations.lastError ?? "")
        }
    }

    private func formatToggle(_ format: RawFormat) -> some View {
        let enabled = associations.isEnabled(format)
        return Toggle(isOn: Binding(
            get: { enabled },
            set: { associations.setEnabled(format, $0) }
        )) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(format.fileExtension.uppercased()).monospaced()
                    Text(format.brand).foregroundStyle(.secondary)
                }
                if !enabled {
                    Text(associations.appName(format))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(associations.isWorking)
        .help(enabled ? "\(format.brand) \(format.fileExtension.uppercased()) s'ouvre avec BetterView"
                      : "\(format.brand) \(format.fileExtension.uppercased()) s'ouvre avec \(associations.appName(format))")
    }
}

// MARK: - Raccourcis

/// Waits for one key press for the settings window, ahead of the menus: a key already used by
/// a menu can be chosen too. Keys typed in another window are left alone and end the capture,
/// as does the settings window losing the keyboard.
@MainActor
final class KeyRecorder: ObservableObject {
    struct Target: Equatable {
        let action: ShortcutAction
        /// The key being changed, or nil when adding one.
        let replacing: KeyBinding?
    }

    struct Conflict: Equatable {
        let target: Target
        let binding: KeyBinding
        let owner: ShortcutAction
    }

    @Published private(set) var target: Target?
    @Published private(set) var conflict: Conflict?
    @Published private(set) var notice: (action: ShortcutAction, text: String)?
    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private weak var window: NSWindow?
    private let store: ShortcutStore

    init(store: ShortcutStore) { self.store = store }

    var isListening: Bool { monitor != nil }

    /// `window` is the settings window, the only one whose keys are recorded.
    func start(_ action: ShortcutAction, replacing: KeyBinding? = nil, in window: NSWindow? = NSApp.keyWindow) {
        stopListening()
        conflict = nil
        notice = nil
        target = Target(action: action, replacing: replacing)
        self.window = window
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let recorded = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, event.window === window else {
                    self?.cancel()
                    return false
                }
                self.record(event)
                return true
            }
            return recorded ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
    }

    func cancel() {
        stopListening()
        target = nil
        conflict = nil
    }

    /// Takes the key from the command that had it.
    func replace() {
        guard let conflict else { return }
        apply(conflict.binding, conflict.target)
        self.conflict = nil
        target = nil
    }

    private func record(_ event: NSEvent) {
        guard let target else { return }
        // Échap alone cancels, as everywhere in macOS. ⌫ is recorded like any key.
        if event.keyCode == 53, event.modifierFlags.intersection(KeyBinding.relevantModifiers).isEmpty {
            cancel()
            return
        }
        guard let binding = KeyBinding(event: event) else { return }
        if binding.isReserved {
            notice = (target.action, "\(binding.label) est réservé par le menu de l'app.")
            return
        }
        if let owner = store.map.action(for: binding), owner != target.action {
            stopListening()
            conflict = Conflict(target: target, binding: binding, owner: owner)
            return
        }
        apply(binding, target)
        cancel()
    }

    private func apply(_ binding: KeyBinding, _ target: Target) {
        if let old = target.replacing, old != binding { store.remove(old) }
        store.assign(binding, to: target.action)
    }

    fileprivate func setNotice(_ action: ShortcutAction, _ text: String) { notice = (action, text) }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
    }
}

struct ShortcutsSettingsView: View {
    @ObservedObject var store: ShortcutStore
    @StateObject private var recorder: KeyRecorder

    init(store: ShortcutStore) {
        self.store = store
        _recorder = StateObject(wrappedValue: KeyRecorder(store: store))
    }

    var body: some View {
        Form {
            ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                Section(group.rawValue) {
                    ForEach(ShortcutAction.allCases.filter { $0.spec.group == group }) { row($0) }
                }
            }
            Section("App") {
                fixedRow("Ouvrir…", "⌘O")
                fixedRow("Réglages…", "⌘,")
                fixedRow("Fermer la fenêtre", "⌘W")
                fixedRow("Quitter BetterView", "⌘Q")
            }
            Section {
                HStack {
                    Spacer()
                    Button("Tout rétablir") {
                        recorder.cancel()
                        store.reset()
                    }
                    .disabled(ShortcutAction.allCases.allSatisfy { !store.map.isCustomized($0) })
                }
            } footer: {
                Text("Cliquer sur un raccourci pour le changer, le survoler pour le retirer. Les lettres suivent la disposition du clavier (AZERTY compris). Maintenir une touche ne répète que la navigation. Souris et trackpad : double-clic pour 100 %, pincement pour zoomer, glisser pour se déplacer.")
                    .settingsFooter()
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
        .onDisappear { recorder.cancel() }
    }

    private func fixedRow(_ title: String, _ key: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(key).foregroundStyle(.secondary).help("Réservé par le menu de l'app")
        }
    }

    /// While a conflict waits for an answer, the chip shows the key in question.
    private func pendingText(_ action: ShortcutAction) -> String {
        if let conflict = recorder.conflict, conflict.target.action == action { return conflict.binding.label }
        return "Tapez un raccourci…"
    }

    @ViewBuilder
    private func row(_ action: ShortcutAction) -> some View {
        let keys = store.map.keys(for: action)
        let customized = store.map.isCustomized(action)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(action.title)
                Spacer(minLength: 12)
                if keys.isEmpty, recorder.target?.action != action {
                    Text("Aucun").foregroundStyle(.tertiary)
                }
                ForEach(keys, id: \.self) { binding in
                    if recorder.target == .init(action: action, replacing: binding) {
                        RecordingChip(text: pendingText(action))
                    } else {
                        ShortcutChip(
                            label: binding.label,
                            onEdit: { recorder.start(action, replacing: binding) },
                            onRemove: {
                                recorder.cancel()
                                store.remove(binding)
                            }
                        )
                    }
                }
                if recorder.target == .init(action: action, replacing: nil) {
                    RecordingChip(text: pendingText(action))
                }
                Button { recorder.start(action) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Ajouter un raccourci")
                Button {
                    recorder.cancel()
                    let kept = store.reset(action)
                    if !kept.isEmpty {
                        let list = kept.map { "\($0.0.label) reste à « \($0.1.title) »" }.joined(separator: ", ")
                        recorder.say(action, list + ".")
                    }
                } label: { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Rétablir : \(action.defaultBindings.map(\.label).joined(separator: " "))")
                    .opacity(customized ? 1 : 0)
                    .disabled(!customized)
            }
            if let conflict = recorder.conflict, conflict.target.action == action {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("\(conflict.binding.label) est déjà utilisé par « \(conflict.owner.title) ».")
                    Spacer()
                    Button("Remplacer") { recorder.replace() }
                    Button("Annuler") { recorder.cancel() }
                }
                .font(.callout)
                .controlSize(.small)
            } else if let notice = recorder.notice, notice.action == action {
                Text(notice.text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

extension KeyRecorder {
    func say(_ action: ShortcutAction, _ text: String) { setNotice(action, text) }
}

private struct ShortcutChip: View {
    let label: String
    let onEdit: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onEdit) {
            Text(label).frame(minWidth: 18)
        }
        .buttonStyle(KeyCapStyle())
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .gray)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .help("Retirer \(label)")
            }
        }
        .onHover { hovering = $0 }
        .help("Cliquer pour changer")
    }
}

private struct RecordingChip: View {
    let text: String

    var body: some View {
        Text(text)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1))
            .shadow(color: Color.accentColor.opacity(0.35), radius: 2)
    }
}

private struct KeyCapStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: configuration.isPressed ? .selectedControlColor : .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 0, y: 1)
            )
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
    }
}

private extension View {
    func settingsFooter() -> some View {
        font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Window

/// Réglages window: toolbar tabs, as in Apple's own apps. Each tab sizes the window.
@MainActor
enum SettingsWindow {
    static func make(shortcuts: ShortcutStore, disk: DiskCache, viewer: ViewerController) -> NSWindow {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        func tab<Content: View>(_ title: String, _ symbol: String, _ view: Content) -> NSTabViewItem {
            let host = NSHostingController(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            host.title = title
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            return item
        }
        let general = GeneralSettingsView(
            associations: FileAssociations(),
            cache: CacheSettings(disk: disk),
            onInfoVisibleChange: { [weak viewer] in viewer?.setInfoVisible($0) },
            onStripVisibleChange: { [weak viewer] in viewer?.setStripVisible($0) }
        )
        tabs.addTabViewItem(tab("Général", "gearshape", general))
        tabs.addTabViewItem(tab("Raccourcis", "keyboard", ShortcutsSettingsView(store: shortcuts)))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        return window
    }
}
