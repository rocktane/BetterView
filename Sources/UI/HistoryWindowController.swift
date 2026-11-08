import AppKit

/// The deletions of the open folder, or of the last one opened, newest first. Opened on demand
/// and idle otherwise: nothing here runs while the user sorts photos with the window closed.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    private let session: LibrarySession
    private let folder: () -> String?
    private let thumbnails = HistoryThumbnails()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private(set) var entries: [DeletionRecord] = []

    private static let background = NSColor(white: 0.07, alpha: 1)

    init(session: LibrarySession, folder: @escaping () -> String?) {
        self.session = session
        self.folder = folder
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Self.background
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 460, height: 300)
        window.delegate = self
        window.setFrameAutosaveName("History")
        if !window.setFrameUsingName("History") { window.center() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = HistoryRow.height
        table.intercellSpacing = .zero
        table.backgroundColor = Self.background
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Self.background
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyLabel.textColor = NSColor(white: 1, alpha: 0.45)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.contentView = content

        thumbnails.onLoaded = { [weak self] id in self?.thumbnailArrived(id) }
    }

    func show() {
        // A fresh look at the Trash each time the window is opened.
        session.history.forgetChecks()
        session.history.onChange = { [weak self] in self?.reload() }
        reload()
        window.makeKeyAndOrderFront(nil)
    }

    func reload() {
        let path = folder()
        let name = path.map { FileManager.default.displayName(atPath: $0) }
        window.title = name.map { "Suppressions · \($0)" } ?? "Suppressions"
        entries = path.map { folder in
            session.history.newestFirst.filter { Self.standardized($0.folderPath) == folder }
        } ?? []
        emptyLabel.stringValue = path == nil ? "Aucun dossier ouvert" : "Aucune suppression dans ce dossier"
        emptyLabel.isHidden = !entries.isEmpty
        table.reloadData()
        session.history.check(entries.map(\.id))
    }

    static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func thumbnailArrived(_ id: UUID) {
        guard let row = entries.firstIndex(where: { $0.id == id }),
              let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? HistoryRow
        else { return }
        view.setThumbnail(thumbnails.image(id))
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let record = entries[row]
        let view = tableView.makeView(withIdentifier: HistoryRow.identifier, owner: nil) as? HistoryRow ?? HistoryRow()
        view.configure(record, status: session.history.status(record.id) ?? .unverified)
        view.setThumbnail(thumbnails.image(record.id))
        view.onRestore = { [weak self] in self?.restore(record.id) }
        // Only rows on screen ask for a preview; one leaving the screen cancels its own.
        thumbnails.request(record)
        return view
    }

    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        guard let view = rowView.view(atColumn: 0) as? HistoryRow, let id = view.recordID else { return }
        thumbnails.cancel(id)
    }

    private func restore(_ id: UUID) {
        if !session.restore(id) { NSSound.beep() }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        reload()
    }

    func windowWillClose(_ notification: Notification) {
        session.history.onChange = {}
        thumbnails.clear()
        entries = []
        table.reloadData()
    }
}

/// One deletion: a large preview, the name and date, and either Restaurer or why not.
@MainActor
final class HistoryRow: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryRow")
    static let height: CGFloat = 140

    private(set) var recordID: UUID?
    var onRestore: () -> Void = {}

    private let preview = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "Restaurer", target: nil, action: nil)
    private let separator = NSBox()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: Self.height))
        identifier = Self.identifier

        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor(white: 0.1, alpha: 1).cgColor
        preview.layer?.cornerRadius = 5
        preview.layer?.masksToBounds = true
        preview.imageScaling = .scaleProportionallyUpOrDown

        nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        nameLabel.textColor = NSColor(white: 0.94, alpha: 1)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        dateLabel.font = .systemFont(ofSize: 12)
        dateLabel.textColor = NSColor(white: 0.54, alpha: 1)
        stateLabel.font = .systemFont(ofSize: 12)
        stateLabel.textColor = NSColor(white: 0.48, alpha: 1)
        stateLabel.alignment = .right
        stateLabel.maximumNumberOfLines = 2
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(restoreClicked)

        let text = NSStackView(views: [nameLabel, dateLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4

        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = NSColor(white: 0.105, alpha: 1)

        for view in [preview, text, stateLabel, button, separator] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            preview.centerYAnchor.constraint(equalTo: centerYAnchor),
            preview.widthAnchor.constraint(equalToConstant: 180),
            preview.heightAnchor.constraint(equalToConstant: 120),
            text.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 16),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: stateLabel.leadingAnchor, constant: -12),
            text.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            stateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 130),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ record: DeletionRecord, status: DeletionStatus) {
        recordID = record.id
        nameLabel.stringValue = record.name
        dateLabel.stringValue = Self.format(record.deletedAt)
        let reason: String? = switch status {
        case .inTrash, .inaccessible, .restoring, .trashing, .deleting: nil
        case .restored: "Restaurée"
        case .unavailable: "Plus dans la corbeille"
        case .deletedPermanently: "Supprimée définitivement"
        case .unverified: "À vérifier"
        }
        stateLabel.stringValue = reason ?? ""
        stateLabel.isHidden = reason == nil
        button.isHidden = reason != nil
        // Inaccessible stays clickable: once access is back the same button works, and a
        // refusal explains itself in an alert.
        button.isEnabled = status == .inTrash || { if case .inaccessible = status { true } else { false } }()
    }

    var hasThumbnail: Bool { preview.image != nil }

    func setThumbnail(_ image: CGImage?) {
        preview.image = image.map { NSImage(cgImage: $0, size: .zero) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        setThumbnail(nil)
        recordID = nil
    }

    @objc private func restoreClicked() { onRestore() }

    private static let dated: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// « Il y a 2 min » within the hour, then « Aujourd'hui à 10:40 », « Hier à 18:05 »…
    static func format(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed >= 0 && elapsed < 60 { return "À l'instant" }
        if elapsed >= 0 && elapsed < 3600 { return "Il y a \(Int(elapsed / 60)) min" }
        let text = dated.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
