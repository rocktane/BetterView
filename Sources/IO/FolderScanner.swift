import Foundation

enum FolderScanner {
    /// Lists, stats and sorts a folder. Blocking: runs off the main thread.
    @Sendable
    static func scan(folder: URL, only allowed: Set<String>?) -> [PhotoKey] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        var photos: [PhotoKey] = []
        photos.reserveCapacity(names.count)
        for name in names {
            guard !name.hasPrefix("."),
                  RawFormat.extensions.contains((name as NSString).pathExtension.lowercased())
            else { continue }
            let path = folder.appendingPathComponent(name).path
            if let allowed, !allowed.contains(path) { continue }
            if let key = PhotoKey.read(path: path) { photos.append(key) }
        }
        photos.sort(by: PhotoList.ordered)
        return photos
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
