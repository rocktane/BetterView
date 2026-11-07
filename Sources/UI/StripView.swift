import AppKit
import QuartzCore

struct StripCell {
    enum Mark { case none, current, selected }

    var photo: PhotoKey
    var image: CGImage?
    var mark = Mark.none
    var opacity: Float = 0.6
}

/// A row of thumbnails, drawn as layers: updating it costs a few pointer assignments, and it
/// never looks at the file system. Used floating over the desktop and inside the comparison.
final class StripView: NSView {
    struct Metrics {
        var cell: CGSize
        var gap: CGFloat
        var top: CGFloat
    }

    /// `nil` cell positions stay empty, which keeps the current photo in the middle.
    private(set) var cells: [StripCell?] = []
    var onClick: (PhotoKey, _ extending: Bool) -> Void = { _, _ in }
    var onLabelClick: () -> Void = {}
    var onHoverChanged: () -> Void = {}
    /// Set for a view that moves its window: called with the pointer's travel since the press,
    /// in screen points, then with nil when the drag ends.
    var onDrag: ((CGPoint?) -> Void)?

    private let metrics: Metrics
    private let host = NSView()
    private var images: [CALayer] = []
    private let brackets = CAShapeLayer()
    private let label = NSTextField(labelWithString: "")
    private var bracketRanges: [ClosedRange<Int>] = []
    private var labelRange: ClosedRange<Int>?
    private var pressStart: CGPoint?
    private var dragging = false
    private var hoverTracking: NSTrackingArea?

    init(metrics: Metrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
        let root = CALayer()
        host.layer = root
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        brackets.fillColor = nil
        brackets.strokeColor = NSColor(white: 0.55, alpha: 1).cgColor
        brackets.lineWidth = 1
        brackets.actions = ["path": NSNull()]
        root.addSublayer(brackets)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = NSColor(white: 0.75, alpha: 1)
        label.alignment = .center
        label.isHidden = true
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    /// How many thumbnails fit in a width.
    static func capacity(metrics: Metrics, width: CGFloat) -> Int {
        max(1, Int((width + metrics.gap) / (metrics.cell.width + metrics.gap)))
    }

    private var capacity: Int { Self.capacity(metrics: metrics, width: bounds.width) }

    private func slotFrame(_ position: Int) -> CGRect {
        let total = CGFloat(cells.count) * (metrics.cell.width + metrics.gap) - metrics.gap
        let x = ((bounds.width - total) / 2 + CGFloat(position) * (metrics.cell.width + metrics.gap)).rounded()
        return CGRect(x: x, y: bounds.height - metrics.top - metrics.cell.height, width: metrics.cell.width, height: metrics.cell.height)
    }

    /// Every cell keeps the same slot whatever the image's shape, so nothing shifts when a
    /// thumbnail arrives; a portrait photo is simply narrower inside its slot.
    private func imageFrame(_ image: CGImage?, in slot: CGRect) -> CGRect {
        guard let image, image.width > 0, image.height > 0 else { return slot }
        let scale = min(slot.width / CGFloat(image.width), slot.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return CGRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2, width: size.width, height: size.height).integral
    }

    /// Brackets group runs of positions, and `label` is written under `labelRange`.
    func update(cells: [StripCell?], brackets ranges: [ClosedRange<Int>] = [], label text: String? = nil, labelRange: ClosedRange<Int>? = nil) {
        self.cells = cells
        bracketRanges = ranges
        self.labelRange = labelRange
        let isHidden = text == nil
        if label.isHidden != isHidden { label.isHidden = isHidden }
        if let text, label.stringValue != text { label.stringValue = text }
        redraw()
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while images.count < cells.count {
            let layer = CALayer()
            layer.contentsGravity = .resize
            layer.cornerRadius = 2
            layer.masksToBounds = true
            layer.minificationFilter = .trilinear
            layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull()]
            host.layer?.addSublayer(layer)
            images.append(layer)
        }
        for (position, layer) in images.enumerated() {
            guard position < cells.count, let cell = cells[position] else {
                if !layer.isHidden { layer.isHidden = true }
                continue
            }
            if layer.isHidden { layer.isHidden = false }
            layer.frame = imageFrame(cell.image, in: slotFrame(position))
            layer.contents = cell.image
            layer.backgroundColor = cell.image == nil ? NSColor(white: 0.2, alpha: 1).cgColor : nil
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
        for range in bracketRanges {
            let from = slotFrame(range.lowerBound), to = slotFrame(range.upperBound)
            let y = from.minY - 3
            path.move(to: CGPoint(x: from.minX, y: y))
            path.addLine(to: CGPoint(x: from.minX, y: y - 4))
            path.addLine(to: CGPoint(x: to.maxX, y: y - 4))
            path.addLine(to: CGPoint(x: to.maxX, y: y))
        }
        brackets.frame = host.bounds
        brackets.path = path
        CATransaction.commit()
        placeLabel()
    }

    private func placeLabel() {
        guard !label.isHidden else { return }
        label.sizeToFit()
        var size = label.frame.size
        size.width = min(size.width, bounds.width - 16)
        let middle: CGFloat
        if let labelRange, !cells.isEmpty {
            middle = (slotFrame(labelRange.lowerBound).minX + slotFrame(labelRange.upperBound).maxX) / 2
        } else {
            middle = bounds.midX
        }
        let x = min(max(middle - size.width / 2, 8), bounds.width - 8 - size.width)
        let y = bounds.height - metrics.top - metrics.cell.height - 9 - size.height
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
        for (position, cell) in cells.enumerated() where slotFrame(position).contains(point) {
            if let cell { onClick(cell.photo, event.modifierFlags.contains(.shift)) }
            return
        }
    }
}
