import AppKit

/// Where the strip sits. The magnets are remembered rather than just their result, so that a
/// strip held by the Dock stays by the Dock when the Dock or the screen changes, and a strip
/// held by the photo's window follows it.
struct StripPlacement: Codable, Equatable, Sendable {
    var origin: CGPoint?
    var docked = true
    var centeredX = true
    var centeredY = false
    /// Set while the photo's window holds the strip: the screen's magnets then do not apply.
    var window: StripWindowHold?
}

/// How the photo's window holds the strip: under its bottom edge, outside the window.
struct StripWindowHold: Codable, Equatable, Sendable {
    /// Centred under the window, whatever its width.
    var centered: Bool
    /// From the window's centre to the strip's, along x, when not centred. The window changes
    /// width around its centre at each photo, so this keeps the strip where it was dropped.
    var offset: CGFloat = 0
}

/// Pure geometry of the strip's magnets: the Dock's edge of the screen, its centre, and the
/// photo's window.
enum StripMagnet {
    enum DockEdge: Equatable, Sendable { case bottom, left, right }
    static let windowReach: CGFloat = 36

    /// How close the strip must come for a magnet to catch it. The drag keeps following the
    /// pointer behind the scenes, so moving this far past it lets go.
    static let dockReach: CGFloat = 36
    static let centerReach: CGFloat = 24
    /// Space left between the strip and the Dock.
    static let dockGap: CGFloat = 8

    /// The visible frame leaves out the Dock, which gives away its side. A hidden Dock leaves
    /// nothing to see, and is then taken to be at the bottom.
    static func dockEdge(screen: CGRect, visible: CGRect) -> DockEdge {
        if visible.minX > screen.minX { return .left }
        if visible.maxX < screen.maxX { return .right }
        return .bottom
    }

    private static func dockedOrigin(size: CGSize, visible: CGRect, edge: DockEdge) -> (x: CGFloat?, y: CGFloat?) {
        switch edge {
        case .bottom: (nil, visible.minY + dockGap)
        case .left: (visible.minX + dockGap, nil)
        case .right: (visible.maxX - dockGap - size.width, nil)
        }
    }

    private static func clamped(_ origin: CGPoint, size: CGSize, visible: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
            y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        )
    }

    /// The strip's bottom when the window holds it: under the window, with the Dock's gap.
    static func windowY(height: CGFloat, window: CGRect) -> CGFloat {
        window.minY - dockGap - height
    }

    /// Where a strip held by the window sits: clamped to the visible screen when the window
    /// leaves no room (a window as tall as the screen), back in place once it does.
    static func windowOrigin(_ hold: StripWindowHold, size: CGSize, window: CGRect, visible: CGRect) -> CGPoint {
        let midX = window.midX + (hold.centered ? 0 : hold.offset)
        let origin = clamped(CGPoint(x: midX - size.width / 2, y: windowY(height: size.height, window: window)), size: size, visible: visible)
        return CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
    }

    /// The window's hold on a strip dragged to `proposed`, if its bottom edge is within reach.
    /// Only a strip that overlaps the window across is caught, and only if there is room for
    /// it under the window on screen.
    static func windowSnap(proposed origin: CGPoint, size: CGSize, window: CGRect, visible: CGRect) -> (origin: CGPoint, hold: StripWindowHold)? {
        guard origin.x < window.maxX, origin.x + size.width > window.minX else { return nil }
        let y = windowY(height: size.height, window: window)
        guard y >= visible.minY, y + size.height <= visible.maxY, abs(origin.y - y) <= windowReach else { return nil }
        let centered = abs(origin.x + size.width / 2 - window.midX) <= centerReach
        var hold = StripWindowHold(centered: centered)
        let x = centered ? window.midX - size.width / 2 : origin.x
        let landed = clamped(CGPoint(x: x, y: y), size: size, visible: visible)
        if !centered { hold.offset = landed.x + size.width / 2 - window.midX }
        return (CGPoint(x: landed.x.rounded(), y: landed.y.rounded()), hold)
    }

    /// Where a strip dragged to `proposed` lands, and which magnets now hold it. The photo's
    /// window, when given, comes first: it is what the strip was brought to, and its place
    /// moves with it, while the Dock and the screen's centre stay.
    static func snap(proposed: CGRect, screen: CGRect, visible: CGRect, window: CGRect? = nil) -> (origin: CGPoint, placement: StripPlacement) {
        let size = proposed.size
        var origin = clamped(proposed.origin, size: size, visible: visible)
        var placement = StripPlacement(origin: nil, docked: false, centeredX: false, centeredY: false)
        // Measured from where the pointer puts the strip, not where the screen stops it:
        // pushing on past the screen's edge leaves the reach and lets go.
        if let window, let held = windowSnap(proposed: proposed.origin, size: size, window: window, visible: visible) {
            placement.origin = held.origin
            placement.window = held.hold
            return (held.origin, placement)
        }

        let dock = dockedOrigin(size: size, visible: visible, edge: dockEdge(screen: screen, visible: visible))
        if let x = dock.x, abs(origin.x - x) <= dockReach {
            origin.x = x
            placement.docked = true
        }
        if let y = dock.y, abs(origin.y - y) <= dockReach {
            origin.y = y
            placement.docked = true
        }
        if dock.x == nil || !placement.docked, abs(origin.x + size.width / 2 - visible.midX) <= centerReach {
            origin.x = visible.midX - size.width / 2
            placement.centeredX = true
        }
        if dock.y == nil || !placement.docked, abs(origin.y + size.height / 2 - visible.midY) <= centerReach {
            origin.y = visible.midY - size.height / 2
            placement.centeredY = true
        }
        origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        placement.origin = origin
        return (origin, placement)
    }

    /// Applies a remembered placement to the screen as it is now. A strip held by the window
    /// follows `window`; without one (the window is away), it stays where it last was.
    static func origin(for placement: StripPlacement, size: CGSize, screen: CGRect, visible: CGRect, window: CGRect? = nil) -> CGPoint {
        if let hold = placement.window {
            if let window { return windowOrigin(hold, size: size, window: window, visible: visible) }
            let last = clamped(placement.origin ?? CGPoint(x: visible.midX - size.width / 2, y: visible.minY + dockGap), size: size, visible: visible)
            return CGPoint(x: last.x.rounded(), y: last.y.rounded())
        }
        var origin = clamped(placement.origin ?? CGPoint(x: visible.midX, y: visible.midY), size: size, visible: visible)
        // The Dock wins on its own axis, as when dragging: it may have moved since.
        let dock = dockedOrigin(size: size, visible: visible, edge: dockEdge(screen: screen, visible: visible))
        let holdsX = placement.docked && dock.x != nil
        let holdsY = placement.docked && dock.y != nil
        if holdsX, let x = dock.x { origin.x = x }
        if holdsY, let y = dock.y { origin.y = y }
        if placement.centeredX, !holdsX { origin.x = visible.midX - size.width / 2 }
        if placement.centeredY, !holdsY { origin.y = visible.midY - size.height / 2 }
        return CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
    }
}

/// The strip's size. Only the width is stretched today; the height is stored beside it, so that
/// stretching it too (bigger thumbnails) adds a side to `StripResize` and changes no stored value.
struct StripSize: Codable, Equatable, Sendable {
    var width: CGFloat
    var height: CGFloat

    static let standard = StripSize(width: 820, height: 82)
}

/// Pure geometry of stretching the strip by one of its sides.
enum StripResize {
    enum Side: Equatable, Sendable { case left, right }
    /// What stays put while the strip stretches: its centre, or one of its sides.
    enum Anchor: Equatable, Sendable { case center, minX, maxX }

    /// Room for a few photos and the current one in the middle.
    static let minWidth: CGFloat = 300
    /// How far inside each side a press stretches rather than clicks, scrolls or moves.
    static let grip: CGFloat = 8

    /// Never wider than the visible screen, with the Dock's gap on each side.
    static func maxWidth(visible: CGRect) -> CGFloat {
        max(visible.width - 2 * StripMagnet.dockGap, 1).rounded(.down)
    }

    /// The size to show: the one chosen, as far as this screen allows. The chosen width is
    /// kept, so that coming back to a larger screen brings it back.
    static func fitted(_ size: StripSize, visible: CGRect) -> CGSize {
        let upper = maxWidth(visible: visible)
        return CGSize(width: min(max(size.width, min(minWidth, upper)), upper).rounded(), height: StripSize.standard.height)
    }

    /// A centred strip stays centred, a strip held by the Dock stays against it, and any
    /// other keeps the side opposite the one pulled.
    static func anchor(for placement: StripPlacement, side: Side, screen: CGRect, visible: CGRect) -> Anchor {
        if let hold = placement.window {
            return hold.centered ? .center : side == .right ? .minX : .maxX
        }
        let dockHoldsX = placement.docked && StripMagnet.dockEdge(screen: screen, visible: visible) != .bottom
        if dockHoldsX {
            return StripMagnet.dockEdge(screen: screen, visible: visible) == .left ? .minX : .maxX
        }
        if placement.centeredX { return .center }
        return side == .right ? .minX : .maxX
    }

    /// The strip's frame once the pulled side has travelled `travel` points, right positive,
    /// since the press. The pulled side follows the pointer; around the centre, both do.
    static func frame(start: CGRect, side: Side, travel: CGFloat, anchor: Anchor, visible: CGRect) -> CGRect {
        let grow = side == .right ? travel : -travel
        let room: CGFloat
        switch anchor {
        case .center: room = 2 * min(start.midX - visible.minX, visible.maxX - start.midX)
        case .minX: room = visible.maxX - start.minX
        case .maxX: room = start.maxX - visible.minX
        }
        // A strip already past a bound (a smaller screen) may still shrink, never grow.
        let upper = max(min(maxWidth(visible: visible), room), min(start.width, minWidth))
        let lower = min(minWidth, upper)
        let width = min(max(start.width + (anchor == .center ? 2 * grow : grow), lower), upper).rounded()
        let x: CGFloat
        switch anchor {
        case .center: x = (start.midX - width / 2).rounded()
        case .minX: x = start.minX
        case .maxX: x = start.maxX - width
        }
        return CGRect(x: x, y: start.minY, width: width, height: start.height)
    }
}

/// Keeps the keyboard on the viewer: clicking the strip never takes it away, and the strip goes
/// away with the app.
private final class FloatingStripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The strip's own small window, detached from the viewer, whose size follows each photo.
@MainActor
final class StripPanel {
    /// As much room under the photos as above: no line of text under them. A taller strip
    /// would get taller thumbnails from here, and the thumbnails' pixel size would follow.
    static func metrics(height: CGFloat) -> StripView.Metrics {
        StripView.Metrics(height: height - 16, gap: 6, top: 8, fadesEdges: true)
    }

    let view = StripView(metrics: StripPanel.metrics(height: StripSize.standard.height))
    private let panel: NSPanel
    private var placement: StripPlacement
    private var size: StripSize
    /// Where the placement and the size go once a gesture ends.
    var save: (StripPlacement, StripSize) -> Void = { placement, size in
        Preferences.stripPlacement = placement
        Preferences.stripSize = size
    }
    private var dragOrigin: CGPoint?
    private var resizeStart: (frame: CGRect, anchor: StripResize.Anchor, visible: CGRect)?
    /// The screen the viewer is on, for a first placement.
    var preferredScreen: () -> NSScreen? = { nil }
    /// The width changed: a wider strip needs more photos to stay filled.
    var onWidthChanged: () -> Void = {}
    /// The photo's window, which the strip can be held by. Its frame is given only while the
    /// strip may follow it: shown with a photo, not minimised, not comparing.
    weak var viewer: NSWindow?
    var viewerFrame: () -> CGRect? = { nil }

    init(placement: StripPlacement? = Preferences.stripPlacement, size: StripSize? = Preferences.stripSize) {
        self.placement = placement ?? StripPlacement()
        self.size = size ?? .standard
        panel = FloatingStripPanel(
            contentRect: NSRect(x: 0, y: 0, width: StripSize.standard.width, height: StripSize.standard.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.ignoresCycle, .fullScreenNone]
        panel.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.94).cgColor
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        view.layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
        view.layer?.borderWidth = 1
        panel.contentView = view
        view.onDrag = { [weak self] in self?.drag($0) }
        view.onResize = { [weak self] in self?.resize($0) }
        fitToScreen()
    }

    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }

    /// How many photos to give on each side of the middle one, so that even portrait photos
    /// fill the strip as it is now.
    var reach: Int { StripView.reach(width: panel.frame.width, metrics: Self.metrics(height: StripSize.standard.height)) }

    var isHeldByViewer: Bool { placement.window != nil }

    func setVisible(_ visible: Bool) {
        guard visible != panel.isVisible else { return }
        if visible {
            fitToScreen()
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
        }
        updateChildWindow()
    }

    /// A strip held by the window is its child while nothing else moves it: the window server
    /// then carries it along with the window as it is dragged, with no delay. A shape change
    /// still goes through `followViewer`, as the window grows around its centre.
    private func updateChildWindow() {
        let wanted = panel.isVisible && placement.window != nil && dragOrigin == nil && resizeStart == nil && viewerFrame() != nil
        let parent = panel.parent
        if wanted, let viewer {
            if parent !== viewer {
                parent?.removeChildWindow(panel)
                viewer.addChildWindow(panel, ordered: .above)
                // A child takes its parent's level: the strip stays a floating panel.
                panel.level = .floating
            }
        } else if let parent {
            parent.removeChildWindow(panel)
        }
    }

    /// The window moved or changed shape: a strip it holds goes with it, in the same turn so
    /// that both land together.
    func followViewer() {
        guard placement.window != nil, panel.isVisible, dragOrigin == nil, resizeStart == nil else { return }
        fitToScreen()
        updateChildWindow()
    }

    /// The screen holding the remembered position, or the viewer's until there is one. A strip
    /// held by the window is on the window's screen.
    private var screen: NSScreen? {
        if placement.window != nil, viewerFrame() != nil, let screen = viewer?.screen { return screen }
        if let origin = placement.origin,
           let holding = NSScreen.screens.first(where: { $0.frame.contains(origin) }) {
            return holding
        }
        return preferredScreen() ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// Follows the Dock and the screens. They change under the strip without any drag.
    func fitToScreen() {
        guard let screen else { return }
        let visible = screen.visibleFrame
        let size = StripResize.fitted(size, visible: visible)
        let origin = StripMagnet.origin(for: placement, size: size, screen: screen.frame, visible: visible, window: viewerFrame())
        setFrame(CGRect(origin: origin, size: size), display: panel.isVisible)
    }

    private func setFrame(_ frame: CGRect, display: Bool) {
        guard frame != panel.frame else { return }
        let widthChanged = frame.width != panel.frame.width
        panel.setFrame(frame, display: display)
        if widthChanged { onWidthChanged() }
    }

    /// Stretches the strip by a side, then remembers the width and where it ended.
    private func resize(_ pull: (side: StripResize.Side, travel: CGFloat)?) {
        guard let pull else {
            resizeStart = nil
            // A centred strip that the screen pushed aside may fit centred again.
            followViewer()
            save(placement, size)
            updateChildWindow()
            return
        }
        guard let screen = panel.screen ?? self.screen else { return }
        let start = resizeStart ?? (
            panel.frame,
            StripResize.anchor(for: placement, side: pull.side, screen: screen.frame, visible: screen.visibleFrame),
            screen.visibleFrame
        )
        if resizeStart == nil {
            resizeStart = start
            updateChildWindow()
        }
        let frame = StripResize.frame(start: start.frame, side: pull.side, travel: pull.travel, anchor: start.anchor, visible: start.visible)
        guard frame != panel.frame else { return }
        size.width = frame.width
        placement.origin = frame.origin
        if placement.window != nil, let window = viewerFrame() {
            placement.window?.offset = frame.midX - window.midX
        }
        setFrame(frame, display: true)
    }

    private func drag(_ travel: CGPoint?) {
        guard let travel else {
            dragOrigin = nil
            save(placement, size)
            updateChildWindow()
            return
        }
        let start = dragOrigin ?? panel.frame.origin
        if dragOrigin == nil {
            dragOrigin = start
            updateChildWindow()
        }
        // The screen under the pointer: the strip can be dragged across to another one.
        let pointer = view.pointerLocation()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? panel.screen else { return }
        // The width chosen, as far as that screen allows: a strip widened on a larger screen
        // narrows when brought to a smaller one, and widens again on the way back.
        let fitted = StripResize.fitted(size, visible: screen.visibleFrame)
        let proposed = CGRect(origin: CGPoint(x: start.x + travel.x, y: start.y + travel.y), size: fitted)
        let (origin, landed) = StripMagnet.snap(proposed: proposed, screen: screen.frame, visible: screen.visibleFrame, window: viewerFrame())
        let caught = (landed.docked && !placement.docked) || (landed.centeredX && !placement.centeredX) || (landed.centeredY && !placement.centeredY)
            || (landed.window != nil && placement.window == nil) || (landed.window?.centered == true && placement.window?.centered != true)
        if caught { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        placement = landed
        setFrame(CGRect(origin: origin, size: fitted), display: true)
    }
}
