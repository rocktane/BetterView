import AppKit
import QuartzCore

/// Pure geometry of the comparison: where the slots are and where a photo sits inside one.
enum ComparisonGeometry {
    /// `count` cells: side by side up to two, 2 x 2 above that. In reading order, y up.
    static func grid(in area: CGRect, count: Int, gap: CGFloat = 3) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = count <= 2 ? count : 2
        let rows = count <= 2 ? 1 : 2
        let width = (area.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let height = (area.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
        return (0..<count).map { index in
            let column = index % columns
            let row = index / columns
            return CGRect(
                x: area.minX + CGFloat(column) * (width + gap),
                y: area.maxY - CGFloat(row + 1) * height - CGFloat(row) * gap,
                width: width, height: height
            ).integral
        }
    }

    /// AF mode: a slot looks at its own anchor (normalised, y up), moved by the offset common
    /// to every slot, in image pixels. Same zoom everywhere, so the same offset is the same
    /// distance on screen in every slot.
    static func center(anchor: CGPoint, offset: CGVector, native: CGSize) -> CGPoint {
        guard native.width > 0, native.height > 0 else { return anchor }
        return CGPoint(x: anchor.x + offset.dx / native.width, y: anchor.y + offset.dy / native.height)
    }

    /// The common offset held to what at least one photo can still show. A photo at its edge
    /// stays there (each one is clamped for display only) without stopping the others, and a
    /// pan is never spent past every edge.
    static func clampedOffset(_ offset: CGVector, photos: [(anchor: CGPoint, native: CGSize, slot: CGSize)], zoom: CGFloat, pointsPerPixel: CGFloat) -> CGVector {
        var low = CGVector(dx: CGFloat.infinity, dy: CGFloat.infinity)
        var high = CGVector(dx: -CGFloat.infinity, dy: -CGFloat.infinity)
        let scale = zoom * pointsPerPixel
        for photo in photos where photo.native.width > 0 && photo.native.height > 0 {
            let halfX = min(0.5, photo.slot.width / 2 / max(photo.native.width * scale, 1))
            let halfY = min(0.5, photo.slot.height / 2 / max(photo.native.height * scale, 1))
            low.dx = min(low.dx, (halfX - photo.anchor.x) * photo.native.width)
            high.dx = max(high.dx, (1 - halfX - photo.anchor.x) * photo.native.width)
            low.dy = min(low.dy, (halfY - photo.anchor.y) * photo.native.height)
            high.dy = max(high.dy, (1 - halfY - photo.anchor.y) * photo.native.height)
        }
        guard low.dx <= high.dx, low.dy <= high.dy else { return offset }
        return CGVector(dx: min(max(offset.dx, low.dx), high.dx), dy: min(max(offset.dy, low.dy), high.dy))
    }

    /// The photo's rectangle in a slot. `zoom` nil fits it whole with bars around it; otherwise
    /// `zoom` is image pixels per screen pixel, with `center` (normalised, y up) in the middle.
    static func imageFrame(slot: CGSize, native: CGSize, zoom: CGFloat?, pointsPerPixel: CGFloat, center: CGPoint) -> CGRect {
        guard native.width > 0, native.height > 0 else { return .zero }
        let scale = zoom.map { $0 * pointsPerPixel } ?? min(slot.width / native.width, slot.height / native.height)
        let size = CGSize(width: native.width * scale, height: native.height * scale)
        let halfX = min(0.5, slot.width / 2 / max(size.width, 1))
        let halfY = min(0.5, slot.height / 2 / max(size.height, 1))
        let x = min(max(center.x, halfX), 1 - halfX)
        let y = min(max(center.y, halfY), 1 - halfY)
        return CGRect(
            x: (slot.width / 2 - x * size.width).rounded(),
            y: (slot.height / 2 - y * size.height).rounded(),
            width: size.width, height: size.height
        )
    }
}

/// The look of the buttons drawn over a photo, in one place. Filled, with a thin light edge and
/// a shadow: readable over a dark photo as over a bright one.
struct ComparisonActionStyle {
    var fill: NSColor
    var text: NSColor
    var edge = NSColor(white: 1, alpha: 0.55)

    static let trash = ComparisonActionStyle(fill: NSColor(srgbRed: 0.84, green: 0.16, blue: 0.14, alpha: 1), text: .white)
    static let keep = ComparisonActionStyle(fill: NSColor(white: 0.97, alpha: 1), text: .black)

    func apply(to button: NSButton) {
        button.isBordered = false
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        layer.backgroundColor = fill.cgColor
        layer.cornerRadius = 5
        layer.borderWidth = 0.5
        layer.borderColor = edge.cgColor
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.55
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: -1)
        button.attributedTitle = NSAttributedString(string: button.title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: text,
        ])
    }
}

/// One photo of the comparison. Its pixels only ever come from a frame carrying its own key.
private final class ComparisonSlotView: NSView {
    private let host = NSView()
    private let imageLayer = CALayer()
    private let focusLayer = CALayer()
    /// Where the camera aimed, in AF mode only.
    private let markerLayer = CALayer.focusMarker()
    private let captionPanel = NSView()
    private let caption = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    let trashButton = NSButton(title: "Corbeille", target: nil, action: nil)
    let keepButton = NSButton(title: "Garder celle-ci", target: nil, action: nil)

    private(set) var photo: PhotoKey?
    private var shownSurface: IOSurface?
    private(set) var nativeSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.04, alpha: 1).cgColor
        layer?.masksToBounds = true
        let root = CALayer()
        host.layer = root
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        host.frame = bounds
        addSubview(host)
        imageLayer.contentsGravity = .resize
        imageLayer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.addSublayer(imageLayer)
        focusLayer.borderColor = NSColor.white.cgColor
        focusLayer.borderWidth = 2
        focusLayer.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
        root.addSublayer(markerLayer)
        root.addSublayer(focusLayer)

        captionPanel.wantsLayer = true
        captionPanel.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        captionPanel.layer?.cornerRadius = 6
        addSubview(captionPanel)
        for label in [caption, badge, message] {
            label.textColor = NSColor(white: 1, alpha: 0.9)
            label.lineBreakMode = .byTruncatingTail
            label.drawsBackground = false
        }
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        captionPanel.addSubview(caption)
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.isHidden = true
        addSubview(badge)
        message.font = .systemFont(ofSize: 13, weight: .medium)
        message.alignment = .center
        message.isHidden = true
        addSubview(message)
        for (button, style) in [(trashButton, ComparisonActionStyle.trash), (keepButton, .keep)] {
            style.apply(to: button)
            button.refusesFirstResponder = true
            button.isHidden = true
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    func setPhoto(_ newPhoto: PhotoKey?) {
        guard newPhoto != photo else { return }
        photo = newPhoto
        clearPixels()
    }

    private func clearPixels() {
        shownSurface = nil
        nativeSize = .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = nil
        CATransaction.commit()
    }

    func show(_ frame: Frame) {
        message.isHidden = true
        guard frame.surface !== shownSurface else { return }
        shownSurface = frame.surface
        nativeSize = frame.nativeSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = frame.surface
        CATransaction.commit()
    }

    func showMessage(_ text: String) {
        clearPixels()
        if message.stringValue != text { message.stringValue = text }
        message.isHidden = false
        needsLayout = true
    }

    func setCaption(number: Int, name: String, settings: String) {
        let text = settings.isEmpty ? "\(number)   \(name)" : "\(number)   \(name)   \(settings)"
        if caption.stringValue != text {
            caption.stringValue = text
            needsLayout = true
        }
    }

    func setBadge(_ text: String?) {
        badge.isHidden = text == nil
        if let text, badge.stringValue != text {
            badge.stringValue = text
            needsLayout = true
        }
    }

    func setFocused(_ focused: Bool) {
        if focusLayer.isHidden == focused { focusLayer.isHidden = !focused }
    }

    /// The actions follow the pointer, not the focus.
    func setActionsVisible(_ visible: Bool) {
        for button in [trashButton, keepButton] where button.isHidden == visible {
            button.isHidden = !visible
        }
    }

    var actionsVisible: Bool { !trashButton.isHidden && !keepButton.isHidden }

    /// `marker`: the AF position, normalised with y up, or nil for no ring.
    func updateImage(zoom: CGFloat?, pointsPerPixel: CGFloat, center: CGPoint, marker: CGPoint? = nil) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = ComparisonGeometry.imageFrame(slot: bounds.size, native: nativeSize, zoom: zoom, pointsPerPixel: pointsPerPixel, center: center)
        imageLayer.frame = frame
        imageLayer.magnificationFilter = (zoom ?? 0) >= 2 ? .nearest : .linear
        focusLayer.frame = bounds
        if let marker, zoom != nil, frame.width > 0 {
            markerLayer.position = CGPoint(x: frame.minX + marker.x * frame.width, y: frame.minY + marker.y * frame.height)
            markerLayer.isHidden = false
        } else {
            markerLayer.isHidden = true
        }
        CATransaction.commit()
    }

    var showsMarker: Bool { !markerLayer.isHidden }

    /// Photo coordinates under a point of this slot, normalised, y up.
    func imagePoint(at point: CGPoint) -> CGPoint? {
        let rect = imageLayer.frame
        guard rect.width > 0, rect.height > 0 else { return nil }
        return CGPoint(
            x: min(max((point.x - rect.minX) / rect.width, 0), 1),
            y: min(max((point.y - rect.minY) / rect.height, 0), 1)
        )
    }

    var imageSize: CGSize { imageLayer.frame.size }

    override func layout() {
        super.layout()
        caption.sizeToFit()
        let captionWidth = min(caption.frame.width, bounds.width - 32)
        caption.frame = CGRect(x: 8, y: 3, width: captionWidth, height: caption.frame.height)
        captionPanel.frame = CGRect(x: 8, y: bounds.height - 8 - caption.frame.height - 6, width: captionWidth + 16, height: caption.frame.height + 6)
        badge.sizeToFit()
        badge.setFrameOrigin(CGPoint(x: 10, y: 8))
        message.frame = CGRect(x: 8, y: bounds.midY - 10, width: bounds.width - 16, height: 20)
        var right = bounds.width - 8
        for button in [keepButton, trashButton] {
            button.sizeToFit()
            let size = CGSize(width: button.frame.width + 16, height: 22)
            right -= size.width
            button.frame = CGRect(x: right, y: 8, width: size.width, height: size.height)
            right -= 6
        }
    }
}

/// The photos side by side, with one zoom and one position shared by all of them. No app logic
/// here: it shows what it is given and reports what was asked.
final class ComparisonView: NSView {
    var onCommand: (ViewerCommand) -> Void = { _ in }
    var shortcuts = ShortcutMap.defaults {
        didSet { updateHints() }
    }

    private static let titleHeight: CGFloat = 28
    private static let rowHeight: CGFloat = 50
    private static let hintHeight: CGFloat = 26
    private static let rowMetrics = StripView.Metrics(height: 36, gap: 3, top: 7, fadesEdges: false)

    /// nil is fit-to-slot. Otherwise 1.0 means one image pixel per screen pixel.
    private(set) var zoom: CGFloat?
    /// Photo point kept in the middle of every slot, normalised, y up.
    private var center = CGPoint(x: 0.5, y: 0.5)

    /// AF mode (A): each slot looks at its own AF position. Set while that zoom lasts.
    private struct FocusAnchor {
        let photo: PhotoKey
        /// Where the slot looks before the common offset, normalised, y up.
        var point: CGPoint
        /// The AF position itself, for the ring.
        var marker: CGPoint?
        /// The header was read: the position is known, or known to be missing.
        var known: Bool
        /// Moved by the user since the anchor was set: a late header no longer recentres it.
        var moved = false
    }
    private var focusAnchors: [Int: FocusAnchor]?
    /// Common to every slot in AF mode, in image pixels, y up.
    private(set) var focusOffset = CGVector.zero

    var followsFocus: Bool { focusAnchors != nil }

    private var slotViews: [ComparisonSlotView] = []
    private var layoutSlots: [Int] = []
    private var focus = 0
    /// The slot under the pointer: it carries the buttons. The keyboard keeps acting on `focus`.
    private(set) var hoveredSlot: Int?
    private var hoverTracking: NSTrackingArea?
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let rowNote = NSTextField(labelWithString: "")
    private let toastPanel = NSView()
    private let toastLabel = NSTextField(labelWithString: "")
    private var toastToken = 0
    let row = StripView(metrics: ComparisonView.rowMetrics)


    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        for index in 0..<ComparisonModel.slotCount {
            let slot = ComparisonSlotView()
            for button in [slot.trashButton, slot.keepButton] {
                button.target = self
                button.tag = index
            }
            slot.trashButton.action = #selector(trashPressed)
            slot.keepButton.action = #selector(keepPressed)
            addSubview(slot)
            slotViews.append(slot)
        }
        row.wantsLayer = true
        row.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        addSubview(row)
        rowNote.font = .systemFont(ofSize: 11, weight: .regular)
        rowNote.textColor = NSColor(white: 0.6, alpha: 1)
        rowNote.isHidden = true
        addSubview(rowNote)
        for label in [titleLabel, hintLabel] {
            label.alignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.textColor = NSColor(white: 0.7, alpha: 1)
        }
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hintLabel.font = .systemFont(ofSize: 11, weight: .regular)
        addSubview(titleLabel)
        addSubview(hintLabel)
        toastPanel.wantsLayer = true
        toastPanel.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.95).cgColor
        toastPanel.layer?.cornerRadius = 11
        toastPanel.isHidden = true
        toastLabel.font = .systemFont(ofSize: 12, weight: .medium)
        toastLabel.textColor = NSColor(white: 1, alpha: 0.92)
        toastPanel.addSubview(toastLabel)
        addSubview(toastPanel)
        updateHints()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var pointsPerPixel: CGFloat { 1 / (window?.backingScaleFactor ?? 2) }

    @objc private func trashPressed(_ sender: NSButton) { slotButtonPressed(.delete, slot: sender.tag) }
    @objc private func keepPressed(_ sender: NSButton) { slotButtonPressed(.keepSelected, slot: sender.tag) }

    /// The button acts on its own slot, which then takes the focus. As in the viewer, a
    /// double-click counts as one click: the second one would hit the photo that just took
    /// the place of the deleted one.
    private func slotButtonPressed(_ action: ShortcutAction, slot: Int) {
        if let event = NSApp.currentEvent, event.clickCount > 1 { return }
        onCommand(.slotAction(action, slot: slot, photo: slotViews[slot].photo))
    }

    // MARK: Content

    func reset() {
        zoom = nil
        center = CGPoint(x: 0.5, y: 0.5)
        stopFollowingFocus()
        toastPanel.isHidden = true
        for slot in slotViews { slot.setPhoto(nil) }
        setHovered(nil)
    }

    func setTitle(_ text: String) {
        if titleLabel.stringValue != text { titleLabel.stringValue = text }
    }

    /// Which slots are drawn, and which one is focused.
    func arrange(layout: [Int], focus newFocus: Int, photos: [PhotoKey?]) {
        let changed = layout != layoutSlots
        layoutSlots = layout
        focus = newFocus
        for (index, slot) in slotViews.enumerated() {
            slot.setPhoto(photos[index])
            let drawn = layout.contains(index) && photos[index] != nil
            if slot.isHidden == drawn { slot.isHidden = !drawn }
            slot.setFocused(index == focus)
        }
        if changed { needsLayout = true }
        // A slot emptied or filled under a pointer that does not move sends no event.
        refreshHover()
    }

    func showFrame(_ frame: Frame, slot: Int) {
        slotViews[slot].show(frame)
        updateImage(slot)
    }

    func showMessage(_ text: String, slot: Int) { slotViews[slot].showMessage(text) }

    /// Which slots show their buttons.
    var slotsWithActions: [Int] { slotViews.indices.filter { slotViews[$0].actionsVisible } }

    /// Middle of a slot, in this view's coordinates.
    func slotCenter(_ slot: Int) -> CGPoint { CGPoint(x: slotViews[slot].frame.midX, y: slotViews[slot].frame.midY) }

    func setCaption(slot: Int, number: Int, name: String, settings: String) {
        slotViews[slot].setCaption(number: number, name: name, settings: settings)
    }

    func setBadge(_ text: String?, slot: Int) { slotViews[slot].setBadge(text) }

    func setRowNote(_ text: String?) {
        rowNote.isHidden = text == nil
        if let text, rowNote.stringValue != text {
            rowNote.stringValue = text
            needsLayout = true
        }
    }

    func showToast(_ text: String) {
        toastLabel.stringValue = text
        toastPanel.isHidden = false
        needsLayout = true
        toastToken += 1
        let token = toastToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.toastToken == token else { return }
                self.toastPanel.isHidden = true
            }
        }
    }

    private func updateHints() {
        func key(_ action: ShortcutAction) -> String { shortcuts.keys(for: action).first?.label ?? "–" }
        hintLabel.stringValue = [
            "\(key(.previous)) \(key(.next))  Choisir",
            "\(key(.delete))  Corbeille",
            "\(key(.keepSelected))  Garder celle-ci",
            "\(key(.toggleZoom))  100 % synchronisé",
            "\(key(.zoomToFocus))  100 % sur le point AF",
            "\(key(.undo))  Annuler",
            "\(key(.exit))  Retour",
        ].joined(separator: "      ")
    }

    // MARK: Geometry

    override func layout() {
        super.layout()
        let height = bounds.height
        titleLabel.sizeToFit()
        titleLabel.frame = CGRect(x: 80, y: height - Self.titleHeight + 6, width: max(bounds.width - 160, 0), height: titleLabel.frame.height)
        hintLabel.sizeToFit()
        hintLabel.frame = CGRect(x: 8, y: (Self.hintHeight - hintLabel.frame.height) / 2, width: max(bounds.width - 16, 0), height: hintLabel.frame.height)
        row.frame = CGRect(x: 0, y: Self.hintHeight, width: bounds.width, height: Self.rowHeight)
        rowNote.sizeToFit()
        rowNote.setFrameOrigin(CGPoint(x: bounds.width - 12 - rowNote.frame.width, y: Self.hintHeight + (Self.rowHeight - rowNote.frame.height) / 2))
        let area = CGRect(
            x: 3, y: Self.hintHeight + Self.rowHeight + 3,
            width: max(bounds.width - 6, 0),
            height: max(height - Self.titleHeight - Self.hintHeight - Self.rowHeight - 3, 0)
        )
        let frames = ComparisonGeometry.grid(in: area, count: layoutSlots.count)
        for (position, slot) in layoutSlots.enumerated() {
            slotViews[slot].frame = frames[position]
        }
        updateImages()
        // The slots moved under the pointer: entering, a grid going from 4 to 2, a new size.
        refreshHover()
        toastLabel.sizeToFit()
        let toastSize = CGSize(width: toastLabel.frame.width + 24, height: toastLabel.frame.height + 8)
        toastPanel.frame = CGRect(x: (bounds.midX - toastSize.width / 2).rounded(), y: area.minY + 12, width: toastSize.width, height: toastSize.height)
        toastLabel.setFrameOrigin(CGPoint(x: 12, y: 4))
    }

    private func updateImages() {
        for index in slotViews.indices where !slotViews[index].isHidden {
            updateImage(index)
        }
    }

    private func updateImage(_ index: Int) {
        let slot = slotViews[index]
        if let anchor = focusAnchors?[index] {
            let shown = ComparisonGeometry.center(anchor: anchor.point, offset: focusOffset, native: slot.nativeSize)
            slot.updateImage(zoom: zoom, pointsPerPixel: pointsPerPixel, center: shown, marker: anchor.marker)
        } else {
            slot.updateImage(zoom: zoom, pointsPerPixel: pointsPerPixel, center: center)
        }
    }

    private func slot(at point: CGPoint) -> Int? {
        layoutSlots.first { !slotViews[$0].isHidden && slotViews[$0].frame.contains(point) }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { hover(atWindowPoint: event.locationInWindow) }
    override func mouseMoved(with event: NSEvent) { hover(atWindowPoint: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { refreshHover() }

    /// Where the pointer really is, in window coordinates, or nil when it is not on this
    /// window or another window is in front of it there. Replaced by tests.
    lazy var pointerInWindow: () -> CGPoint? = { [weak self] in
        guard let window = self?.window,
              NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
        else { return nil }
        return window.mouseLocationOutsideOfEventStream
    }

    /// Reads where the pointer really is: the slots can change under a pointer that does not
    /// move, which sends no event.
    func refreshHover() {
        hover(atWindowPoint: pointerInWindow())
    }

    /// A point given by a pointer event of this window: the pointer is on it.
    func hover(atWindowPoint windowPoint: CGPoint?) {
        setHovered(windowPoint.flatMap { slot(at: convert($0, from: nil)) })
    }

    private func setHovered(_ slot: Int?) {
        hoveredSlot = slot
        for (index, view) in slotViews.enumerated() {
            view.setActionsVisible(index == slot && !view.isHidden && view.photo != nil)
        }
    }

    // MARK: Zoom and pan

    func toggleZoom(atWindowPoint windowPoint: CGPoint?) {
        if zoom != nil {
            zoom = nil
            center = CGPoint(x: 0.5, y: 0.5)
            stopFollowingFocus()
        } else {
            zoom = 1
            if let windowPoint { aim(atWindowPoint: windowPoint) }
        }
        updateImages()
        onCommand(.zoomChanged)
    }

    func exitZoom() {
        guard zoom != nil else { return }
        toggleZoom(atWindowPoint: nil)
    }

    /// A: 100 % with every slot on its own AF position. The positions come next, slot by
    /// slot, through `setFocus`; until then a slot looks at its middle.
    func zoomOnFocus() {
        let wasZoomed = zoom != nil
        zoom = 1
        center = CGPoint(x: 0.5, y: 0.5)
        focusAnchors = [:]
        focusOffset = .zero
        updateImages()
        if !wasZoomed { onCommand(.zoomChanged) }
    }

    private func stopFollowingFocus() {
        focusAnchors = nil
        focusOffset = .zero
    }

    /// AF mode: what the header of this slot's photo says, nil while it is not read yet. A
    /// new photo in the slot looks at its own position, plus the offset common to all. A
    /// position read late recentres the slot, unless the user moved the photos since.
    func setFocus(_ focus: CameraFocus?, photo: PhotoKey?, slot: Int) {
        guard var anchors = focusAnchors else { return }
        guard let photo else {
            if anchors.removeValue(forKey: slot) != nil { focusAnchors = anchors }
            return
        }
        var point: CGPoint?
        if case .point(let found) = focus {
            point = CGPoint(x: found.normalized.x, y: 1 - found.normalized.y)
        }
        let middle = CGPoint(x: 0.5, y: 0.5)
        if var anchor = anchors[slot], anchor.photo == photo {
            guard !anchor.known, focus != nil else { return }
            anchor.known = true
            anchor.marker = point
            if !anchor.moved { anchor.point = point ?? middle }
            anchors[slot] = anchor
        } else {
            anchors[slot] = FocusAnchor(photo: photo, point: point ?? middle, marker: point, known: focus != nil)
        }
        focusAnchors = anchors
        if !slotViews[slot].isHidden { updateImage(slot) }
    }

    /// For the tests: the point in the middle of a slot and whether its ring shows.
    func shownCenter(slot: Int) -> CGPoint? {
        guard let anchor = focusAnchors?[slot] else { return nil }
        return ComparisonGeometry.center(anchor: anchor.point, offset: focusOffset, native: slotViews[slot].nativeSize)
    }

    func showsMarker(slot: Int) -> Bool { slotViews[slot].showsMarker }

    /// Before zooming: the photo point under the pointer becomes the one everybody looks at.
    private func aim(atWindowPoint windowPoint: CGPoint) {
        let point = convert(windowPoint, from: nil)
        guard let at = slot(at: point) else { return }
        let view = slotViews[at]
        if let target = view.imagePoint(at: view.convert(windowPoint, from: nil)) { center = target }
    }

    override func magnify(with event: NSEvent) {
        let slot = slotViews[focus]
        let wasZoomed = zoom != nil
        guard slot.nativeSize.width > 0, slot.nativeSize.height > 0 else { return }
        let fitZoom = min(slot.bounds.width / slot.nativeSize.width, slot.bounds.height / slot.nativeSize.height) / pointsPerPixel
        let updated = (zoom ?? fitZoom) * (1 + event.magnification)
        if updated <= fitZoom {
            zoom = nil
            center = CGPoint(x: 0.5, y: 0.5)
            stopFollowingFocus()
        } else {
            if !wasZoomed { aim(atWindowPoint: event.locationInWindow) }
            zoom = min(updated, 8)
        }
        updateImages()
        if wasZoomed != (zoom != nil) { onCommand(.zoomChanged) }
    }

    override func scrollWheel(with event: NSEvent) {
        guard zoom != nil else { return }
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        pan(dx: event.scrollingDeltaX * multiplier, dy: event.scrollingDeltaY * multiplier)
    }

    func pan(dx: CGFloat, dy: CGFloat) {
        if let anchors = focusAnchors, let zoom {
            // Every photo moves by the same distance from its own AF position.
            let scale = zoom * pointsPerPixel
            let photos = anchors.compactMap { slot, anchor -> (anchor: CGPoint, native: CGSize, slot: CGSize)? in
                let view = slotViews[slot]
                return view.isHidden ? nil : (anchor.point, view.nativeSize, view.bounds.size)
            }
            // From what is on screen, as in the viewer: an offset past every edge is not kept.
            var offset = ComparisonGeometry.clampedOffset(focusOffset, photos: photos, zoom: zoom, pointsPerPixel: pointsPerPixel)
            offset.dx -= dx / scale
            offset.dy += dy / scale
            focusOffset = ComparisonGeometry.clampedOffset(offset, photos: photos, zoom: zoom, pointsPerPixel: pointsPerPixel)
            focusAnchors = anchors.mapValues { anchor in
                var moved = anchor
                moved.moved = true
                return moved
            }
            updateImages()
            return
        }
        let size = slotViews[focus].imageSize
        guard size.width > 0, size.height > 0 else { return }
        let bounds = slotViews[focus].bounds.size
        let halfX = min(0.5, bounds.width / 2 / size.width)
        let halfY = min(0.5, bounds.height / 2 / size.height)
        // Held to what the focused photo can show, so a pan is never spent past its edge.
        center.x = min(max(center.x - dx / size.width, halfX), 1 - halfX)
        center.y = min(max(center.y + dy / size.height, halfY), 1 - halfY)
        updateImages()
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if let at = slot(at: point) {
            if at != focus { onCommand(.selectSlot(at)) }
            if event.clickCount == 2 {
                toggleZoom(atWindowPoint: event.locationInWindow)
                return
            }
        }
        // As in the viewer: dragging moves the window, or the photos once zoomed.
        if zoom == nil { window?.performDrag(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        hover(atWindowPoint: event.locationInWindow)
        guard zoom != nil else { return }
        pan(dx: event.deltaX, dy: event.deltaY)
    }

    // MARK: Keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return false }
        return handle(event)
    }

    override func keyDown(with event: NSEvent) {
        if !handle(event) { super.keyDown(with: event) }
    }

    /// The row of digits by key code: on an AZERTY keyboard those keys type & é " ' unshifted.
    private static let digitKeys: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3]

    private func handle(_ event: NSEvent) -> Bool {
        switch shortcuts.decide(KeyBinding(event: event), isRepeat: event.isARepeat) {
        case .pass: break
        case .swallow: return true
        case .perform(let action, let repeating):
            onCommand(.perform(action, repeating: repeating))
            return true
        }
        let modifiers = event.modifierFlags.intersection(KeyBinding.relevantModifiers)
        if modifiers.isEmpty, let slot = Self.digitKeys[event.keyCode] {
            onCommand(.selectSlot(slot))
            return true
        }
        return false
    }
}
