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
    case trashFailed(PhotoKey, message: String)
    case restoreFailed(name: String, message: String)
    case deleteFailed(name: String, message: String)
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
        enum State { case pending, done(URL) }
        let photo: PhotoKey
        /// Deletions of one gesture share a group, and one undo brings them all back.
        let group: Int
        var state = State.pending
        var undoRequested = false
        init(photo: PhotoKey, group: Int) {
            self.photo = photo
            self.group = group
        }
    }

    private(set) var list = PhotoList()
    private(set) var tombstones: Set<String> = []
    var onEvent: (SessionEvent) -> Void = { _ in }
    var onDrained: (() -> Void)?

    var fileOps: FileOps
    private let scanner: @Sendable (URL, Set<String>?) -> [PhotoKey]
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
    private var ops: [TrashOp] = []
    private var pendingIO = 0
    private var lastGroup = 0

    init(fileOps: FileOps = .system,
         scanner: @escaping @Sendable (URL, Set<String>?) -> [PhotoKey] = FolderScanner.scan) {
        self.fileOps = fileOps
        self.scanner = scanner
    }

    var hasPendingIO: Bool { pendingIO > 0 }

    // MARK: Opening

    /// One file opens its folder positioned on it; several files open just those; a folder
    /// opens its contents. A single file is shown before the scan finishes.
    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        sessionID += 1
        scanRunning = false
        rescanPending = false
        list = PhotoList()
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
                guard let key = PhotoKey.read(path: path) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.sessionID == session, self.list.count == 0 else { return }
                        self.list = PhotoList(photos: [key], selecting: path)
                        self.onEvent(.listChanged)
                    }
                }
            }
        }
        onEvent(.listChanged)
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

    private func apply(snapshot: [PhotoKey], session: Int, generation: Int) {
        // An old session's scan neither applies nor touches the new session's flags.
        guard session == sessionID else { return }
        scanRunning = false
        guard generation == opGeneration else {
            requestScan()
            return
        }
        if list.merge(scan: snapshot, excluding: tombstones, selecting: desiredPath) {
            onEvent(.listChanged)
        }
        if rescanPending { requestScan() }
    }

    // MARK: Navigation

    @discardableResult
    func move(to index: Int) -> Bool { list.move(to: index) }

    // MARK: Deleting

    /// Removes the current photo from the list right away, then trashes it in FIFO order.
    /// Returns false when there is nothing to delete.
    @discardableResult
    func trashCurrent(direction: Int) -> Bool {
        guard let photo = list.removeCurrent(direction: direction) else { return false }
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
        let accepted = photos.filter { list.remove($0) }
        guard !accepted.isEmpty else { return false }
        lastGroup += 1
        for photo in accepted { enqueueTrash(photo, group: lastGroup) }
        onEvent(.listChanged)
        return true
    }

    private func enqueueTrash(_ photo: PhotoKey, group: Int) {
        tombstones.insert(photo.path)
        let op = TrashOp(photo: photo, group: group)
        ops.append(op)
        pendingIO += 1
        let fileOps = fileOps
        ioQueue.async { [weak self] in
            let result = Self.performTrash(photo: photo, fileOps: fileOps)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishTrash(op, result) }
            }
        }
    }

    private enum TrashResult: Sendable {
        case trashed(URL)
        case changed
        case failed(String)
    }

    /// The file on disk must still be the revision the user saw, otherwise it is not ours to delete.
    private nonisolated static func performTrash(photo: PhotoKey, fileOps: FileOps) -> TrashResult {
        guard PhotoKey.read(path: photo.path) == photo else { return .changed }
        do {
            return .trashed(try fileOps.trash(photo.url))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func finishTrash(_ op: TrashOp, _ result: TrashResult) {
        tombstones.remove(op.photo.path)
        opGeneration += 1
        switch result {
        case .trashed(let trashURL):
            op.state = .done(trashURL)
            onEvent(.trashed(op.photo))
            if op.undoRequested {
                ops.removeAll { $0 === op }
                restore(op.photo, from: trashURL)
            }
        case .changed:
            ops.removeAll { $0 === op }
            onEvent(.fileChanged(name: op.photo.name))
            requestScan()
        case .failed(let message):
            ops.removeAll { $0 === op }
            list.insert(op.photo, select: op.undoRequested || list.count == 0)
            onEvent(.listChanged)
            onEvent(.trashFailed(op.photo, message: message))
        }
        ioFinished()
    }

    /// Undoes the latest deletion gesture not already being undone, whatever number of photos
    /// it took. A deletion still in progress is restored as soon as it completes.
    @discardableResult
    func undo() -> Bool {
        guard let latest = ops.last(where: { !$0.undoRequested }) else { return false }
        for op in ops.reversed() where op.group == latest.group && !op.undoRequested {
            switch op.state {
            case .pending:
                op.undoRequested = true
            case .done(let trashURL):
                ops.removeAll { $0 === op }
                restore(op.photo, from: trashURL)
            }
        }
        return true
    }

    private func restore(_ photo: PhotoKey, from trashURL: URL) {
        pendingIO += 1
        let fileOps = fileOps
        ioQueue.async { [weak self] in
            var failure: String?
            var restored: PhotoKey?
            do {
                try fileOps.restore(trashURL, photo.url)
                restored = PhotoKey.read(path: photo.path)
            } catch {
                failure = error.localizedDescription
            }
            let message = failure
            let key = restored
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.opGeneration += 1
                    if let key {
                        self.list.insert(key, select: true)
                        self.onEvent(.listChanged)
                        self.onEvent(.restored(key))
                    } else {
                        self.onEvent(.restoreFailed(name: photo.name, message: message ?? ""))
                    }
                    self.ioFinished()
                }
            }
        }
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
        pendingIO += 1
        let fileOps = fileOps
        ioQueue.async { [weak self] in
            var message: String?
            if PhotoKey.read(path: photo.path) == photo {
                do { try fileOps.deletePermanently(photo.url) } catch { message = error.localizedDescription }
            } else {
                message = "Le fichier a changé sur le disque."
            }
            let failure = message
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
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
