import AppKit

/// Where the strip sits. The magnets are remembered rather than just their result, so that a
/// strip held by the Dock stays by the Dock when the Dock or the screen changes.
struct StripPlacement: Codable, Equatable, Sendable {
    var origin: CGPoint?
    var docked = true
    var centeredX = true
    var centeredY = false
}

/// Pure geometry of the strip's two magnets: the Dock's edge of the screen, and its centre.
enum StripMagnet {
    enum DockEdge: Equatable, Sendable { case bottom, left, right }

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

    /// Where a strip dragged to `proposed` lands, and which magnets now hold it.
    static func snap(proposed: CGRect, screen: CGRect, visible: CGRect) -> (origin: CGPoint, placement: StripPlacement) {
        let size = proposed.size
        var origin = clamped(proposed.origin, size: size, visible: visible)
        var placement = StripPlacement(origin: nil, docked: false, centeredX: false, centeredY: false)

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

    /// Applies a remembered placement to the screen as it is now.
    static func origin(for placement: StripPlacement, size: CGSize, screen: CGRect, visible: CGRect) -> CGPoint {
        var origin = clamped(placement.origin ?? CGPoint(x: visible.midX, y: visible.midY), size: size, visible: visible)
        if placement.docked {
            let dock = dockedOrigin(size: size, visible: visible, edge: dockEdge(screen: screen, visible: visible))
            if let x = dock.x { origin.x = x }
            if let y = dock.y { origin.y = y }
        }
        if placement.centeredX { origin.x = visible.midX - size.width / 2 }
        if placement.centeredY { origin.y = visible.midY - size.height / 2 }
        return CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
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
    private static let metrics = StripView.Metrics(cell: CGSize(width: 78, height: 52), gap: 5, top: 9)
    private static let height: CGFloat = 92
    private static let inset: CGFloat = 10
    private static let wantedCells = 9

    let view = StripView(metrics: StripPanel.metrics)
    private let panel: NSPanel
    private var placement = Preferences.stripPlacement ?? StripPlacement()
    private var dragOrigin: CGPoint?
    /// The screen the viewer is on, for a first placement.
    var preferredScreen: () -> NSScreen? = { nil }

    /// An odd number that fits the screen, so the current photo has a middle.
    private(set) var cellCount = StripPanel.wantedCells

    init() {
        panel = FloatingStripPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: Self.height),
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
        view.layer?.borderColor = NSColor(white: 1, alpha: 0.1).cgColor
        view.layer?.borderWidth = 1
        panel.contentView = view
        view.onDrag = { [weak self] in self?.drag($0) }
        fitToScreen()
    }

    var isVisible: Bool { panel.isVisible }

    func setVisible(_ visible: Bool) {
        guard visible != panel.isVisible else { return }
        if visible {
            fitToScreen()
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
        }
    }

    /// The screen holding the remembered position, or the viewer's until there is one.
    private var screen: NSScreen? {
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
        let fitting = StripView.capacity(metrics: Self.metrics, width: visible.width - 2 * StripMagnet.dockGap - 2 * Self.inset)
        cellCount = max(1, min(Self.wantedCells, fitting.isMultiple(of: 2) ? fitting - 1 : fitting))
        let width = CGFloat(cellCount) * (Self.metrics.cell.width + Self.metrics.gap) - Self.metrics.gap + 2 * Self.inset
        let size = CGSize(width: width, height: Self.height)
        let origin = StripMagnet.origin(for: placement, size: size, screen: screen.frame, visible: visible)
        panel.setFrame(CGRect(origin: origin, size: size), display: panel.isVisible)
    }

    private func drag(_ travel: CGPoint?) {
        guard let travel else {
            dragOrigin = nil
            Preferences.stripPlacement = placement
            return
        }
        let start = dragOrigin ?? panel.frame.origin
        dragOrigin = start
        // The screen under the pointer: the strip can be dragged across to another one.
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? panel.screen else { return }
        let proposed = CGRect(origin: CGPoint(x: start.x + travel.x, y: start.y + travel.y), size: panel.frame.size)
        let (origin, landed) = StripMagnet.snap(proposed: proposed, screen: screen.frame, visible: screen.visibleFrame)
        let caught = (landed.docked && !placement.docked) || (landed.centeredX && !placement.centeredX) || (landed.centeredY && !placement.centeredY)
        if caught { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        placement = landed
        panel.setFrameOrigin(origin)
    }
}
