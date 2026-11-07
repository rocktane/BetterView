enum MemoryLevel: Sendable {
    case normal, warning, critical
}

struct PlanInput: Sendable {
    var count: Int
    var current: Int
    var direction = 1
    /// A navigation key is held down.
    var repeating = false
    /// The current photo has been on screen for a short moment.
    var settled = true
    /// The current photo has been on screen long enough to expect a zoom.
    var focused = false
    var zoomed = false
    /// The user is idle and the machine can afford background rendering.
    var idle = false
    var memory = MemoryLevel.normal
    var screenAhead = 20
    var screenBehind = 8
    var previewRadius = 25
}

struct PlanItem: Equatable, Sendable {
    let index: Int
    let tier: Tier
    /// The photo on screen is waiting for this: it may use the reserved GPU slot.
    var visible = false
    /// Goes to the disk cache only and never to memory.
    var background = false
}

/// Pure function from the position to the ordered work wanted right now.
enum WindowPlanner {
    static func plan(_ input: PlanInput) -> [PlanItem] {
        guard input.count > 0, input.current >= 0, input.current < input.count else { return [] }
        var builder = Builder(input: input)
        let current = input.current

        // 1. What the photo on screen is waiting for.
        builder.add(current, .preview, visible: true)
        if !input.repeating || input.settled {
            builder.add(current, .screen, visible: true)
        }
        if input.zoomed && !input.repeating {
            builder.add(current, .full, visible: true)
        }
        if input.memory == .critical { return builder.items }

        let limited = input.memory == .warning
        let previewRadius = limited ? min(3, input.previewRadius) : input.previewRadius
        let ahead = limited ? min(3, input.screenAhead) : input.screenAhead
        let behind = limited ? min(3, input.screenBehind) : input.screenBehind

        // Scrolling through a held key only needs previews.
        if input.repeating {
            builder.addAround(current, tier: .preview, ahead: previewRadius, behind: previewRadius)
            return builder.items
        }

        // 2. The immediate neighbours, 3. previews, 4. the screen window.
        builder.add(current + input.direction, .screen)
        builder.add(current - input.direction, .screen)
        // Staying on a photo announces a focus check: that beats preparing distant photos.
        if input.focused && !limited { builder.add(current, .full) }
        builder.addAround(current, tier: .preview, ahead: previewRadius, behind: previewRadius)
        builder.addAround(current, tier: .screen, ahead: ahead, behind: behind)

        // 5. Full resolution, ready for checking focus.
        if input.zoomed {
            builder.add(current + input.direction, .full)
            builder.add(current - input.direction, .full)
        } else if input.focused && !limited {
            builder.add(current + input.direction, .full)
        }

        // 6. Fill the disk cache with the rest of the folder.
        if input.idle && input.memory == .normal {
            builder.addRest(current)
        }
        return builder.items
    }

    private struct Builder {
        let input: PlanInput
        var items: [PlanItem] = []
        private var seen: Set<Int> = []

        init(input: PlanInput) {
            self.input = input
            items.reserveCapacity(128)
        }

        mutating func add(_ index: Int, _ tier: Tier, visible: Bool = false, background: Bool = false) {
            guard index >= 0, index < input.count else { return }
            guard seen.insert(index &* 4 &+ tier.rawValue).inserted else { return }
            items.append(PlanItem(index: index, tier: tier, visible: visible, background: background))
        }

        /// Nearest first, favouring the direction of travel.
        mutating func addAround(_ center: Int, tier: Tier, ahead: Int, behind: Int) {
            for distance in 1...max(ahead, behind, 1) {
                if distance <= ahead { add(center + distance * input.direction, tier) }
                if distance <= behind { add(center - distance * input.direction, tier) }
            }
        }

        mutating func addRest(_ center: Int) {
            for distance in 1..<max(input.count, 2) {
                add(center + distance * input.direction, .screen, background: true)
                add(center - distance * input.direction, .screen, background: true)
            }
        }
    }
}
