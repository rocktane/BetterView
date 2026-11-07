import AppKit
import QuartzCore

enum ViewerCommand {
    case next(repeating: Bool), previous(repeating: Bool), first, last
    case delete
    case toggleZoom, toggleFullScreen, toggleInfo
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

    private let host = NSView()
    private let imageLayer = CALayer()
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
        setLabel(badgeLabel, frame.key.tier == .preview ? "Aperçu" : nil)
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
        setLabel(badgeLabel, nil)
    }

    func setInfo(_ text: String?) { setLabel(infoLabel, text) }

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
        clampCenter(for: size)
        let origin = CGPoint(
            x: (bounds.width / 2 - center.x * size.width).rounded(),
            y: (bounds.height / 2 - center.y * size.height).rounded()
        )
        imageLayer.frame = CGRect(origin: origin, size: size)
        imageLayer.magnificationFilter = (zoom ?? 0) >= 2 ? .nearest : .linear
    }

    private func clampCenter(for size: CGSize) {
        let halfX = min(0.5, bounds.width / 2 / max(size.width, 1))
        let halfY = min(0.5, bounds.height / 2 / max(size.height, 1))
        center.x = min(max(center.x, halfX), 1 - halfX)
        center.y = min(max(center.y, halfY), 1 - halfY)
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
        center.x -= dx / rect.width
        center.y += dy / rect.height
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
