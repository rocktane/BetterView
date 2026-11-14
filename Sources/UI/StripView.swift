import AppKit
import QuartzCore

struct StripCell {
    enum Mark { case none, current }

    var photo: PhotoKey
    var image: CGImage?
    var mark = Mark.none
    /// A blue check in the corner: it shows on the current photo's white border too.
    var selected = false
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
    /// Some photo is checked: every thumbnail shows a ring to check it with one click.
    private(set) var showsSelectionRings = false
    /// The modifiers held: Shift and Command select rather than go to the photo.
    var onClick: (PhotoKey, NSEvent.ModifierFlags) -> Void = { _, _ in }
    /// The right-click menu for a thumbnail.
    var onMenu: (PhotoKey) -> NSMenu? = { _ in nil }
    var onHoverChanged: () -> Void = {}
    /// Set for a view that scrolls: called with how many photos the swipe carried past the
    /// middle, forward positive. The strip expects to be given them centred.
    var onScroll: ((Int) -> Void)?
    /// Set for a view that moves its window: called with the pointer's travel since the press,
    /// in screen points, then with nil when the drag ends.
    var onDrag: ((CGPoint?) -> Void)?
    /// Set for a view whose window can be stretched: called with the sides pressed (two at a
    /// corner) and the pointer's travel since the press, in screen points, then with nil.
    var onResize: (((sides: StripResize.Sides, travel: CGPoint)?) -> Void)?
    /// The pointer on screen. Read rather than taken from the event: the window moves under it.
    var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }

    /// Changed by a strip stretched taller or shorter: the redraw comes with the new frame.
    var metrics: Metrics {
        didSet {
            // A swipe in progress keeps its place among photos of the new size.
            if oldValue.height > 0 { scrollShift *= metrics.height / oldValue.height }
            needsLayout = true
        }
    }
    private let host = NSView()
    private let content = CALayer()
    private let fade = CAGradientLayer()
    private var images: [CALayer] = []
    private var checks: [CALayer] = []
    private var frames: [CGRect] = []
    private let outlines = CAShapeLayer()
    private var anchor: Int?
    private var groupRanges: [ClosedRange<Int>] = []
    private var groupTips: [String] = []
    private var pressStart: CGPoint?
    private var dragging = false
    /// The side whose grip the press started on, if any: that press stretches the strip.
    private var pressSides: StripResize.Sides?
    private var resizing = false
    private var resizeCursorSides: StripResize.Sides?
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

    /// How many photos each side of the middle one fill `width` even if they are all portrait,
    /// plus one cut by the edge.
    static func reach(width: CGFloat, metrics: Metrics) -> Int {
        let narrowest = (metrics.height * 2 / 3).rounded() + metrics.gap
        return Int((width / 2 / narrowest).rounded(.up)) + 1
    }

    /// For tests: the mark each drawn cell shows in its corner.
    enum CornerMark: Equatable { case none, ring, check }
    var cornerMarks: [CornerMark] {
        cells.indices.map { at in
            guard at < checks.count, !checks[at].isHidden else { return .none }
            return cells[at].selected ? .check : .ring
        }
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
    private static let checkSize: CGFloat = 16
    /// Room around the disc for its shadow, at full size.
    private static let checkMargin: CGFloat = 2

    /// A blue disc with a white check, a thin white ring and a soft shadow, drawn once at
    /// twice its size.
    private static let checkImage: CGImage? = {
        let side = checkSize + 2 * checkMargin
        let pixels = Int(side * 2)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: checkMargin, y: checkMargin)
        // The shadow's offset and blur ignore the scale: they are in pixels.
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.4, color: NSColor(white: 0, alpha: 0.45).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: 16, height: 16))
        context.restoreGState()
        context.setFillColor(NSColor(red: 0.2, green: 0.5, blue: 1, alpha: 1).cgColor)
        context.fillEllipse(in: CGRect(x: 1, y: 1, width: 14, height: 14))
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: 4.6, y: 8.2))
        context.addLine(to: CGPoint(x: 7, y: 5.7))
        context.addLine(to: CGPoint(x: 11.4, y: 10.4))
        context.strokePath()
        return context.makeImage()
    }()

    /// An empty ring in the check's place, shown on every thumbnail once a photo is checked:
    /// white, on a darkened disc and with the same shadow, so that it reads on a light photo
    /// as on a dark one.
    private static let ringImage: CGImage? = {
        let side = checkSize + 2 * checkMargin
        let pixels = Int(side * 2)
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.scaleBy(x: 2, y: 2)
        context.translateBy(x: checkMargin, y: checkMargin)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.4, color: NSColor(white: 0, alpha: 0.45).cgColor)
        context.setFillColor(NSColor(white: 0, alpha: 0.3).cgColor)
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: 16, height: 16))
        context.restoreGState()
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1.5)
        context.strokeEllipse(in: CGRect(x: 0.75, y: 0.75, width: 14.5, height: 14.5))
        return context.makeImage()
    }()

    /// Where the check or the ring sits in a thumbnail of `size`: inside the white border, in
    /// the top right corner.
    private func discFrame(inCellOf size: CGSize) -> CGRect {
        let side = min(Self.checkSize, metrics.height * 0.4)
        let inset: CGFloat = 4
        return CGRect(x: size.width - side - inset, y: size.height - side - inset, width: side, height: side)
    }

    /// How far around a ring a click still checks: the ring is small.
    private static let ringReach: CGFloat = 5

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
    func update(cells: [StripCell], anchor: Int? = nil, cut: (start: Bool, end: Bool) = (false, false), groups ranges: [ClosedRange<Int>] = [], tips: [String] = [], selecting: Bool = false) {
        let previous = (cells: self.cells, anchor: self.anchor)
        showsSelectionRings = selecting
        self.cells = cells
        self.anchor = anchor
        cutAtStart = cut.start
        cutAtEnd = cut.end
        groupRanges = ranges
        groupTips = tips
        carryScroll(from: previous.cells, anchor: previous.anchor)
        redraw()
        updateTips()
        if !scrollGestureActive { settle() }
        onContentChanged()
    }

    /// Called after each update: the width the row needs may have changed.
    var onContentChanged: () -> Void = {}

    /// The width the whole row needs, margins included, with thumbnails `height` points tall,
    /// when it holds every photo of the list; nil when more photos lie beyond an end.
    func fittingWidth(thumbnailHeight height: CGFloat) -> CGFloat? {
        guard !cutAtStart, !cutAtEnd, !cells.isEmpty else { return nil }
        let widths = cells.reduce(0) { $0 + width(of: $1, height: height) }
        return widths + metrics.gap * CGFloat(cells.count - 1) + 2 * inset
    }

    /// A new photo in the middle first leaves the photos where they were, the shift rebased
    /// on a photo both rows share: a swipe goes on under the fingers, and any other move,
    /// deletion of the current photo included, slides there.
    private func carryScroll(from old: [StripCell], anchor oldAnchor: Int?) {
        scrollTarget = nil
        guard let anchor, cells.indices.contains(anchor), let oldAnchor, old.indices.contains(oldAnchor),
              cells[anchor].photo != old[oldAnchor].photo
        else { return }
        // The new middle photo if it was there, else the old one, else any photo kept.
        let candidates = [cells[anchor].photo, old[oldAnchor].photo] + cells.map(\.photo)
        guard let shared = candidates.lazy.compactMap({ photo -> (new: Int, old: Int)? in
            guard let new = self.cells.firstIndex(where: { $0.photo == photo }),
                  let was = old.firstIndex(where: { $0.photo == photo }) else { return nil }
            return (new, was)
        }).first else {
            scrollShift = 0
            return
        }
        // The shared photo keeps its place on screen.
        let before = centres(of: old), after = centres(of: cells)
        scrollShift += (after[anchor] - after[shared.new]) - (before[oldAnchor] - before[shared.old])
    }

    /// Where each cell's centre lies along the row, from the start of the first cell.
    private func centres(of row: [StripCell]) -> [CGFloat] {
        var x: CGFloat = 0
        return row.map { cell in
            let width = width(of: cell)
            defer { x += width + metrics.gap }
            return x + width / 2
        }
    }

    private func centre(of index: Int) -> CGFloat { centres(of: cells)[index] }

    private func width(of cell: StripCell) -> CGFloat { width(of: cell, height: metrics.height) }

    private func width(of cell: StripCell, height: CGFloat) -> CGFloat {
        guard let image = cell.image, image.width > 0, image.height > 0 else { return (height * Self.defaultAspect).rounded() }
        return (height * CGFloat(image.width) / CGFloat(image.height)).rounded()
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
            let check = CALayer()
            check.contents = Self.checkImage
            check.contentsScale = 2
            check.isHidden = true
            check.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
            layer.addSublayer(check)
            checks.append(check)
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
            }
            let check = checks[position]
            // A check on the photos checked, and while any is, an empty ring on the others.
            let marked = cell.selected || showsSelectionRings
            if check.isHidden == marked { check.isHidden = !marked }
            if marked {
                check.contents = cell.selected ? Self.checkImage : Self.ringImage
                let disc = discFrame(inCellOf: frames[position].size)
                let margin = Self.checkMargin * disc.width / Self.checkSize
                check.frame = disc.insetBy(dx: -margin, dy: -margin)
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

    /// Redrawn in the same transaction as the new size: a strip being stretched keeps the
    /// current photo in its middle at every step, with nothing stretched or left blank.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed else { return }
        host.frame = bounds
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
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged()
        updateResizeCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged()
        if !resizing { setResizeCursor(nil) }
    }

    override func mouseMoved(with event: NSEvent) {
        updateResizeCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// The sides whose grips hold `point`: a thin band inside each side, over the faded edges
    /// and the margins around the photos. Near a corner, both sides it joins.
    private func gripSides(at point: CGPoint) -> StripResize.Sides? {
        guard onResize != nil, bounds.contains(point) || point.x == bounds.maxX || point.y == bounds.maxY else { return nil }
        let grip = StripResize.grip, corner = Self.cornerGrip
        let nearX = point.x < grip.width || point.x > bounds.width - grip.width
        let nearY = point.y < grip.height || point.y > bounds.height - grip.height
        guard nearX || nearY else { return nil }
        var sides: StripResize.Sides = []
        if nearX || point.x < corner || point.x > bounds.width - corner {
            sides.insert(point.x < bounds.midX ? .left : .right)
        }
        if nearY || point.y < corner || point.y > bounds.height - corner {
            sides.insert(point.y < bounds.midY ? .bottom : .top)
        }
        return sides
    }

    /// How far from a corner a side's grip takes the other side along: the rounded corner.
    private static let cornerGrip: CGFloat = 14

    private func updateResizeCursor(at point: CGPoint) {
        guard !resizing, pressStart == nil else { return }
        setResizeCursor(gripSides(at: point))
    }

    /// Set by hand: the strip's panel never becomes key, so cursor rects would not apply.
    private func setResizeCursor(_ sides: StripResize.Sides?) {
        guard sides != resizeCursorSides else { return }
        resizeCursorSides = sides
        guard let sides else {
            NSCursor.arrow.set()
            return
        }
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition
            switch (sides.contains(.left), sides.contains(.right), sides.contains(.bottom), sides.contains(.top)) {
            case (true, _, true, _): position = .bottomLeft
            case (true, _, _, true): position = .topLeft
            case (_, true, true, _): position = .bottomRight
            case (_, true, _, true): position = .topRight
            case (true, _, _, _): position = .left
            case (_, true, _, _): position = .right
            case (_, _, true, _): position = .bottom
            default: position = .top
            }
            NSCursor.frameResize(position: position, directions: .all).set()
        } else if sides.isDisjoint(with: [.left, .right]) {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.resizeLeftRight.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragging = false
        resizing = false
        // ⌃-click is a right-click: no selection, no move, no stretch.
        if event.modifierFlags.contains(.control) {
            pressStart = nil
            pressSides = nil
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        pressStart = pointerLocation()
        pressSides = gripSides(at: convert(event.locationInWindow, from: nil))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        cell(at: convert(event.locationInWindow, from: nil)).flatMap { onMenu(cells[$0].photo) }
    }

    private func cell(at point: CGPoint) -> Int? {
        guard point.x >= 0, point.x <= bounds.width else { return nil }
        return frames.firstIndex(where: { $0.insetBy(dx: -metrics.gap / 2, dy: 0).contains(point) })
    }

    /// Dragging from anywhere, thumbnails included, moves the strip: the thumbnails cover most
    /// of it, and a press that does not travel is still a click.
    override func mouseDragged(with event: NSEvent) {
        guard let pressStart else { return }
        let now = pointerLocation()
        let travel = CGPoint(x: now.x - pressStart.x, y: now.y - pressStart.y)
        // From a grip, the press stretches the strip instead of moving it; it still clicks
        // if it does not travel.
        if let pressSides, let onResize {
            if !resizing, hypot(travel.x, travel.y) < 4 { return }
            resizing = true
            onResize((pressSides, travel))
            return
        }
        guard let onDrag else { return }
        if !dragging, hypot(travel.x, travel.y) < 4 { return }
        dragging = true
        onDrag(travel)
    }

    /// Whether `point` falls on the ring or the check of cell `at`, a little around it included.
    private func ringHit(_ at: Int, _ point: CGPoint) -> Bool {
        guard frames.indices.contains(at), showsSelectionRings || cells[at].selected else { return false }
        let disc = discFrame(inCellOf: frames[at].size).offsetBy(dx: frames[at].minX, dy: frames[at].minY)
        return disc.insetBy(dx: -Self.ringReach, dy: -Self.ringReach).contains(point)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressStart != nil else { return }
        defer {
            pressStart = nil
            pressSides = nil
        }
        if resizing {
            resizing = false
            onResize?(nil)
            setResizeCursor(gripSides(at: convert(event.locationInWindow, from: nil)))
            return
        }
        if dragging {
            dragging = false
            onDrag?(nil)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        if let at = cell(at: point) {
            var modifiers = event.modifierFlags.intersection([.shift, .command])
            // On a ring or a check, a plain click checks or unchecks, as Command does.
            if modifiers.isEmpty, ringHit(at, point) { modifiers = .command }
            onClick(cells[at].photo, modifiers)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
