import AppKit
import QuartzCore

struct StripCell {
    enum Mark { case none, current, selected }

    var photo: PhotoKey
    var image: CGImage?
    var mark = Mark.none
    var opacity: Float = 0.7
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
    var onLabelClick: () -> Void = {}
    var onHoverChanged: () -> Void = {}
    /// Set for a view that moves its window: called with the pointer's travel since the press,
    /// in screen points, then with nil when the drag ends.
    var onDrag: ((CGPoint?) -> Void)?

    private let metrics: Metrics
    private let host = NSView()
    private let content = CALayer()
    private let fade = CAGradientLayer()
    private var images: [CALayer] = []
    private var frames: [CGRect] = []
    private let brackets = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private var anchor: Int?
    private var bracketRanges: [ClosedRange<Int>] = []
    private var labelRange: ClosedRange<Int>?
    private var pressStart: CGPoint?
    private var dragging = false
    private var hoverTracking: NSTrackingArea?

    /// Space kept between the first or last photo of the list and the edge.
    private static let inset: CGFloat = 10
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

    /// For tests: where each cell is drawn.
    var cellFrames: [CGRect] { frames }

    /// Shape of a thumbnail that has not arrived yet: the most common one.
    private static let defaultAspect: CGFloat = 1.5

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
        brackets.fillColor = nil
        brackets.strokeColor = NSColor(white: 0.6, alpha: 1).cgColor
        brackets.lineWidth = 1
        brackets.actions = ["path": NSNull()]
        content.addSublayer(brackets)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = NSColor(white: 0.78, alpha: 1)
        label.alignment = .center
        label.isHidden = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    /// `anchor` stays in the middle, so that moving along slides the strip under a fixed
    /// highlight. Without one, a row that fits is centred as a whole. Brackets group runs of
    /// cells, and `label` is written under `labelRange`.
    func update(cells: [StripCell], anchor: Int? = nil, cut: (start: Bool, end: Bool) = (false, false), brackets ranges: [ClosedRange<Int>] = [], label text: String? = nil, labelRange: ClosedRange<Int>? = nil) {
        self.cells = cells
        self.anchor = anchor
        cutAtStart = cut.start
        cutAtEnd = cut.end
        bracketRanges = ranges
        self.labelRange = labelRange
        let isHidden = text == nil
        if label.isHidden != isHidden { label.isHidden = isHidden }
        if let text, label.stringValue != text { label.stringValue = text }
        redraw()
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
        // The anchor stays in the middle, except near the ends of the list, where the strip stops
        // scrolling rather than leave half of itself empty.
        if let anchor, cells.indices.contains(anchor), total > bounds.width - 2 * Self.inset {
            let before = widths[..<anchor].reduce(0, +) + metrics.gap * CGFloat(anchor)
            let centred = bounds.midX - widths[anchor] / 2 - before
            let first = Self.inset, last = bounds.width - Self.inset - total
            // A cut list end (more photos beyond the cells given) may scroll past the edge.
            x = min(max(centred, cutAtEnd ? -.infinity : last), cutAtStart ? .infinity : first)
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
            layer.cornerRadius = 3
            layer.masksToBounds = true
            layer.minificationFilter = .trilinear
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(), "hidden": NSNull()]
            content.insertSublayer(layer, below: brackets)
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
        let path = CGMutablePath()
        for range in bracketRanges where frames.indices.contains(range.lowerBound) && frames.indices.contains(range.upperBound) {
            let from = frames[range.lowerBound], to = frames[range.upperBound]
            let y = from.minY - 3
            path.move(to: CGPoint(x: from.minX + 1, y: y))
            path.addLine(to: CGPoint(x: from.minX + 1, y: y - 3))
            path.addLine(to: CGPoint(x: to.maxX - 1, y: y - 3))
            path.addLine(to: CGPoint(x: to.maxX - 1, y: y))
        }
        brackets.frame = content.bounds
        brackets.path = path
        CATransaction.commit()
        placeLabel()
    }

    private func placeLabel() {
        guard !label.isHidden else { return }
        label.sizeToFit()
        var size = label.frame.size
        size.width = min(size.width, bounds.width - 16)
        var middle = bounds.midX
        if let labelRange, frames.indices.contains(labelRange.lowerBound), frames.indices.contains(labelRange.upperBound) {
            middle = (frames[labelRange.lowerBound].minX + frames[labelRange.upperBound].maxX) / 2
        }
        let x = min(max(middle - size.width / 2, 12), bounds.width - 12 - size.width)
        let y = bounds.height - metrics.top - metrics.height - 6 - size.height
        label.frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
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
        if !label.isHidden, label.frame.contains(point) {
            onLabelClick()
            return
        }
        if let at = frames.firstIndex(where: { $0.insetBy(dx: -metrics.gap / 2, dy: 0).contains(point) }), point.x >= 0, point.x <= bounds.width {
            onClick(cells[at].photo, event.modifierFlags.contains(.shift))
        }
    }
}
