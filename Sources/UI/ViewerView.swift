import AppKit
import QuartzCore

enum ViewerCommand {
    case next(repeating: Bool), previous(repeating: Bool), first, last
    case delete
    case toggleZoom, toggleFullScreen, toggleInfo
    /// 100 % on the AF position the camera recorded.
    case zoomToFocus
    case exitZoom
    case keyReleased
    case openDropped([URL])
    case zoomChanged
}

/// Shows one IOSurface in a layer and handles geometry and input. No app logic here.
final class ViewerView: NSView {
    var onCommand: (ViewerCommand) -> Void = { _ in }

    /// nil is fit-to-window. Otherwise 1.0 means one image pixel per screen pixel.
    private(set) var zoom: CGFloat?
    /// Image point kept at the centre of the view, normalised, y up.
    private var center = CGPoint(x: 0.5, y: 0.5)
    private var nativeSize: CGSize = .zero
    private var shownSurface: IOSurface?
    /// The user dragged or scrolled since the view was last centred by code.
    private(set) var movedByUser = false
    /// Normalised, y down, nil when hidden.
    private var focusMarker: CGPoint?
    private var focusNote: String?
    private var tierBadge: String?

    private let host = NSView()
    private let imageLayer = CALayer()
    /// A thin ring: it marks where the camera aimed, nothing about sharpness.
    private let markerLayer = CALayer()
    private static let markerSize: CGFloat = 22
    private let messageLabel = ViewerView.label(size: 15, weight: .medium)
    private let badgeLabel = ViewerView.label(size: 11, weight: .semibold)
    private let infoLabel = ViewerView.label(size: 12, weight: .regular)

    var isZoomed: Bool { zoom != nil }

    private static func label(size: CGFloat, weight: NSFont.Weight) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = NSColor(white: 1, alpha: 0.85)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        label.drawsBackground = false
        label.shadow = {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.8)
            shadow.shadowBlurRadius = 3
            shadow.shadowOffset = .zero
            return shadow
        }()
        return label
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        layerContentsRedrawPolicy = .never

        // A layer-hosting subview: AppKit never touches this layer tree.
        let root = CALayer()
        host.layer = root
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.addSublayer(imageLayer)
        markerLayer.bounds = CGRect(x: 0, y: 0, width: Self.markerSize, height: Self.markerSize)
        markerLayer.cornerRadius = Self.markerSize / 2
        markerLayer.borderWidth = 1.5
        markerLayer.borderColor = NSColor(white: 1, alpha: 0.75).cgColor
        markerLayer.shadowColor = NSColor.black.cgColor
        markerLayer.shadowOpacity = 0.8
        markerLayer.shadowRadius = 1.5
        markerLayer.shadowOffset = .zero
        markerLayer.isHidden = true
        markerLayer.actions = ["position": NSNull(), "hidden": NSNull()]
        root.addSublayer(markerLayer)

        for label in [messageLabel, badgeLabel, infoLabel] { addSubview(label) }
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badgeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            infoLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            infoLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Showing

    /// Hands the surface to the layer without copying it, and pushes it out immediately.
    func show(_ frame: Frame) {
        if frame.surface !== shownSurface {
            shownSurface = frame.surface
            nativeSize = frame.nativeSize
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageLayer.contents = frame.surface
            updateGeometry()
            CATransaction.commit()
            CATransaction.flush()
        }
        setLabel(messageLabel, nil)
        tierBadge = frame.key.tier == .preview ? "Aperçu" : nil
        updateBadge()
    }

    /// Shows no pixels at all: a photo must never appear under another photo's name.
    func showMessage(_ text: String?) {
        shownSurface = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
        CATransaction.flush()
        setLabel(messageLabel, text)
        tierBadge = nil
        updateBadge()
    }

    func setInfo(_ text: String?) { setLabel(infoLabel, text) }

    /// A ring on the AF position, normalised with y down, or nil to hide it; and a short
    /// note when there is no position to show.
    func setFocusMarker(_ point: CGPoint?, note: String?) {
        focusMarker = point
        focusNote = note
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry()
        CATransaction.commit()
        updateBadge()
    }

    private func updateBadge() {
        let parts = [tierBadge, focusNote].compactMap { $0 }
        setLabel(badgeLabel, parts.isEmpty ? nil : parts.joined(separator: "  ·  "))
    }

    private func setLabel(_ label: NSTextField, _ text: String?) {
        let hidden = text == nil
        if label.isHidden != hidden { label.isHidden = hidden }
        if let text, label.stringValue != text { label.stringValue = text }
    }

    // MARK: Geometry

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry()
        CATransaction.commit()
    }

    private var pointsPerPixel: CGFloat { 1 / (window?.backingScaleFactor ?? 2) }

    private var fitScale: CGFloat {
        guard nativeSize.width > 0, nativeSize.height > 0 else { return 1 }
        return min(bounds.width / nativeSize.width, bounds.height / nativeSize.height)
    }

    /// Fit zoom in the same unit as `zoom`.
    private var fitZoom: CGFloat { fitScale / pointsPerPixel }

    private func updateGeometry() {
        guard nativeSize.width > 0 else { return }
        let scale = zoom.map { $0 * pointsPerPixel } ?? fitScale
        let size = CGSize(width: nativeSize.width * scale, height: nativeSize.height * scale)
        if zoom == nil { center = CGPoint(x: 0.5, y: 0.5) }
        // Clamped for this layout only: a preview's size can be smaller than the photo's, and
        // the point asked for must survive until the rendered frame arrives.
        let shown = clamped(center, for: size)
        let origin = CGPoint(
            x: (bounds.width / 2 - shown.x * size.width).rounded(),
            y: (bounds.height / 2 - shown.y * size.height).rounded()
        )
        imageLayer.frame = CGRect(origin: origin, size: size)
        imageLayer.magnificationFilter = (zoom ?? 0) >= 2 ? .nearest : .linear
        if let focusMarker, zoom != nil {
            markerLayer.position = CGPoint(x: origin.x + focusMarker.x * size.width,
                                           y: origin.y + (1 - focusMarker.y) * size.height)
            markerLayer.isHidden = false
        } else {
            markerLayer.isHidden = true
        }
    }

    private func clamped(_ point: CGPoint, for size: CGSize) -> CGPoint {
        let halfX = min(0.5, bounds.width / 2 / max(size.width, 1))
        let halfY = min(0.5, bounds.height / 2 / max(size.height, 1))
        return CGPoint(x: min(max(point.x, halfX), 1 - halfX), y: min(max(point.y, halfY), 1 - halfY))
    }

    // MARK: Zoom and pan

    func toggleZoom(at point: CGPoint?) {
        if zoom != nil {
            zoom = nil
        } else {
            if let point { center = imagePoint(at: point) }
            zoom = 1
        }
        applyZoomChange()
    }

    /// Zooms on a point given as a fraction of the image, y down: to `level`, or keeping
    /// the current zoom when nil (100 % if not zoomed).
    func zoom(onNormalized point: CGPoint, level: CGFloat?) {
        let wasZoomed = zoom != nil
        center = CGPoint(x: min(max(point.x, 0), 1), y: 1 - min(max(point.y, 0), 1))
        zoom = level ?? zoom ?? 1
        movedByUser = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry()
        CATransaction.commit()
        if !wasZoomed { onCommand(.zoomChanged) }
    }

    func exitZoom() {
        guard zoom != nil else { return }
        zoom = nil
        applyZoomChange()
    }

    private func imagePoint(at point: CGPoint) -> CGPoint {
        let rect = imageLayer.frame
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(
            x: min(max((point.x - rect.minX) / rect.width, 0), 1),
            y: min(max((point.y - rect.minY) / rect.height, 0), 1)
        )
    }

    private func applyZoomChange() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry()
        CATransaction.commit()
        onCommand(.zoomChanged)
    }

    override func magnify(with event: NSEvent) {
        let wasZoomed = zoom != nil
        let currentZoom = zoom ?? fitZoom
        let updated = currentZoom * (1 + event.magnification)
        if updated <= fitZoom {
            zoom = nil
        } else {
            if !wasZoomed { center = imagePoint(at: convert(event.locationInWindow, from: nil)) }
            zoom = min(updated, 8)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry()
        CATransaction.commit()
        if wasZoomed != (zoom != nil) { onCommand(.zoomChanged) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoom != nil else { return }
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        pan(dx: event.scrollingDeltaX * multiplier, dy: event.scrollingDeltaY * multiplier)
    }

    override func mouseDragged(with event: NSEvent) {
        guard zoom != nil else { return }
        pan(dx: event.deltaX, dy: event.deltaY)
    }

    private func pan(dx: CGFloat, dy: CGFloat) {
        let rect = imageLayer.frame
        guard rect.width > 0, rect.height > 0 else { return }
        // Panning starts from what is on screen and stops at the edges.
        center = clamped(center, for: rect.size)
        center.x -= dx / rect.width
        center.y += dy / rect.height
        center = clamped(center, for: rect.size)
        movedByUser = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry()
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 {
            toggleZoom(at: convert(event.locationInWindow, from: nil))
        }
    }

    // MARK: Keyboard

    /// Runs before the main menu, so plain keys never pay for menu lookup and repeat state
    /// stays available here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        return handle(event)
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    override func keyUp(with event: NSEvent) {
        onCommand(.keyReleased)
    }

    /// Letters go through the typed character so they work on any layout (AZERTY included);
    /// arrows and delete go through key codes.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 123, 126: onCommand(.previous(repeating: event.isARepeat)); return true
        case 124, 125: onCommand(.next(repeating: event.isARepeat)); return true
        case 115: onCommand(.first); return true
        case 119: onCommand(.last); return true
        case 51, 117:
            // Holding the key must never wipe a folder.
            if !event.isARepeat { onCommand(.delete) }
            return true
        case 53: onCommand(.exitZoom); return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "x":
            if !event.isARepeat { onCommand(.delete) }
            return true
        case "z":
            if !event.isARepeat { onCommand(.toggleZoom) }
            return true
        case "f":
            if !event.isARepeat { onCommand(.toggleFullScreen) }
            return true
        case "i":
            if !event.isARepeat { onCommand(.toggleInfo) }
            return true
        case "a":
            if !event.isARepeat { onCommand(.zoomToFocus) }
            return true
        default:
            return false
        }
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty
        else { return false }
        onCommand(.openDropped(urls))
        return true
    }
}
