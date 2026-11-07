/// Byte-bounded LRU per tier, main-thread owned.
@MainActor
final class FrameCache {
    struct Budgets: Sendable {
        var preview: Int
        var screen: Int
        var full: Int

        /// 400 MB, 1 GB and 300 MB on a 16 GB machine.
        static func scaled(physicalMemory: UInt64) -> Budgets {
            let ratio = min(2, max(0.5, Double(physicalMemory) / Double(16 << 30)))
            return Budgets(
                preview: Int(400_000_000 * ratio),
                screen: Int(1_000_000_000 * ratio),
                full: Int(300_000_000 * ratio)
            )
        }
    }

    private final class Node {
        let frame: Frame
        var older: Node?
        weak var newer: Node?
        init(_ frame: Frame) { self.frame = frame }
    }

    private struct Shelf {
        var budget: Int
        var bytes = 0
        var nodes: [FrameKey: Node] = [:]
        var newest: Node?
        var oldest: Node?

        mutating func unlink(_ node: Node) {
            if let newer = node.newer { newer.older = node.older } else { newest = node.older }
            if let older = node.older { older.newer = node.newer } else { oldest = node.newer }
            node.older = nil
            node.newer = nil
        }

        mutating func pushNewest(_ node: Node) {
            node.older = newest
            newest?.newer = node
            newest = node
            if oldest == nil { oldest = node }
        }

        mutating func remove(_ node: Node) {
            unlink(node)
            nodes[node.frame.key] = nil
            bytes -= node.frame.byteCost
        }
    }

    private var shelves: [Shelf]
    /// Frames the current plan wants: evicted only when nothing else is left.
    var protected: Set<FrameKey> = []

    init(budgets: Budgets) {
        shelves = [
            Shelf(budget: budgets.preview),
            Shelf(budget: budgets.screen),
            Shelf(budget: budgets.full),
        ]
    }

    func budget(_ tier: Tier) -> Int { shelves[tier.rawValue].budget }
    func bytes(_ tier: Tier) -> Int { shelves[tier.rawValue].bytes }
    var totalBytes: Int { shelves.reduce(0) { $0 + $1.bytes } }

    func contains(_ key: FrameKey) -> Bool { shelves[key.tier.rawValue].nodes[key] != nil }

    func frame(_ key: FrameKey) -> Frame? {
        let i = key.tier.rawValue
        guard let node = shelves[i].nodes[key] else { return nil }
        shelves[i].unlink(node)
        shelves[i].pushNewest(node)
        return node.frame
    }

    /// The best frame for showing a photo. When fitted, a full-size frame is only a
    /// fallback because the screen tier is sharper at that scale.
    func best(_ photo: PhotoKey, zoomed: Bool) -> Frame? {
        let order: [Tier] = zoomed ? [.full, .screen, .preview] : [.screen, .full, .preview]
        for tier in order {
            if let found = frame(FrameKey(photo: photo, tier: tier)) { return found }
        }
        return nil
    }

    func insert(_ frame: Frame, visible: FrameKey? = nil) {
        let i = frame.key.tier.rawValue
        if let existing = shelves[i].nodes[frame.key] { shelves[i].remove(existing) }
        let node = Node(frame)
        shelves[i].nodes[frame.key] = node
        shelves[i].pushNewest(node)
        shelves[i].bytes += frame.byteCost
        trim(i, keeping: visible)
        // The preview has served its purpose once the sharper frame exists.
        if frame.key.tier == .screen {
            remove(FrameKey(photo: frame.key.photo, tier: .preview))
        }
    }

    func remove(_ key: FrameKey) {
        let i = key.tier.rawValue
        if let node = shelves[i].nodes[key] { shelves[i].remove(node) }
    }

    func removeAll(_ tier: Tier) {
        let i = tier.rawValue
        shelves[i].nodes.removeAll()
        // Unlink iteratively so a long chain does not recurse on release.
        var node = shelves[i].oldest
        while let current = node {
            node = current.newer
            current.older = nil
        }
        shelves[i].newest = nil
        shelves[i].oldest = nil
        shelves[i].bytes = 0
    }

    /// Keeps only `keep`, dropping everything else in the tier.
    func retainOnly(_ tier: Tier, keep: Set<FrameKey>) {
        let i = tier.rawValue
        for (key, node) in shelves[i].nodes where !keep.contains(key) {
            shelves[i].remove(node)
        }
    }

    private func trim(_ i: Int, keeping visible: FrameKey?) {
        guard shelves[i].bytes > shelves[i].budget else { return }
        // First pass: anything the plan does not want, oldest first.
        var node = shelves[i].oldest
        while shelves[i].bytes > shelves[i].budget, let current = node {
            node = current.newer
            if !protected.contains(current.frame.key) && current.frame.key != visible {
                shelves[i].remove(current)
            }
        }
        // Second pass: over budget even so, the budget wins over the plan.
        node = shelves[i].oldest
        while shelves[i].bytes > shelves[i].budget, let current = node {
            node = current.newer
            if current.frame.key != visible { shelves[i].remove(current) }
        }
    }
}
