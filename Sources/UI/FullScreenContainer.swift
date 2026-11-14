import AppKit

/// The photo's window in full screen: black, with the strip along the bottom and the photo
/// fitted in the room above it. The photo's view keeps the photo's shape, as the window does
/// outside full screen, so that it never shows bars of its own and its overlays stay on the
/// photo. The comparison takes the whole room above the strip.
final class FullScreenContainer: NSView {
    /// The view shown: the photo's or the comparison's.
    var content: NSView? {
        didSet {
            guard content !== oldValue else { return }
            if let oldValue {
                oldValue.layer?.masksToBounds = oldMasks
                oldValue.removeFromSuperview()
            }
            if let content {
                // The window no longer clips it: a zoomed photo must stay within its frame,
                // off the margins and the strip.
                content.wantsLayer = true
                oldMasks = content.layer?.masksToBounds ?? false
                content.layer?.masksToBounds = true
                addSubview(content)
            }
            needsLayout = true
        }
    }
    private var oldMasks = false
    /// The photo's shape, nil to fill the room (the comparison).
    var photoAspect: CGFloat? {
        didSet { if photoAspect != oldValue { layoutContent() } }
    }
    /// The strip's height, 0 when it is not shown.
    var bottomInset: CGFloat = 0 {
        didSet { if bottomInset != oldValue { layoutContent() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        layoutContent()
    }

    /// Set at once, not at the next layout pass: a new photo's shape lands with its image.
    private func layoutContent() {
        content?.frame = Self.contentFrame(in: bounds, bottomInset: bottomInset, aspect: photoAspect)
    }

    /// The room above the strip, and in it the largest frame of the photo's shape, centred.
    static func contentFrame(in bounds: CGRect, bottomInset: CGFloat, aspect: CGFloat?) -> CGRect {
        let inset = min(max(bottomInset, 0), bounds.height)
        let room = CGRect(x: bounds.minX, y: bounds.minY + inset, width: bounds.width, height: bounds.height - inset)
        guard let aspect, aspect > 0, room.width > 0, room.height > 0 else { return room }
        let width = min(room.width, room.height * aspect)
        let height = width / aspect
        return CGRect(
            x: (room.midX - width / 2).rounded(), y: (room.midY - height / 2).rounded(),
            width: width.rounded(), height: height.rounded()
        )
    }
}
