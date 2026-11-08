import AppKit
import QuartzCore

enum ViewerCommand {
    case perform(ShortcutAction, repeating: Bool)
    case keyReleased
    case hoverChanged(Bool)
    case openDropped([URL])
    case zoomChanged
    /// In the comparison: this slot takes the focus.
    case selectSlot(Int)
}

/// Shows one IOSurface in a layer and handles geometry and input. No app logic here.
final class ViewerView: NSView {
    var onCommand: (ViewerCommand) -> Void = { _ in }
    var shortcuts = ShortcutMap.defaults

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
    private let infoPanel = ViewerView.panel()
    private let infoNameLabel = ViewerView.label(size: 15, weight: .semibold)
    private let infoSettingsLabel = ViewerView.label(size: 13, weight: .regular)
    private let infoDateLabel = ViewerView.label(size: 13, weight: .regular)
    private let positionPanel = ViewerView.panel()
    private let positionLabel = ViewerView.label(size: 17, weight: .semibold)
    private var hoverTracking: NSTrackingArea?
    /// Everything written over the photo only shows while the pointer is on it.
    private(set) var isHovered = false
    private var hasInfo = false
    private var badgeText: String?

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

    private static func panel() -> NSView {
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor(white: 0, alpha: 0.45).cgColor
        panel.layer?.cornerRadius = 8
        panel.isHidden = true
        return panel
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

        for label in [messageLabel, badgeLabel] { addSubview(label) }
        addSubview(infoPanel)
        addSubview(positionPanel)
        positionLabel.isHidden = false
        positionLabel.setContentCompressionResistancePriority(.dragThatCannotResizeWindow - 5, for: .horizontal)
        positionPanel.addSubview(positionLabel)
        for label in [infoNameLabel, infoSettingsLabel, infoDateLabel] {
            label.isHidden = false
            label.lineBreakMode = .byTruncatingTail
            // The panel follows its text. Below the window's own priorities, or the text would
            // force a minimum width on the window and the photo would no longer fit it.
            label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            label.setContentCompressionResistancePriority(.dragThatCannotResizeWindow - 10, for: .horizontal)
            infoPanel.addSubview(label)
        }
        let shrinkToText = infoPanel.widthAnchor.constraint(equalToConstant: 0)
        shrinkToText.priority = .defaultLow
        NSLayoutConstraint.activate([
            shrinkToText,
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badgeLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            infoPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            infoPanel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            infoPanel.trailingAnchor.constraint(lessThanOrEqualTo: positionPanel.leadingAnchor, constant: -8),
            positionPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            positionPanel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            positionLabel.topAnchor.constraint(equalTo: positionPanel.topAnchor, constant: 6),
            positionLabel.bottomAnchor.constraint(equalTo: positionPanel.bottomAnchor, constant: -6),
            positionLabel.leadingAnchor.constraint(equalTo: positionPanel.leadingAnchor, constant: 10),
            positionLabel.trailingAnchor.constraint(equalTo: positionPanel.trailingAnchor, constant: -10),
            infoNameLabel.topAnchor.constraint(equalTo: infoPanel.topAnchor, constant: 6),
            infoNameLabel.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: 10),
            infoNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: infoPanel.trailingAnchor, constant: -10),
            infoSettingsLabel.topAnchor.constraint(equalTo: infoNameLabel.bottomAnchor, constant: 2),
            infoSettingsLabel.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: 10),
            infoSettingsLabel.trailingAnchor.constraint(lessThanOrEqualTo: infoPanel.trailingAnchor, constant: -10),
            infoDateLabel.topAnchor.constraint(equalTo: infoSettingsLabel.bottomAnchor, constant: 2),
            infoDateLabel.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: 10),
            infoDateLabel.trailingAnchor.constraint(lessThanOrEqualTo: infoPanel.trailingAnchor, constant: -10),
            infoDateLabel.bottomAnchor.constraint(equalTo: infoPanel.bottomAnchor, constant: -6),
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
        badgeText = frame.key.tier == .preview ? "Aperçu" : nil
        applyOverlayVisibility()
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
        badgeText = nil
        applyOverlayVisibility()
    }

    /// The lines keep their place while the shooting information is loading.
    func setInfo(name: String, settings: String, date: String, position: String) {
        hasInfo = true
        if infoNameLabel.stringValue != name { infoNameLabel.stringValue = name }
        if infoSettingsLabel.stringValue != settings { infoSettingsLabel.stringValue = settings }
        if infoDateLabel.stringValue != date { infoDateLabel.stringValue = date }
        if positionLabel.stringValue != position { positionLabel.stringValue = position }
        applyOverlayVisibility()
    }

    func hideInfo() {
        hasInfo = false
        applyOverlayVisibility()
    }

    private func applyOverlayVisibility() {
        let showInfo = hasInfo && isHovered
        if infoPanel.isHidden == showInfo { infoPanel.isHidden = !showInfo }
        if positionPanel.isHidden == showInfo { positionPanel.isHidden = !showInfo }
        setLabel(badgeLabel, isHovered ? badgeText : nil)
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

    /// The window has the photo's shape, so this is the whole photo. Taking the larger of the
    /// two ratios means a rounding difference between the two shapes can never open a bar.
    private var fitScale: CGFloat {
        guard nativeSize.width > 0, nativeSize.height > 0 else { return 1 }
        return max(bounds.width / nativeSize.width, bounds.height / nativeSize.height)
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

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        hoverTracking = area
        // The window can change shape under a pointer that does not move, which sends no event.
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }

    /// Asks where the pointer really is. Over another window in front, it is not on the photo.
    func refreshHover() {
        guard let window else { return }
        let inWindow = window.mouseLocationOutsideOfEventStream
        let inside = bounds.contains(convert(inWindow, from: nil))
            && NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
        guard inside != isHovered else { return }
        isHovered = inside
        applyOverlayVisibility()
        onCommand(.hoverChanged(inside))
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
        } else if zoom == nil {
            // Dragging the photo moves the window; once zoomed, it moves the image instead.
            window?.performDrag(with: event)
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

    private func handle(_ event: NSEvent) -> Bool {
        guard let binding = KeyBinding(event: event), let action = shortcuts.action(for: binding) else { return false }
        if action.repeats || !event.isARepeat {
            onCommand(.perform(action, repeating: event.isARepeat))
        }
        return true
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
