import Foundation

/// File operations, swappable so tests and the benchmark never touch the real Trash.
struct FileOps: Sendable {
    var trash: @Sendable (URL) throws -> URL
    var restore: @Sendable (_ from: URL, _ to: URL) throws -> Void
    var deletePermanently: @Sendable (URL) throws -> Void

    static let system = FileOps(
        trash: { url in
            var result: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &result)
            guard let result else { throw CocoaError(.fileWriteUnknown) }
            return result as URL
        },
        // moveItem refuses to overwrite, so a restored file can never clobber a new one.
        restore: { try FileManager.default.moveItem(at: $0, to: $1) },
        deletePermanently: { try FileManager.default.removeItem(at: $0) }
    )
}

enum SessionEvent: Sendable {
    case listChanged
    case restored(PhotoKey)
    case trashed(PhotoKey)
    case fileChanged(name: String)
    case trashFailed(PhotoKey, TrashFailure)
    /// Only the protection of some photos changed: no pixels to redo.
    case protectionChanged
    case restoreFailed(name: String, message: String)
    case deleteFailed(name: String, message: String)
    /// The deletion history could not be written: deletions still work, without a record.
    case historyNotSaved(message: String)
}

/// Owns the list and everything that can change it: scans, deletions and undo.
///
/// Invariants:
/// - a photo with a queued deletion is a tombstone and no scan can bring it back;
/// - one scan at a time per session, so snapshots of a session are always in order;
/// - a snapshot older than the last finished file operation is thrown away and redone;
/// - a snapshot from another session is ignored.
@MainActor
final class LibrarySession {
    @MainActor private final class TrashOp {
        let photo: PhotoKey
        let record: UUID
        var undoRequested = false
        init(photo: PhotoKey, record: UUID) {
            self.photo = photo
            self.record = record
        }
    }

    private(set) var list = PhotoList()
    /// Every deletion, of this launch and of earlier ones when a journal is given.
    let history = DeletionHistory()
    private(set) var tombstones: Set<String> = []
    /// Protected photos by path, from the latest scan or deletion attempt. Never read from disk here.
    private(set) var protection: [String: FileProtection] = [:]
    var onEvent: (SessionEvent) -> Void = { _ in }
    var onDrained: (() -> Void)?

    var fileOps: FileOps
    private let scanner: @Sendable (URL, Set<String>?) -> ScanSnapshot
    private let ioQueue = DispatchQueue(label: "betterview.fileops", qos: .userInitiated)
    private let scanQueue = DispatchQueue(label: "betterview.scan", qos: .userInitiated)
    private let watcher = FolderWatcher()

    private var folder: URL?
    private var allowed: Set<String>?
    private var desiredPath: String?
    private var sessionID = 0
    private var opGeneration = 0
    private var scanRunning = false
    private var rescanPending = false
    /// Deletions still in progress, by record.
    private var ops: [UUID: TrashOp] = [:]
    /// Deletions of this launch that ⌘Z can take back, latest last. A failed restore stays.
    private var undoStack: [UUID] = []
    /// Deletions of one gesture share a group, and one undo brings them all back.
    private var groups: [UUID: Int] = [:]
    private var lastGroup = 0
    private var pendingIO = 0
    private let journal: DeletionJournal?

    init(fileOps: FileOps = .system,
         scanner: @escaping @Sendable (URL, Set<String>?) -> ScanSnapshot = FolderScanner.scan,
         journal: DeletionJournal? = nil) {
        self.fileOps = fileOps
        self.scanner = scanner
        self.journal = journal
        if let journal {
            journal.onFailure = { [weak self] message in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.onEvent(.historyNotSaved(message: message)) }
                }
            }
            // First on the queue, so it reads the file before this launch appends to it.
            ioQueue.async { [weak self] in
                let loaded = journal.load()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.history.load(loaded) }
                }
            }
        }
    }

    var hasPendingIO: Bool { pendingIO > 0 }

    func protection(of photo: PhotoKey) -> FileProtection { protection[photo.path] ?? [] }

    /// The folder of the active list, for the history's default filter.
    var folderPath: String? { folder?.standardizedFileURL.path }

    /// Whether a file belongs in the active list: same folder, and among the chosen files
    /// when only some were opened. A file of another folder is restored on disk only.
    private func covers(_ path: String) -> Bool {
        guard let folderPath else { return false }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.deletingLastPathComponent().path == folderPath else { return false }
        return allowed?.contains(file.path) ?? true
    }

    // MARK: Opening

    /// One file opens its folder positioned on it; several files open just those; a folder
    /// opens its contents. A single file is shown before the scan finishes.
    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        sessionID += 1
        scanRunning = false
        rescanPending = false
        list = PhotoList()
        protection = [:]
        let session = sessionID

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: first.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            folder = first
            allowed = nil
            desiredPath = nil
        } else {
            let path = first.standardizedFileURL.path
            folder = first.deletingLastPathComponent()
            allowed = urls.count > 1 ? Set(urls.map { $0.standardizedFileURL.path }) : nil
            desiredPath = path
            scanQueue.async { [weak self] in
                guard let (key, protected) = PhotoKey.readWithProtection(path: path) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.sessionID == session, self.list.count == 0 else { return }
                        self.list = PhotoList(photos: [key], selecting: path)
                        if !protected.isEmpty { self.protection[path] = protected }
                        self.onEvent(.listChanged)
                    }
                }
            }
        }
        onEvent(.listChanged)
        // The history window shows the open folder's deletions.
        history.onChange()
        if let folder {
            watcher.watch(folder) { [weak self] in self?.requestScan() }
        }
        requestScan()
    }

    // MARK: Scanning

    func requestScan() {
        guard let folder else { return }
        guard !scanRunning else {
            rescanPending = true
            return
        }
        scanRunning = true
        rescanPending = false
        let session = sessionID
        let generation = opGeneration
        let allowed = allowed
        let scanner = scanner
        scanQueue.async { [weak self] in
            let snapshot = scanner(folder, allowed)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(snapshot: snapshot, session: session, generation: generation)
                }
            }
        }
    }

    private func apply(snapshot: ScanSnapshot, session: Int, generation: Int) {
        // An old session's scan neither applies nor touches the new session's flags.
        guard session == sessionID else { return }
        scanRunning = false
        guard generation == opGeneration else {
            requestScan()
            return
        }
        let protectionChanged = snapshot.protection != protection
        protection = snapshot.protection
        if list.merge(scan: snapshot.photos, excluding: tombstones, selecting: desiredPath) {
            onEvent(.listChanged)
        } else if protectionChanged {
            onEvent(.protectionChanged)
        }
        if rescanPending { requestScan() }
    }

    // MARK: Navigation

    @discardableResult
    func move(to index: Int) -> Bool { list.move(to: index) }

    // MARK: Deleting

    /// Removes the current photo from the list right away, then trashes it in FIFO order.
    /// Returns false when there is nothing to delete, or when the photo is known to be protected.
    @discardableResult
    func trashCurrent(direction: Int) -> Bool {
        guard let current = list.current, protection(of: current).isEmpty,
              let photo = list.removeCurrent(direction: direction) else { return false }
        lastGroup += 1
        enqueueTrash(photo, group: lastGroup)
        onEvent(.listChanged)
        return true
    }

    /// Removes these photos from the list right away, then trashes them in FIFO order, as one
    /// gesture for undo. Photos no longer listed under this exact revision are left alone.
    /// Returns false when none of them could be deleted.
    @discardableResult
    func trash(_ photos: [PhotoKey]) -> Bool {
        let accepted = photos.filter { protection(of: $0).isEmpty && list.remove($0) }
        guard !accepted.isEmpty else { return false }
        lastGroup += 1
        for photo in accepted { enqueueTrash(photo, group: lastGroup) }
        onEvent(.listChanged)
        return true
    }

    private func enqueueTrash(_ photo: PhotoKey, group: Int) {
        tombstones.insert(photo.path)
        let record = DeletionRecord(photo: photo, phase: .trashing)
        let op = TrashOp(photo: photo, record: record.id)
        ops[record.id] = op
        undoStack.append(record.id)
        groups[record.id] = group
        history.update(record)
        pendingIO += 1
        let fileOps = fileOps
        let journal = journal
        ioQueue.async { [weak self] in
            // Intent first: an interruption after the move leaves an entry to check, not a lie.
            journal?.append(record)
            let result = Self.performTrash(photo: photo, fileOps: fileOps)
            var outcome = record.with(.cancelled)
            if case .trashed(let trashURL) = result {
                outcome = record.with(.inTrash)
                outcome.trashPath = trashURL.path
                if case .file(let revision) = PathState.inspect(trashURL.path) { outcome.trashRevision = revision }
            }
            journal?.append(outcome)
            let settled = outcome
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishTrash(op, result, record: settled) }
            }
        }
    }

    private enum TrashResult: Sendable {
        case trashed(URL)
        case changed
        case failed(TrashFailure)
    }

    /// The file on disk must still be the revision the user saw, otherwise it is not ours to delete.
    /// A protection set since the scan is checked again here, and never bypassed.
    private nonisolated static func performTrash(photo: PhotoKey, fileOps: FileOps) -> TrashResult {
        guard let (key, protected) = PhotoKey.readWithProtection(path: photo.path), key == photo else { return .changed }
        if protected.contains(.locked) { return .failed(.locked) }
        if protected.contains(.readOnly) { return .failed(.fileNotWritable) }
        do {
            return .trashed(try fileOps.trash(photo.url))
        } catch {
            return .failed(TrashFailure.classify(error, probe: TrashProbe.read(path: photo.path)))
        }
    }

    private func finishTrash(_ op: TrashOp, _ result: TrashResult, record: DeletionRecord) {
        tombstones.remove(op.photo.path)
        opGeneration += 1
        ops[op.record] = nil
        history.update(record)
        if case .trashed = result {} else { dropUndo(op.record) }
        switch result {
        case .trashed:
            onEvent(.trashed(op.photo))
            if op.undoRequested { restore(op.record) }
        case .changed:
            onEvent(.fileChanged(name: op.photo.name))
            requestScan()
        case .failed(let failure):
            // Still in its folder on disk; back in the list only if that folder is still open.
            if covers(op.photo.path) {
                if failure == .locked { protection[op.photo.path, default: []].insert(.locked) }
                if failure == .fileNotWritable { protection[op.photo.path, default: []].insert(.readOnly) }
                list.insert(op.photo, select: op.undoRequested || list.count == 0)
                onEvent(.listChanged)
            }
            onEvent(.trashFailed(op.photo, failure))
        }
        ioFinished()
    }

    private func dropUndo(_ id: UUID) {
        undoStack.removeAll { $0 == id }
        groups[id] = nil
    }

    /// Undoes the latest deletion gesture of this launch not already being undone, whatever
    /// number of photos it took. A deletion still in progress is restored as soon as it
    /// completes. A restore that failed is tried again.
    @discardableResult
    func undo() -> Bool {
        func undoable(_ id: UUID) -> Bool {
            if let op = ops[id] { return !op.undoRequested }
            return history[id]?.phase == .inTrash
        }
        guard let latest = undoStack.last(where: undoable) else { return false }
        let group = groups[latest]
        for id in undoStack.reversed() where groups[id] == group && undoable(id) {
            if let op = ops[id] {
                op.undoRequested = true
            } else {
                restore(id)
            }
        }
        return true
    }

    /// Restores one entry of the history, with the same checks as ⌘Z. Later deletions stay.
    /// Returns false when the entry is not in the Trash as far as the history knows.
    @discardableResult
    func restore(_ id: UUID) -> Bool {
        guard let record = history[id], record.phase == .inTrash, record.trashPath != nil else { return false }
        let restoring = record.with(.restoring)
        history.update(restoring)
        pendingIO += 1
        let fileOps = fileOps
        let journal = journal
        ioQueue.async { [weak self] in
            journal?.append(restoring)
            let outcome = Self.performRestore(restoring, fileOps: fileOps)
            let settled: DeletionRecord
            if case .restored = outcome { settled = restoring.with(.restored) } else { settled = restoring.with(.inTrash) }
            journal?.append(settled)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishRestore(settled, outcome) }
            }
        }
        return true
    }

    enum RestoreOutcome: Sendable, Equatable {
        case restored(PhotoKey)
        /// Something already has the original name. Free it and try again.
        case occupied
        /// The Trash no longer has it: emptied, or the file was taken out.
        case missing
        /// Something else sits at the Trash URL. It is not ours to restore.
        case replaced
        case inaccessible(String)
        case failed(String)

        var message: String {
            switch self {
            case .restored: ""
            case .occupied: "Un fichier porte déjà ce nom dans le dossier d'origine. Rien n'a été écrasé : libérez ce nom puis réessayez."
            case .missing: "Le fichier n'est plus dans la corbeille : elle a été vidée, ou il en a été retiré."
            case .replaced: "Le fichier présent dans la corbeille à cet emplacement n'est pas celui qui a été supprimé. Il n'a pas été déplacé."
            case .inaccessible(let reason): "Accès refusé (\(reason)). Le fichier est resté dans la corbeille."
            case .failed(let reason): "\(reason)\nLe fichier est resté dans la corbeille."
            }
        }
    }

    /// The file in the Trash must be the one that was moved there, and the origin must be free.
    private nonisolated static func performRestore(_ record: DeletionRecord, fileOps: FileOps) -> RestoreOutcome {
        guard let trashPath = record.trashPath else { return .missing }
        switch PathState.inspect(trashPath) {
        case .missing: return .missing
        case .other: return .replaced
        case .inaccessible(let reason): return .inaccessible(reason)
        case .file(let revision):
            guard revision == record.expectedInTrash else { return .replaced }
        }
        switch PathState.inspect(record.originPath) {
        case .missing: break
        case .inaccessible(let reason): return .inaccessible(reason)
        case .file, .other: return .occupied
        }
        do {
            // Never replaces: a file arriving at the origin meanwhile makes this throw.
            try fileOps.restore(URL(fileURLWithPath: trashPath), URL(fileURLWithPath: record.originPath))
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            return .occupied
        } catch let error as CocoaError where error.code == .fileWriteNoPermission || error.code == .fileReadNoPermission {
            return .inaccessible(error.localizedDescription)
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let key = PhotoKey.read(path: record.originPath) else { return .failed("Le fichier restauré est introuvable.") }
        return .restored(key)
    }

    private func finishRestore(_ record: DeletionRecord, _ outcome: RestoreOutcome) {
        opGeneration += 1
        history.update(record)
        switch outcome {
        case .restored(let key):
            dropUndo(record.id)
            if covers(key.path) {
                list.insert(key, select: true)
                onEvent(.listChanged)
            }
            onEvent(.restored(key))
        case .missing, .replaced:
            // Retrying can never work: ⌘Z moves on to the deletion before.
            dropUndo(record.id)
            history.setCheck(record.id, outcome == .missing ? .missing : .other)
            onEvent(.restoreFailed(name: record.name, message: outcome.message))
        case .inaccessible(let reason):
            history.setCheck(record.id, .inaccessible(reason))
            onEvent(.restoreFailed(name: record.name, message: outcome.message))
        case .occupied, .failed:
            onEvent(.restoreFailed(name: record.name, message: outcome.message))
        }
        ioFinished()
    }

    /// Only after the user confirmed a volume without Trash. Never enters the undo stack.
    func deletePermanently(_ photo: PhotoKey) {
        guard list.current?.path == photo.path || list.photos.contains(where: { $0.path == photo.path }) else { return }
        tombstones.insert(photo.path)
        let wasCurrent = list.current?.path == photo.path
        if wasCurrent {
            _ = list.removeCurrent(direction: 1)
        } else {
            _ = list.merge(scan: list.photos, excluding: tombstones)
        }
        onEvent(.listChanged)
        let record = DeletionRecord(photo: photo, phase: .deleting)
        history.update(record)
        pendingIO += 1
        let fileOps = fileOps
        let journal = journal
        ioQueue.async { [weak self] in
            journal?.append(record)
            var message: String?
            if let (key, protected) = PhotoKey.readWithProtection(path: photo.path), key == photo {
                if !protected.isEmpty {
                    message = (protected.contains(.locked) ? TrashFailure.locked : .fileNotWritable).explanation
                } else {
                    do { try fileOps.deletePermanently(photo.url) } catch { message = error.localizedDescription }
                }
            } else {
                message = "Le fichier a changé sur le disque."
            }
            let failure = message
            let settled = record.with(failure == nil ? .deleted : .cancelled)
            journal?.append(settled)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.history.update(settled)
                    self.tombstones.remove(photo.path)
                    self.opGeneration += 1
                    if let failure {
                        self.onEvent(.deleteFailed(name: photo.name, message: failure))
                        self.requestScan()
                    } else {
                        self.onEvent(.trashed(photo))
                    }
                    self.ioFinished()
                }
            }
        }
    }

    private func ioFinished() {
        pendingIO -= 1
        if pendingIO == 0 {
            if rescanPending { requestScan() }
            onDrained?()
        }
    }
}
