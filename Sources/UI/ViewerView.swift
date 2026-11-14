import AppKit
import QuartzCore

enum ViewerCommand {
    case perform(ShortcutAction, repeating: Bool)
    case keyReleased
    case hoverChanged(Bool)
    case openDropped([URL])
    /// A click that did not move the window, while `opensOnClick`.
    case clicked
    case zoomChanged
    /// In the comparison: a button of this slot, showing this photo, was pressed.
    case slotAction(ComparisonAction, slot: Int, photo: PhotoKey?)
}

/// The buttons over a photo of the comparison: the only way to keep or delete there.
enum ComparisonAction: Sendable {
    case trash, keep
}

/// Shows one IOSurface in a layer and handles geometry and input. No app logic here.
final class ViewerView: NSView {
    var onCommand: (ViewerCommand) -> Void = { _ in }
    /// The right-click menu for the photo shown, built for each click.
    var contextMenu: () -> NSMenu? = { nil }
    var shortcuts = ShortcutMap.defaults
    /// Nothing is shown: a click asks to open something.
    var opensOnClick = false

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
    private let markerLayer = CALayer.focusMarker()
    private let messageLabel = ViewerView.label(size: 15, weight: .medium)
    private let badgeLabel = ViewerView.label(size: 11, weight: .semibold)
    /// The zoom level, shown for as long as the view is zoomed, pointer on the photo or not.
    private let zoomPanel = ViewerView.panel()
    private let zoomLabel = ViewerView.label(size: 13, weight: .semibold)
    private let infoPanel = ViewerView.panel()
    private let infoNameLabel = ViewerView.label(size: 15, weight: .semibold)
    private let infoSettingsLabel = ViewerView.label(size: 13, weight: .regular)
    private let infoDateLabel = ViewerView.label(size: 13, weight: .regular)
    private let positionPanel = ViewerView.panel()
    /// Set in the name's font: same size, same weight.
    private let positionLabel = ViewerView.label(size: 15, weight: .semibold)
    private var hoverTracking: NSTrackingArea?
    /// Everything written over the photo only shows while the pointer is on it.
    private(set) var isHovered = false
    private var hasInfo = false
    private let bannerLabel = ViewerView.label(size: 13, weight: .semibold)
    private let lockBadge: NSImageView = {
        let image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Photo protégée")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = NSColor(white: 1, alpha: 0.85)
        view.toolTip = "Photo protégée : la suppression est refusée"
        view.isHidden = true
        return view
    }()
    private var isProtected = false
    private var bannerToken = 0

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
        root.addSublayer(markerLayer)

        // Hidden badges drop out of the stack, so the lock and « Aperçu » never overlap.
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        zoomLabel.isHidden = false
        zoomPanel.addSubview(zoomLabel)
        let badges = NSStackView(views: [badgeLabel, lockBadge, zoomPanel])
        badges.orientation = .horizontal
        badges.spacing = 6
        badges.translatesAutoresizingMaskIntoConstraints = false
        bannerLabel.wantsLayer = true
        bannerLabel.drawsBackground = true
        bannerLabel.backgroundColor = NSColor(white: 0, alpha: 0.55)
        bannerLabel.layer?.cornerRadius = 4
        for view in [messageLabel, badges, bannerLabel] { addSubview(view) }
        addSubview(infoPanel)
        addSubview(positionPanel)
        positionLabel.isHidden = false
        positionLabel.font = infoNameLabel.font
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
            badges.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            badges.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            bannerLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            bannerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 44),
            infoPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            infoPanel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            infoPanel.trailingAnchor.constraint(lessThanOrEqualTo: positionPanel.leadingAnchor, constant: -8),
            positionPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            positionPanel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            zoomLabel.topAnchor.constraint(equalTo: zoomPanel.topAnchor, constant: 5),
            zoomLabel.bottomAnchor.constraint(equalTo: zoomPanel.bottomAnchor, constant: -5),
            zoomLabel.leadingAnchor.constraint(equalTo: zoomPanel.leadingAnchor, constant: 10),
            zoomLabel.trailingAnchor.constraint(equalTo: zoomPanel.trailingAnchor, constant: -10),
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
        infoPanel.fade(visible: showInfo)
        positionPanel.fade(visible: showInfo)
        updateBadge()
    }

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
        setLabel(badgeLabel, parts.isEmpty || (!isHovered && focusNote == nil) ? nil : parts.joined(separator: "  ·  "))
        lockBadge.fade(visible: isProtected && isHovered)
    }

    /// A property flip, no I/O: called after the image is committed. Shown with the other
    /// overlays, while the pointer is on the photo.
    func setProtected(_ protected: Bool) {
        guard protected != isProtected else { return }
        isProtected = protected
        updateBadge()
    }

    /// A brief, non-modal message that does not stop the sorting rhythm.
    func flash(_ text: String, duration: TimeInterval = 1.6) {
        bannerToken += 1
        let token = bannerToken
        setLabel(bannerLabel, " \(text) ")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.bannerToken == token else { return }
                self.setLabel(self.bannerLabel, nil)
            }
        }
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
        // Clamped for this layout only: a preview's size can be smaller than the photo's, and
        // the point asked for must survive until the rendered frame arrives.
        let shown = clamped(center, for: size)
        let origin = CGPoint(
            x: (bounds.width / 2 - shown.x * size.width).rounded(),
            y: (bounds.height / 2 - shown.y * size.height).rounded()
        )
        imageLayer.frame = CGRect(origin: origin, size: size)
        imageLayer.magnificationFilter = (zoom ?? 0) >= 2 ? .nearest : .linear
        if let zoom {
            let text = "\(Int((zoom * 100).rounded())) %"
            if zoomLabel.stringValue != text { zoomLabel.stringValue = text }
        }
        if zoomPanel.isHidden != (zoom == nil) { zoomPanel.isHidden = zoom == nil }
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

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        // Moves too: whatever went wrong before, moving the pointer on the photo shows it all.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
        // The window can change shape under a pointer that does not move, which sends no event.
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { pointerMoved(toWindowPoint: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { pointerMoved(toWindowPoint: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { refreshHover() }

    /// Where the pointer really is, in window coordinates, or nil when it is not on this
    /// window or another window is in front of it there. Replaced by tests.
    lazy var pointerInWindow: () -> CGPoint? = { [weak self] in
        guard let window = self?.window,
              NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
        else { return nil }
        return window.mouseLocationOutsideOfEventStream
    }

    /// Asks where the pointer really is. Over another window in front, it is not on the photo.
    /// Applied again even when nothing seems to have changed: the overlays may have drifted.
    func refreshHover() {
        guard window != nil else { return }
        setHovered(pointerInWindow().map { bounds.contains(convert($0, from: nil)) } ?? false)
    }

    /// A pointer event of this window: the pointer is there, whatever another window's
    /// number said before (a tooltip, the app switcher, a system banner).
    func pointerMoved(toWindowPoint point: CGPoint) {
        setHovered(bounds.contains(convert(point, from: nil)))
    }

    /// Idempotent: a few property reads when everything is already as it should be.
    private func setHovered(_ inside: Bool) {
        isHovered = inside
        applyOverlayVisibility()
        onCommand(.hoverChanged(inside))
    }

    /// What the pointer shows, as it really is on screen: for the tests.
    var overlaysShown: Bool { !infoPanel.isHidden && infoPanel.alphaValue == 1 && !positionPanel.isHidden && positionPanel.alphaValue == 1 }

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

    /// Steps of ⌘+ and ⌘−. Below the fit, or past the last step down, the view fits again.
    static let zoomSteps: [CGFloat] = [0.25, 0.5, 1, 2, 4, 8]

    /// The next step up or down from where the view is, kept on the point under the pointer
    /// when the zoom starts there, as Z does.
    func stepZoom(by direction: Int, at point: CGPoint?) {
        guard shownSurface != nil else { return }
        let fit = fitZoom
        let current = zoom ?? fit
        let next = direction > 0
            ? Self.zoomSteps.first { $0 > current * 1.01 && $0 > fit * 1.01 }
            : Self.zoomSteps.last { $0 < current * 0.99 }
        guard let next else {
            if direction < 0 { exitZoom() }
            return
        }
        guard next > fit * 1.01 else {
            exitZoom()
            return
        }
        let wasZoomed = zoom != nil
        if !wasZoomed, let point { center = imagePoint(at: point) }
        zoom = next
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

    /// Back to the fit without reporting it: the caller is already displaying another photo
    /// and plans after that.
    func resetZoom() {
        guard zoom != nil else { return }
        zoom = nil
        movedByUser = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateGeometry()
        CATransaction.commit()
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

    /// A click toggles 100 % on the point clicked, as in Lightroom; a double-click counts as
    /// its first click only. Dragging moves the window, or the image once zoomed. With
    /// nothing to show, a click asks to open something.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // ⌃-click is a right-click: it must neither zoom nor move the window.
        if event.modifierFlags.contains(.control) {
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        guard event.clickCount == 1, let window else { return }
        let start = event.locationInWindow
        var moved = false
        while let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp {
                if !moved { clicked(at: convert(start, from: nil)) }
                return
            }
            if !moved {
                guard hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) >= 3 else { continue }
                moved = true
                guard zoom != nil else {
                    window.performDrag(with: event)
                    return
                }
                // The travel so far, then each move: the image follows the pointer from the press.
                pan(dx: next.locationInWindow.x - start.x, dy: start.y - next.locationInWindow.y)
                continue
            }
            pan(dx: next.deltaX, dy: next.deltaY)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        opensOnClick || shownSurface == nil ? nil : contextMenu()
    }

    private func clicked(at point: CGPoint) {
        if opensOnClick {
            onCommand(.clicked)
        } else if shownSurface != nil {
            toggleZoom(at: point)
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
        switch shortcuts.decide(KeyBinding(event: event), isRepeat: event.isARepeat) {
        case .pass: return false
        case .swallow: return true
        case .perform(let action, let repeating):
            onCommand(.perform(action, repeating: repeating))
            return true
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

/// The last fade asked of each view: an older fade-out that ends late must not hide a view
/// shown again since, whatever its alpha reads at that moment.
private nonisolated(unsafe) var fadeGenerationKey: UInt8 = 0

extension CALayer {
    /// The AF mark, in the viewer as in the comparison: a thin ring where the camera aimed,
    /// saying nothing about sharpness. Hidden until placed.
    static func focusMarker() -> CALayer {
        let size: CGFloat = 22
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        layer.cornerRadius = size / 2
        layer.borderWidth = 1.5
        layer.borderColor = NSColor(white: 1, alpha: 0.75).cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.8
        layer.shadowRadius = 1.5
        layer.shadowOffset = .zero
        layer.isHidden = true
        layer.actions = ["position": NSNull(), "hidden": NSNull()]
        return layer
    }
}

extension NSView {
    private var fadeGeneration: Int {
        get { objc_getAssociatedObject(self, &fadeGenerationKey) as? Int ?? 0 }
        set { objc_setAssociatedObject(self, &fadeGenerationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Overlays shown on hover: they appear almost at once, and leave a little more slowly.
    /// A view that has faded out is hidden, so it takes no clicks.
    func fade(visible: Bool) {
        let target: CGFloat = visible ? 1 : 0
        // Showing always cancels a pending hide, even when the view already looks right.
        if visible { fadeGeneration += 1 }
        // The animator sets the value at once: a view already headed there is left alone.
        if visible ? (!isHidden && alphaValue == 1) : (isHidden || alphaValue == 0) { return }
        if visible, isHidden {
            alphaValue = 0
            isHidden = false
        }
        if !visible { fadeGeneration += 1 }
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.08 : 0.22
            context.timingFunction = CAMediaTimingFunction(name: visible ? .easeOut : .easeInEaseOut)
            animator().alphaValue = target
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Shown again meanwhile: it stays.
                guard let self, !visible, self.fadeGeneration == generation else { return }
                self.isHidden = true
                self.alphaValue = 0
            }
        }
    }
}
