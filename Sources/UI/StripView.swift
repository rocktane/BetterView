import AppKit
import QuartzCore

struct StripCell {
    enum Mark { case none, current, selected }

    var photo: PhotoKey
    var image: CGImage?
    var mark = Mark.none
    var opacity: Float = 1
}

/// A strip of thumbnails laid end to end, each as wide as its photo's shape, drawn as layers:
/// updating it costs a few pointer assignments, and it never looks at the file system. Used
/// floating over the desktop and inside the comparison.
final class StripView: NSView {
    struct Metrics {
        /// Every thumbnail has this height; its width follows the photo.
        var height: CGFloat
        var gap: CGFloat
        var top: CGFloat
        /// Thumbnails cut by an edge fade out rather than stop dead.
        var fadesEdges: Bool
    }

    private(set) var cells: [StripCell] = []
    var onClick: (PhotoKey, _ extending: Bool) -> Void = { _, _ in }
    var onHoverChanged: () -> Void = {}
    /// Set for a view that scrolls: called with how many photos the swipe carried past the
    /// middle, forward positive. The strip expects to be given them centred.
    var onScroll: ((Int) -> Void)?
    /// Set for a view that moves its window: called with the pointer's travel since the press,
    /// in screen points, then with nil when the drag ends.
    var onDrag: ((CGPoint?) -> Void)?

    private let metrics: Metrics
    private let host = NSView()
    private let content = CALayer()
    private let fade = CAGradientLayer()
    private var images: [CALayer] = []
    private var frames: [CGRect] = []
    private let outlines = CAShapeLayer()
    private var anchor: Int?
    private var groupRanges: [ClosedRange<Int>] = []
    private var groupTips: [String] = []
    private var pressStart: CGPoint?
    private var dragging = false
    private var hoverTracking: NSTrackingArea?
    /// How far a swipe has carried the photos from their place, in points, right positive.
    private var scrollShift: CGFloat = 0
    /// The photo a scroll step asked for, until the strip is given it.
    private var scrollTarget: PhotoKey?
    private var scrollGestureActive = false
    private var settleTimer: Timer?
    private var lastSettle: CFTimeInterval = 0
    private static let settleTime: CFTimeInterval = 0.045
    /// The shifts that still move the photos: past them, the row stops at an end of the list.
    private var shiftRange: ClosedRange<CGFloat> = 0...0

    /// Space kept between the first or last photo of the list and the edge: the same as above
    /// and below the photos.
    private var inset: CGFloat { metrics.top }
    /// More photos exist beyond the first or last cell given: no need to stop at that end.
    private var cutAtStart = false
    private var cutAtEnd = false

    /// The photos to give the strip: always `2 * reach + 1` when the list has them, taken from the
    /// other side near an end, so that portrait photos still fill it there.
    static func window(around index: Int, count: Int, reach: Int) -> ClosedRange<Int> {
        let size = min(2 * reach + 1, count)
        let lower = min(max(index - reach, 0), count - size)
        return lower...(lower + size - 1)
    }

    /// For tests: where each cell is drawn, and the outer edge of the group outlines.
    var cellFrames: [CGRect] { frames }
    var outlineFrame: CGRect? {
        outlines.path.map { $0.boundingBox.insetBy(dx: -outlines.lineWidth / 2, dy: -outlines.lineWidth / 2) }
    }

    /// Shape of a thumbnail that has not arrived yet: the most common one.
    private static let defaultAspect: CGFloat = 1.5
    private static let cornerRadius: CGFloat = 3
    /// The outline of a group runs in the gap around it: this far from the photos, and this
    /// thick, so that it never reaches a neighbour across a gap.
    private static let outlineOffset: CGFloat = 1
    private static let outlineWidth: CGFloat = 1.5

    init(metrics: Metrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        host.layer = root
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        content.actions = ["bounds": NSNull(), "position": NSNull()]
        root.addSublayer(content)
        if metrics.fadesEdges {
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.actions = ["bounds": NSNull(), "position": NSNull(), "locations": NSNull()]
            content.mask = fade
        }
        outlines.fillColor = nil
        outlines.strokeColor = NSColor(white: 0.72, alpha: 1).cgColor
        outlines.lineWidth = Self.outlineWidth
        outlines.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        content.addSublayer(outlines)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    /// `anchor` stays in the middle, so that moving along slides the strip under a fixed
    /// highlight. Without one, a row that fits is centred as a whole. Each group of cells is
    /// outlined as one, and its tip shows when the pointer rests on it.
    func update(cells: [StripCell], anchor: Int? = nil, cut: (start: Bool, end: Bool) = (false, false), groups ranges: [ClosedRange<Int>] = [], tips: [String] = []) {
        let previous = self.anchor.flatMap { self.cells.indices.contains($0) ? self.cells[$0].photo : nil }
        self.cells = cells
        self.anchor = anchor
        cutAtStart = cut.start
        cutAtEnd = cut.end
        groupRanges = ranges
        groupTips = tips
        carryScroll(from: previous)
        redraw()
        updateTips()
        if !scrollGestureActive { settle() }
    }

    /// A new photo in the middle first leaves the photos where they were, the shift rebased
    /// on it: a swipe goes on under the fingers, and any other move slides there.
    private func carryScroll(from previous: PhotoKey?) {
        scrollTarget = nil
        guard let anchor, cells.indices.contains(anchor), let previous, cells[anchor].photo != previous else { return }
        guard let from = cells.firstIndex(where: { $0.photo == previous }) else {
            scrollShift = 0
            return
        }
        scrollShift += centre(of: anchor) - centre(of: from)
    }

    /// Where a cell's centre lies along the row, from the start of the first cell.
    private func centre(of index: Int) -> CGFloat {
        let widths = cells.map(width(of:))
        return widths[..<index].reduce(0, +) + metrics.gap * CGFloat(index) + widths[index] / 2
    }

    private func width(of cell: StripCell) -> CGFloat {
        guard let image = cell.image, image.width > 0, image.height > 0 else { return (metrics.height * Self.defaultAspect).rounded() }
        return (metrics.height * CGFloat(image.width) / CGFloat(image.height)).rounded()
    }

    private func layoutFrames() {
        let widths = cells.map(width(of:))
        let total = widths.reduce(0, +) + metrics.gap * CGFloat(max(cells.count - 1, 0))
        let y = bounds.height - metrics.top - metrics.height
        var x = (bounds.width - total) / 2
        shiftRange = 0...0
        // The anchor stays in the middle, except near the ends of the list, where the strip stops
        // scrolling rather than leave half of itself empty.
        if let anchor, cells.indices.contains(anchor), total > bounds.width - 2 * inset {
            let before = widths[..<anchor].reduce(0, +) + metrics.gap * CGFloat(anchor)
            let centred = bounds.midX - widths[anchor] / 2 - before
            let first = inset, last = bounds.width - inset - total
            // A cut list end (more photos beyond the cells given) may scroll past the edge.
            let lowest = cutAtEnd ? -CGFloat.infinity : last, highest = cutAtStart ? CGFloat.infinity : first
            shiftRange = (lowest - centred)...(highest - centred)
            x = min(max(centred + scrollShift, lowest), highest)
            // Only what shows is kept: nothing gathers past an end, to be undone before the
            // photos move again.
            scrollShift = x - centred
        } else {
            scrollShift = 0
        }
        frames = widths.map { width in
            defer { x += width + metrics.gap }
            return CGRect(x: x.rounded(), y: y, width: width, height: metrics.height)
        }
    }

    private func redraw() {
        layoutFrames()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = host.bounds
        if metrics.fadesEdges {
            fade.frame = content.bounds
            let edge = min(0.12, 28 / max(bounds.width, 1))
            // Only an edge that cuts a thumbnail fades: the first or last photo stays whole.
            let cutLeft = (frames.first?.minX ?? 0) < 0
            let cutRight = (frames.last?.maxX ?? 0) > bounds.width
            fade.colors = [
                (cutLeft ? NSColor.clear : NSColor.black).cgColor, NSColor.black.cgColor,
                NSColor.black.cgColor, (cutRight ? NSColor.clear : NSColor.black).cgColor,
            ]
            fade.locations = [0, NSNumber(value: Double(edge)), NSNumber(value: Double(1 - edge)), 1]
        }
        while images.count < cells.count {
            let layer = CALayer()
            layer.contentsGravity = .resizeAspectFill
            layer.cornerRadius = Self.cornerRadius
            layer.masksToBounds = true
            layer.minificationFilter = .trilinear
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
            content.insertSublayer(layer, below: outlines)
            images.append(layer)
        }
        for (position, layer) in images.enumerated() {
            guard position < cells.count, frames[position].maxX > 0, frames[position].minX < bounds.width else {
                if !layer.isHidden { layer.isHidden = true }
                continue
            }
            let cell = cells[position]
            if layer.isHidden { layer.isHidden = false }
            layer.frame = frames[position]
            layer.contents = cell.image
            layer.backgroundColor = cell.image == nil ? NSColor(white: 0.22, alpha: 1).cgColor : nil
            layer.opacity = cell.opacity
            switch cell.mark {
            case .none:
                layer.borderWidth = 0
            case .current:
                layer.borderWidth = 2
                layer.borderColor = NSColor.white.cgColor
            case .selected:
                layer.borderWidth = 2
                layer.borderColor = NSColor(red: 0.42, green: 0.66, blue: 1, alpha: 1).cgColor
            }
        }
        // One rounded outline around each group, concentric with the thumbnails' corners.
        let path = CGMutablePath()
        let ring = Self.outlineOffset + Self.outlineWidth / 2
        for rect in groupRects() {
            path.addRoundedRect(in: rect.insetBy(dx: -ring, dy: -ring), cornerWidth: Self.cornerRadius + ring, cornerHeight: Self.cornerRadius + ring)
        }
        outlines.frame = content.bounds
        outlines.path = path
        CATransaction.commit()
    }

    /// The span of each group's cells.
    private func groupRects() -> [CGRect] {
        groupRanges.compactMap { range in
            guard frames.indices.contains(range.lowerBound), frames.indices.contains(range.upperBound) else { return nil }
            return frames[range.lowerBound].union(frames[range.upperBound])
        }
    }

    private func updateTips() {
        removeAllToolTips()
        for (rect, tip) in zip(groupRects(), groupTips) {
            addToolTip(rect.intersection(bounds), owner: tip as NSString, userData: nil)
        }
    }

    override func layout() {
        super.layout()
        redraw()
        updateTips()
    }

    // MARK: Scrolling

    /// A swipe slides the photos under the fingers; past halfway to a neighbour, that photo
    /// becomes the current one. A mouse wheel moves one photo per notch.
    override func scrollWheel(with event: NSEvent) {
        guard let onScroll, let anchor, cells.indices.contains(anchor) else {
            super.scrollWheel(with: event)
            return
        }
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        let delta = abs(dx) >= abs(dy) ? dx : dy
        guard event.hasPreciseScrollingDeltas else {
            if delta != 0 { onScroll(delta < 0 ? 1 : -1) }
            return
        }
        if event.phase == .began || event.momentumPhase == .began {
            settleTimer?.invalidate()
            settleTimer = nil
            scrollGestureActive = true
        }
        scrollShift = (scrollShift + delta).clamped(to: shiftRange)
        // Every photo whose centre the swipe passed halfway to, at once; the next asks wait
        // for the strip to be given the photo asked for.
        if scrollTarget == nil {
            var to = anchor
            while to < cells.count - 1, -scrollShift > centre(of: to) - centre(of: anchor) + (centre(of: to + 1) - centre(of: to)) / 2 { to += 1 }
            while to > 0, scrollShift > centre(of: anchor) - centre(of: to) + (centre(of: to) - centre(of: to - 1)) / 2 { to -= 1 }
            if to != anchor {
                scrollTarget = cells[to].photo
                onScroll(to - anchor)
            }
        }
        redraw()
        let ended = event.momentumPhase == .ended || event.momentumPhase == .cancelled
            || (event.momentumPhase == [] && (event.phase == .ended || event.phase == .cancelled))
        if ended { settle() }
    }

    /// Brings the nearest photo to the middle once the fingers let go. A momentum phase that
    /// follows the release takes over again.
    private func settle() {
        scrollGestureActive = false
        guard settleTimer == nil, abs(scrollShift - restingShift) >= 0.5 else { return }
        lastSettle = CACurrentMediaTime()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleStep() }
        }
    }

    /// The current photo in the middle, or as near as the ends of the list allow.
    private var restingShift: CGFloat { CGFloat(0).clamped(to: shiftRange) }

    private func settleStep() {
        guard !scrollGestureActive else {
            settleTimer?.invalidate()
            settleTimer = nil
            return
        }
        // An exponential ease, whatever the frame rate: about 0.2 s for a whole photo.
        let now = CACurrentMediaTime()
        let elapsed = now - lastSettle
        lastSettle = now
        let rest = restingShift
        scrollShift = rest + (scrollShift - rest) * CGFloat(exp(-elapsed / Self.settleTime))
        if abs(scrollShift - rest) < 0.5 {
            scrollShift = rest
            settleTimer?.invalidate()
            settleTimer = nil
        }
        redraw()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged() }
    override func mouseExited(with event: NSEvent) { onHoverChanged() }

    override func mouseDown(with event: NSEvent) {
        pressStart = NSEvent.mouseLocation
        dragging = false
    }

    /// Dragging from anywhere, thumbnails included, moves the strip: the thumbnails cover most
    /// of it, and a press that does not travel is still a click.
    override func mouseDragged(with event: NSEvent) {
        guard let onDrag, let pressStart else { return }
        let now = NSEvent.mouseLocation
        let travel = CGPoint(x: now.x - pressStart.x, y: now.y - pressStart.y)
        if !dragging, hypot(travel.x, travel.y) < 4 { return }
        dragging = true
        onDrag(travel)
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressStart = nil }
        if dragging {
            dragging = false
            onDrag?(nil)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let at = frames.firstIndex(where: { $0.insetBy(dx: -metrics.gap / 2, dy: 0).contains(point) }), point.x >= 0, point.x <= bounds.width {
            onClick(cells[at].photo, event.modifierFlags.contains(.shift))
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
