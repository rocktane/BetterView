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

/// One photo of the comparison. Its pixels only ever come from a frame carrying its own key.
private final class ComparisonSlotView: NSView {
    private let host = NSView()
    private let imageLayer = CALayer()
    private let focusLayer = CALayer()
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
        // Drawn by hand: they must stay readable over any photo.
        for (button, background, text) in [
            (trashButton, NSColor(white: 0, alpha: 0.75), NSColor.white),
            (keepButton, NSColor(white: 0.95, alpha: 1), NSColor.black),
        ] {
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = background.cgColor
            button.layer?.cornerRadius = 5
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: text,
            ])
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

    func setFocused(_ focused: Bool, showsActions: Bool) {
        focusLayer.isHidden = !focused
        trashButton.isHidden = !(focused && showsActions)
        keepButton.isHidden = !(focused && showsActions)
    }

    func updateImage(zoom: CGFloat?, pointsPerPixel: CGFloat, center: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = ComparisonGeometry.imageFrame(slot: bounds.size, native: nativeSize, zoom: zoom, pointsPerPixel: pointsPerPixel, center: center)
        imageLayer.magnificationFilter = (zoom ?? 0) >= 2 ? .nearest : .linear
        focusLayer.frame = bounds
        CATransaction.commit()
    }

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

    private var slotViews: [ComparisonSlotView] = []
    private var layoutSlots: [Int] = []
    private var focus = 0
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
        for _ in 0..<ComparisonModel.slotCount {
            let slot = ComparisonSlotView()
            slot.trashButton.target = self
            slot.trashButton.action = #selector(trashPressed)
            slot.keepButton.target = self
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

    @objc private func trashPressed() { onCommand(.perform(.delete, repeating: false)) }
    @objc private func keepPressed() { onCommand(.perform(.keepSelected, repeating: false)) }

    // MARK: Content

    func reset() {
        zoom = nil
        center = CGPoint(x: 0.5, y: 0.5)
        toastPanel.isHidden = true
        for slot in slotViews { slot.setPhoto(nil) }
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
            slot.setFocused(index == focus, showsActions: true)
        }
        if changed { needsLayout = true }
    }

    func showFrame(_ frame: Frame, slot: Int) {
        slotViews[slot].show(frame)
        slotViews[slot].updateImage(zoom: zoom, pointsPerPixel: pointsPerPixel, center: center)
    }

    func showMessage(_ text: String, slot: Int) { slotViews[slot].showMessage(text) }

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
        toastLabel.sizeToFit()
        let toastSize = CGSize(width: toastLabel.frame.width + 24, height: toastLabel.frame.height + 8)
        toastPanel.frame = CGRect(x: (bounds.midX - toastSize.width / 2).rounded(), y: area.minY + 12, width: toastSize.width, height: toastSize.height)
        toastLabel.setFrameOrigin(CGPoint(x: 12, y: 4))
    }

    private func updateImages() {
        for slot in slotViews where !slot.isHidden {
            slot.updateImage(zoom: zoom, pointsPerPixel: pointsPerPixel, center: center)
        }
    }

    private func slot(at point: CGPoint) -> Int? {
        layoutSlots.first { !slotViews[$0].isHidden && slotViews[$0].frame.contains(point) }
    }

    // MARK: Zoom and pan

    func toggleZoom(atWindowPoint windowPoint: CGPoint?) {
        if zoom != nil {
            zoom = nil
            center = CGPoint(x: 0.5, y: 0.5)
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

    private func pan(dx: CGFloat, dy: CGFloat) {
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
