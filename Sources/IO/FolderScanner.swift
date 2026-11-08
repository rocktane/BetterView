import Foundation

/// One scan: the sorted photos, and the protection of those that have one, by path.
struct ScanSnapshot: Sendable {
    var photos: [PhotoKey] = []
    var protection: [String: FileProtection] = [:]
}

enum FolderScanner {
    /// Lists, stats and sorts a folder. Blocking: runs off the main thread.
    @Sendable
    static func scan(folder: URL, only allowed: Set<String>?) -> ScanSnapshot {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var photos: [PhotoKey] = []
        var protection: [String: FileProtection] = [:]
        photos.reserveCapacity(names.count)
        for name in names {
            guard !name.hasPrefix("."),
                  RawFormat.extensions.contains((name as NSString).pathExtension.lowercased())
            else { continue }
            let path = folder.appendingPathComponent(name).path
            if let allowed, !allowed.contains(path) { continue }
            guard let (key, protected) = PhotoKey.readWithProtection(path: path) else { continue }
            photos.append(key)
            if !protected.isEmpty { protection[path] = protected }
        }
        photos.sort(by: PhotoList.ordered)
        return ScanSnapshot(photos: photos, protection: protection)
    }
}

/// Fires on the main queue when a folder's entries change.
@MainActor
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var pendingFire = false

    func watch(_ folder: URL, onChange: @escaping @MainActor () -> Void) {
        stop()
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.pendingFire else { return }
                self.pendingFire = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    MainActor.assumeIsolated {
                        self.pendingFire = false
                        onChange()
                    }
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
