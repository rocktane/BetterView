import Foundation

/// The photos picked to compare or delete together, by path, as in the Finder: Shift extends
/// a run from an anchor, Command (or S) adds or removes one photo. Moving without a modifier
/// keeps the selection, but the next run starts from where the user then is.
struct PhotoSelection: Equatable, Sendable {
    private(set) var paths: Set<String> = []
    /// Where the current run started, and what was selected besides it: going back towards
    /// the anchor shrinks the run instead of keeping everything it passed.
    private var anchor: (path: String, base: Set<String>)?

    static func == (a: PhotoSelection, b: PhotoSelection) -> Bool {
        a.paths == b.paths && a.anchor?.path == b.anchor?.path && a.anchor?.base == b.anchor?.base
    }

    var isEmpty: Bool { paths.isEmpty }
    func contains(_ photo: PhotoKey) -> Bool { paths.contains(photo.path) }

    /// The selected photos still in the list, in its order.
    func photos(in list: [PhotoKey]) -> [PhotoKey] {
        paths.isEmpty ? [] : list.filter { paths.contains($0.path) }
    }

    /// Selects every photo from the anchor to `target`, the anchor being `current` when no
    /// run is going on. The rest of the selection stays.
    mutating func extend(from current: Int, to target: Int, in list: [PhotoKey]) {
        guard list.indices.contains(current), list.indices.contains(target) else { return }
        let start: Int
        if let anchor, let at = list.firstIndex(where: { $0.path == anchor.path }) {
            start = at
        } else {
            anchor = (list[current].path, paths)
            start = current
        }
        let run = list[min(start, target)...max(start, target)].map(\.path)
        paths = (anchor?.base ?? []).union(run)
    }

    /// Adds or removes one photo. An added photo starts the next run.
    mutating func toggle(_ photo: PhotoKey) {
        if paths.remove(photo.path) != nil {
            anchor = nil
        } else {
            anchor = (photo.path, paths)
            paths.insert(photo.path)
        }
    }

    /// The user moved without extending: the selection stays, the next run starts afresh.
    mutating func endRun() { anchor = nil }

    mutating func clear() {
        paths = []
        anchor = nil
    }
}
