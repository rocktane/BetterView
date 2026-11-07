import Foundation

/// Finds photos taken in one go, from their capture time alone: predictable, and nothing to
/// compute from the pixels.
enum PhotoGroups {
    /// EXIF times have a one-second resolution, so this is about one second apart at most.
    static let burstGap: TimeInterval = 2

    /// The runs of at least two consecutive photos taken close together. A photo without a date
    /// breaks the run.
    static func bursts(dates: [Date?]) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for index in dates.indices {
            let linked = index > 0 && {
                guard let before = dates[index - 1], let date = dates[index] else { return false }
                return abs(date.timeIntervalSince(before)) <= burstGap
            }()
            if !linked {
                if let start, index - 1 > start { runs.append(start...(index - 1)) }
                start = index
            }
        }
        if let start, dates.count - 1 > start { runs.append(start...(dates.count - 1)) }
        return runs
    }
}

/// Which photos are being compared, and where each one sits. Removing a photo puts the next
/// waiting one in its slot, so the others do not move and the eye keeps its bearings.
struct ComparisonModel: Equatable, Sendable {
    static let slotCount = 4

    /// Everything that entered the comparison, in order, gone or not.
    private(set) var members: [PhotoKey]
    private(set) var slots: [PhotoKey?]
    private(set) var waiting: [PhotoKey]
    private(set) var focus = 0
    /// Where each removed photo was, for when a deletion is undone.
    private var homes: [String: Int] = [:]

    init?(photos: [PhotoKey], focusing focused: PhotoKey?) {
        guard photos.count >= 2 else { return nil }
        members = photos
        var shown: [PhotoKey?] = Array(photos.prefix(Self.slotCount))
        shown += Array(repeating: nil, count: Self.slotCount - shown.count)
        slots = shown
        waiting = Array(photos.dropFirst(Self.slotCount))
        if let focused, let at = slots.firstIndex(of: focused) { focus = at }
    }

    var shown: [PhotoKey] { slots.compactMap { $0 } }
    var focused: PhotoKey? { slots[focus] }
    var remaining: Int { shown.count + waiting.count }

    /// Slots to draw, in reading order. Up to two photos share the whole space; three keep the
    /// 2 x 2 grid and an empty cell, so losing one of four moves nothing.
    var layout: [Int] {
        let filled = slots.indices.filter { slots[$0] != nil }
        return filled.count <= 2 ? filled : Array(slots.indices)
    }

    /// Photos in a slot, focus aside: what "keep this one" removes. Waiting photos stay out of
    /// it, since they have not been seen yet.
    var shownOthers: [PhotoKey] { shown.filter { $0 != focused } }

    mutating func moveFocus(by delta: Int) {
        let filled = slots.indices.filter { slots[$0] != nil }
        guard let at = filled.firstIndex(of: focus), !filled.isEmpty else { return }
        focus = filled[(at + delta % filled.count + filled.count) % filled.count]
    }

    mutating func setFocus(slot: Int) {
        guard slots.indices.contains(slot), slots[slot] != nil else { return }
        focus = slot
    }

    mutating func remove(_ photos: [PhotoKey]) {
        for photo in photos {
            guard let at = slots.firstIndex(of: photo) else {
                waiting.removeAll { $0 == photo }
                continue
            }
            homes[photo.path] = at
            slots[at] = waiting.isEmpty ? nil : waiting.removeFirst()
        }
        refocus()
    }

    /// Puts a photo back where it was. Whatever took the slot in the meantime moves to an empty
    /// one, or back to its place in the waiting line, so the result does not depend on the
    /// order of the restorations. Returns false for a photo this comparison did not remove.
    @discardableResult
    mutating func restore(_ photo: PhotoKey) -> Bool {
        guard let home = homes.removeValue(forKey: photo.path) else { return false }
        if let at = members.firstIndex(where: { $0.path == photo.path }) { members[at] = photo }
        if let occupant = slots[home] {
            if let empty = slots.firstIndex(of: nil) {
                slots[empty] = occupant
            } else {
                waiting.append(occupant)
                var order: [String: Int] = [:]
                for (at, member) in members.enumerated() { order[member.path] = at }
                waiting.sort { (order[$0.path] ?? 0) < (order[$1.path] ?? 0) }
            }
        }
        slots[home] = photo
        refocus()
        return true
    }

    /// Follows the folder: a photo replaced on disk gets its new revision, and one that
    /// disappeared leaves. A removed photo back in the list returns to its slot, whatever
    /// brought it back: an undo, a failed deletion, or a file that had changed and was kept.
    mutating func reconcile(with list: [PhotoKey]) {
        var current: [String: PhotoKey] = [:]
        for photo in list { current[photo.path] = photo }
        for path in homes.keys.sorted() {
            if let back = current[path] { restore(back) }
        }
        for at in members.indices {
            if let updated = current[members[at].path] { members[at] = updated }
        }
        waiting = waiting.compactMap { current[$0.path] }
        for at in slots.indices {
            guard let photo = slots[at] else { continue }
            if let updated = current[photo.path] {
                slots[at] = updated
            } else {
                slots[at] = waiting.isEmpty ? nil : waiting.removeFirst()
            }
        }
        refocus()
    }

    private mutating func refocus() {
        guard slots[focus] == nil else { return }
        focus = slots.indices.first { slots[$0] != nil } ?? 0
    }
}
