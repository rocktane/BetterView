import Foundation

/// The ordered photos and the current position. Pure value type, main-thread owned.
struct PhotoList: Sendable {
    private(set) var photos: [PhotoKey] = []
    private(set) var index: Int?

    var current: PhotoKey? { index.map { photos[$0] } }
    var count: Int { photos.count }

    static func ordered(_ a: PhotoKey, _ b: PhotoKey) -> Bool {
        switch a.name.localizedStandardCompare(b.name) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a.path < b.path
        }
    }

    init(photos: [PhotoKey] = [], selecting path: String? = nil) {
        self.photos = photos
        index = photos.isEmpty ? nil : (path.flatMap { p in photos.firstIndex { $0.path == p } } ?? 0)
    }

    /// Moves to an absolute position, clamped. Returns true when the position changed.
    mutating func move(to target: Int) -> Bool {
        guard !photos.isEmpty else { return false }
        let clamped = min(max(target, 0), photos.count - 1)
        guard clamped != index else { return false }
        index = clamped
        return true
    }

    /// Removes the current photo and lands on its neighbour in the direction of travel.
    mutating func removeCurrent(direction: Int) -> PhotoKey? {
        guard let i = index else { return nil }
        let removed = photos.remove(at: i)
        if photos.isEmpty {
            index = nil
        } else {
            index = direction < 0 ? max(i - 1, 0) : min(i, photos.count - 1)
        }
        return removed
    }

    /// Inserts at the sorted position, replacing a same-path entry. Keeps the current
    /// photo unless `select` is set.
    mutating func insert(_ photo: PhotoKey, select: Bool) {
        let currentPath = current?.path
        photos.removeAll { $0.path == photo.path }
        let at = photos.firstIndex { Self.ordered(photo, $0) } ?? photos.count
        photos.insert(photo, at: at)
        let path = select ? photo.path : (currentPath ?? photo.path)
        index = photos.firstIndex { $0.path == path }
    }

    /// Applies a sorted scan. In-flight deletions stay out of the list, and the current
    /// photo keeps its place by path. Returns true when anything visible changed.
    mutating func merge(scan: [PhotoKey], excluding tombstones: Set<String>, selecting desired: String? = nil) -> Bool {
        let incoming = tombstones.isEmpty ? scan : scan.filter { !tombstones.contains($0.path) }
        let oldCurrent = current
        let oldIndex = index ?? 0
        let oldPhotos = photos
        let path = oldCurrent?.path ?? desired
        photos = incoming
        if incoming.isEmpty {
            index = nil
        } else if let path, let i = incoming.firstIndex(where: { $0.path == path }) {
            index = i
        } else {
            index = min(oldIndex, incoming.count - 1)
        }
        return incoming != oldPhotos || current != oldCurrent
    }
}
