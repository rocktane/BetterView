import Foundation

/// Identifies one revision of a file. Replacing or editing the file changes the key,
/// so anything derived from the old pixels stops matching on its own.
struct PhotoKey: Hashable, Sendable {
    let path: String
    let device: Int64
    let inode: UInt64
    let size: Int64
    let mtimeSeconds: Int
    let mtimeNanoseconds: Int

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { (path as NSString).lastPathComponent }

    /// Reads the current on-disk revision. Blocking: never call from the main thread.
    static func read(path: String) -> PhotoKey? {
        readWithInfo(path: path)?.key
    }

    /// The revision and its protection from a single `stat`. Blocking: never on the main thread.
    static func readWithProtection(path: String) -> (key: PhotoKey, protection: FileProtection)? {
        guard let (key, info) = readWithInfo(path: path) else { return nil }
        return (key, FileProtection(path: path, info: info))
    }

    private static func readWithInfo(path: String) -> (key: PhotoKey, info: stat)? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let key = PhotoKey(
            path: path,
            device: Int64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mtimeSeconds: info.st_mtimespec.tv_sec,
            mtimeNanoseconds: info.st_mtimespec.tv_nsec
        )
        return (key, info)
    }
}

enum Tier: Int, Sendable, Comparable {
    case preview, screen, full
    static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
}

struct FrameKey: Hashable, Sendable {
    let photo: PhotoKey
    let tier: Tier
}
