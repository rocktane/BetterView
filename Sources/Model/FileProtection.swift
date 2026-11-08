import Foundation

/// Why a photo must not be deleted, as read from the file itself. Kept apart from `PhotoKey`:
/// locking a file changes its ctime, never its mtime, so frames and the disk cache stay valid.
///
/// A photo protected in the camera carries the FAT/exFAT read-only attribute, which macOS
/// shows as `uchg` (locked in the Finder). It survives a Finder copy, `cp -p`, `ditto` and
/// `FileManager.copyItem`, but not a plain `cp`.
struct FileProtection: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    /// `uchg`/`schg` (or append-only): unlink and rename fail with EPERM.
    static let locked = FileProtection(rawValue: 1 << 0)
    /// No write permission for this user. The Trash would accept it; we take it as intent.
    static let readOnly = FileProtection(rawValue: 1 << 1)

    static let lockFlags = UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND)

    /// Blocking: never call from the main thread.
    init(path: String, info: stat) {
        var value: FileProtection = []
        if info.st_flags & Self.lockFlags != 0 { value.insert(.locked) }
        // EACCES only: EPERM is the lock above, EROFS is the volume, not this file.
        if access(path, W_OK) != 0 && errno == EACCES { value.insert(.readOnly) }
        self = value
    }

    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Blocking: never call from the main thread.
    static func read(path: String) -> FileProtection? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileProtection(path: path, info: info)
    }

    /// Shown in the brief banner when the Delete key is refused.
    var refusal: String {
        contains(.locked) ? "Photo protégée : non supprimée" : "Photo en lecture seule : non supprimée"
    }
}

/// What the disk says around a failed deletion, read off the main thread right after it.
struct TrashProbe: Sendable, Equatable {
    var protection: FileProtection = []
    var volumeReadOnly = false
    var folderWritable = true

    /// Blocking: never call from the main thread.
    static func read(path: String) -> TrashProbe {
        let folder = (path as NSString).deletingLastPathComponent
        var probe = TrashProbe()
        probe.protection = FileProtection.read(path: path) ?? []
        var fs = statfs()
        if statfs(folder, &fs) == 0 { probe.volumeReadOnly = fs.f_flags & UInt32(MNT_RDONLY) != 0 }
        probe.folderWritable = !(access(folder, W_OK) != 0 && errno == EACCES)
        return probe
    }
}

/// Why a photo was not moved to the Trash. Only `.noTrash` may lead to a permanent deletion,
/// and only after the user confirms it; a recognised protection is never bypassed.
enum TrashFailure: Error, Equatable, Sendable {
    case locked
    case fileNotWritable
    case folderNotWritable
    case readOnlyVolume
    case noTrash
    case other(String)

    var allowsPermanentDelete: Bool { self == .noTrash }

    /// Measured on macOS 27: a locked file and a read-only folder both give Cocoa 513, and a
    /// read-only volume gives 3328 like a volume without Trash. The disk state decides first.
    static func classify(_ error: Error, probe: TrashProbe) -> TrashFailure {
        if probe.protection.contains(.locked) { return .locked }
        if probe.protection.contains(.readOnly) { return .fileNotWritable }
        let ns = error as NSError
        let posix = (ns.domain == NSPOSIXErrorDomain ? ns.code : nil)
            ?? (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        if probe.volumeReadOnly || posix == Int(EROFS)
            || (ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteVolumeReadOnly.rawValue) {
            return .readOnlyVolume
        }
        if !probe.folderWritable { return .folderNotWritable }
        if ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.featureUnsupported.rawValue { return .noTrash }
        return .other(ns.localizedDescription)
    }

    var explanation: String {
        switch self {
        case .locked:
            "La photo est protégée dans le boîtier ou verrouillée dans le Finder. BetterView ne retire jamais cette protection."
        case .fileNotWritable: "Vous n'avez pas le droit d'écriture sur ce fichier."
        case .folderNotWritable: "Vous n'avez pas le droit d'écriture sur le dossier qui la contient."
        case .readOnlyVolume: "Le volume est en lecture seule (carte verrouillée ou disque monté en lecture seule)."
        case .noTrash: "Ce volume n'a pas de corbeille."
        case .other(let message): message
        }
    }
}
