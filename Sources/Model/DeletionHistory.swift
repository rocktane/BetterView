import Foundation

/// What identifies a file's content whatever its path: a rename to the Trash keeps it.
struct FileRevision: Codable, Hashable, Sendable {
    let device: Int64
    let inode: UInt64
    let size: Int64
    let mtimeSeconds: Int
    let mtimeNanoseconds: Int

    init(_ key: PhotoKey) {
        device = key.device
        inode = key.inode
        size = key.size
        mtimeSeconds = key.mtimeSeconds
        mtimeNanoseconds = key.mtimeNanoseconds
    }
}

extension PhotoKey {
    var revision: FileRevision { FileRevision(self) }
}

/// What is at a path, as far as one `lstat` can tell. Blocking: never on the main thread.
enum PathState: Equatable, Sendable {
    case file(FileRevision)
    /// Something else: a folder, a link, a special file.
    case other
    case missing
    case inaccessible(String)

    static func inspect(_ path: String) -> PathState {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            switch errno {
            case ENOENT, ENOTDIR: return .missing
            case let code: return .inaccessible(String(cString: strerror(code)))
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return .other }
        return .file(FileRevision(PhotoKey(
            path: path,
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mtimeSeconds: info.st_mtimespec.tv_sec,
            mtimeNanoseconds: info.st_mtimespec.tv_nsec
        )))
    }
}

/// One deletion, as written to the journal. Every change of phase is decided and written on
/// the file operation queue, in the same block as the file operation it describes.
struct DeletionRecord: Codable, Identifiable, Sendable, Equatable {
    enum Phase: String, Codable, Sendable {
        /// Written before the move to the Trash.
        case trashing
        case inTrash
        /// Written before the move back.
        case restoring
        case restored
        /// Written before a permanent deletion.
        case deleting
        case deleted
        /// Interrupted while trashing or restoring, and the disk could not settle it.
        case unverified
        /// Nothing happened in the end (refused or failed deletion): dropped at the next load.
        case cancelled
    }

    let id: UUID
    let originPath: String
    let source: FileRevision
    let deletedAt: Date
    var phase: Phase
    /// The URL the Trash really used, as returned by the move. Never guessed.
    var trashPath: String?
    var trashRevision: FileRevision?
    var changedAt: Date

    init(photo: PhotoKey, phase: Phase, date: Date = Date()) {
        id = UUID()
        originPath = photo.path
        source = photo.revision
        deletedAt = date
        self.phase = phase
        changedAt = date
    }

    var name: String { (originPath as NSString).lastPathComponent }
    var folderPath: String { (originPath as NSString).deletingLastPathComponent }
    /// What the file in the Trash must still be for a restore to go ahead.
    var expectedInTrash: FileRevision { trashRevision ?? source }

    func with(_ phase: Phase, date: Date = Date()) -> DeletionRecord {
        var copy = self
        copy.phase = phase
        copy.changedAt = date
        return copy
    }

    /// Settles a phase left open by an interruption, from what is on disk now. Blocking.
    func settled() -> DeletionRecord {
        let atOrigin = PathState.inspect(originPath) == .file(source)
        switch phase {
        case .trashing, .deleting:
            // Still in place, so the move never happened. Otherwise nothing tells where it went.
            return with(atOrigin ? .cancelled : .unverified, date: changedAt)
        case .restoring:
            if let trashPath, PathState.inspect(trashPath) == .file(expectedInTrash) {
                return with(.inTrash, date: changedAt)
            }
            return with(atOrigin ? .restored : .unverified, date: changedAt)
        default:
            return self
        }
    }
}

/// An append-only file of JSON lines, the last line of an id winning. Used only from the
/// session's file operation queue, which orders it with the moves it describes.
final class DeletionJournal: @unchecked Sendable {
    let url: URL
    let limit: Int

    init(url: URL, limit: Int = 1000) {
        self.url = url
        self.limit = limit
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterView", isDirectory: true)
            .appendingPathComponent("suppressions.jsonl")
    }

    private let encoder = JSONEncoder()
    /// Called on the file operation queue the first time a line cannot be written. The file
    /// operation still happens: refusing it would leave only the permanent deletion offered
    /// for a failed trash, and ⌘Z keeps working for this launch. The user is told instead.
    var onFailure: @Sendable (String) -> Void = { _ in }
    private var reported = false

    /// Written and flushed before returning: the next file operation comes after it.
    func append(_ record: DeletionRecord) {
        do {
            try write(record)
        } catch {
            guard !reported else { return }
            reported = true
            onFailure(error.localizedDescription)
        }
    }

    private func write(_ record: DeletionRecord) throws {
        var line = try encoder.encode(record)
        line.append(0x0A)
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    /// Folds the lines, settles interrupted phases from the disk, keeps the latest `limit`
    /// entries and rewrites the file when that changed anything. A damaged line is skipped.
    func load() -> [DeletionRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        var latest: [UUID: DeletionRecord] = [:]
        var lines = 0
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            lines += 1
            if let record = try? decoder.decode(DeletionRecord.self, from: Data(line)) {
                latest[record.id] = record
            }
        }
        var changed = false
        var records: [DeletionRecord] = []
        for record in latest.values {
            let settled = record.settled()
            if settled != record { changed = true }
            if settled.phase != .cancelled { records.append(settled) }
        }
        records.sort { $0.deletedAt > $1.deletedAt }
        if records.count > limit { records.removeLast(records.count - limit) }
        if changed || lines != records.count {
            var out = Data()
            for record in records.reversed() {
                guard let line = try? encoder.encode(record) else { continue }
                out.append(line)
                out.append(0x0A)
            }
            try? out.write(to: url, options: .atomic)
        }
        return records
    }
}

/// State of an entry as the history window shows it.
enum DeletionStatus: Equatable, Sendable {
    case trashing
    case inTrash
    case restoring
    case restored(Date)
    case deleting
    case deletedPermanently
    case unverified
    /// The Trash no longer holds this file.
    case unavailable(String)
    /// The file may be there, but the system refuses to look.
    case inaccessible(String)

    var canRestore: Bool { self == .inTrash }
}

/// The deletions on the main thread, newest first, mirrored from what the file operation queue
/// wrote. Checks of the Trash are done off the main thread, on request of the history window.
@MainActor
final class DeletionHistory {
    private(set) var records: [UUID: DeletionRecord] = [:]
    private var checks: [UUID: PathState] = [:]
    private var checking: Set<UUID> = []
    var onChange: () -> Void = {}
    private let checkQueue = DispatchQueue(label: "betterview.history.check", qos: .utility)

    var newestFirst: [DeletionRecord] {
        records.values.sorted { $0.deletedAt > $1.deletedAt }
    }

    subscript(id: UUID) -> DeletionRecord? { records[id] }

    func update(_ record: DeletionRecord) {
        if record.phase == .cancelled {
            records[record.id] = nil
        } else {
            records[record.id] = record
        }
        checks[record.id] = nil
        onChange()
    }

    /// Entries from earlier launches. Those of this launch, newer by construction, win.
    func load(_ loaded: [DeletionRecord]) {
        for record in loaded where records[record.id] == nil {
            records[record.id] = record
        }
        onChange()
    }

    func status(_ id: UUID) -> DeletionStatus? {
        guard let record = records[id] else { return nil }
        switch record.phase {
        case .trashing: return .trashing
        case .restoring: return .restoring
        case .restored: return .restored(record.changedAt)
        case .deleting: return .deleting
        case .deleted: return .deletedPermanently
        case .unverified, .cancelled: return .unverified
        case .inTrash:
            switch checks[id] {
            case .missing?:
                return .unavailable("Le fichier n'est plus dans la corbeille : elle a été vidée, ou il en a été retiré.")
            case .other?:
                return .unavailable("Un autre élément occupe sa place dans la corbeille.")
            case .file(let revision)? where revision != record.expectedInTrash:
                return .unavailable("Un autre fichier occupe sa place dans la corbeille.")
            case .inaccessible(let reason)?:
                return .inaccessible("Accès refusé à la corbeille (\(reason)).")
            default:
                return .inTrash
            }
        }
    }

    /// The next `check` looks at the Trash again, for entries already looked at.
    func forgetChecks() {
        checks.removeAll()
    }

    /// Looks at the Trash URL of these entries not looked at yet, off the main thread.
    func check(_ ids: [UUID]) {
        let todo = ids.compactMap { id -> (UUID, String)? in
            guard checks[id] == nil, !checking.contains(id), let record = records[id], record.phase == .inTrash,
                  let path = record.trashPath else { return nil }
            return (id, path)
        }
        guard !todo.isEmpty else { return }
        todo.forEach { checking.insert($0.0) }
        checkQueue.async { [weak self] in
            let results = todo.map { ($0.0, PathState.inspect($0.1)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (id, state) in results {
                        self.checking.remove(id)
                        if self.records[id]?.phase == .inTrash { self.checks[id] = state }
                    }
                    self.onChange()
                }
            }
        }
    }

    func setCheck(_ id: UUID, _ state: PathState) {
        checks[id] = state
        onChange()
    }
}
