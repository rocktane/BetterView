import AppKit
import XCTest
@testable import BetterView

final class StripWindowMagnetTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let visible = CGRect(x: 0, y: 80, width: 1512, height: 870)
    private let window = CGRect(x: 300, y: 300, width: 900, height: 600)
    private let size = CGSize(width: 820, height: 82)

    private func snap(x: CGFloat, y: CGFloat, window: CGRect? = nil) -> (origin: CGPoint, placement: StripPlacement) {
        StripMagnet.snap(proposed: CGRect(origin: CGPoint(x: x, y: y), size: size), screen: screen, visible: visible, window: window ?? self.window)
    }

    func testNearTheBottomEdgeItHangsUnderTheWindow() {
        let under = window.minY - StripMagnet.dockGap - size.height
        let result = snap(x: 300, y: under - 20)
        XCTAssertEqual(result.origin, CGPoint(x: 300, y: under))
        XCTAssertEqual(result.placement.window?.centered, false)
        XCTAssertFalse(result.placement.docked || result.placement.centeredX || result.placement.centeredY, "the screen's magnets let go")
    }

    func testNearTheTopEdgeNothingCatches() {
        // Under the window only: the top edge is not a magnet.
        let window = CGRect(x: 300, y: 150, width: 900, height: 600)
        XCTAssertNil(snap(x: 300, y: window.maxY + 8, window: window).placement.window)
    }

    func testNearTheWindowsCentreItIsCentredOnIt() {
        let under = window.minY - StripMagnet.dockGap - size.height
        let result = snap(x: window.midX - size.width / 2 + 15, y: under)
        XCTAssertEqual(result.origin.x, (window.midX - size.width / 2).rounded())
        XCTAssertEqual(result.placement.window?.centered, true)
    }

    func testFarFromTheWindowOrBesideItTheScreenMagnetsApply() {
        XCTAssertNil(snap(x: 360, y: 100).placement.window, "too far below: the Dock's reach")
        XCTAssertTrue(snap(x: 360, y: 100).placement.docked)
        let right = CGRect(x: 900, y: 300, width: 500, height: 600)
        let beside = snap(x: 50, y: right.minY - StripMagnet.dockGap - size.height, window: right)
        XCTAssertNil(beside.placement.window, "not across the window")
    }

    func testTheWindowWinsOverTheDockWhenBothAreInReach() {
        // The window's bottom just above the Dock: both places are within reach.
        let low = CGRect(x: 300, y: 80 + 8 + 82 + 8 + 20, width: 900, height: 600)
        let result = snap(x: 360, y: 100, window: low)
        XCTAssertNotNil(result.placement.window)
        XCTAssertFalse(result.placement.docked)
        XCTAssertEqual(result.origin.y, low.minY - 8 - 82)
    }

    func testPushingOnPastTheScreensEdgeLetsGo() {
        // Under the window, 10 pt above the bottom of the visible screen.
        let low = CGRect(x: 300, y: 80 + 10 + 82 + 8, width: 900, height: 600)
        let under = low.minY - 8 - 82
        XCTAssertNotNil(snap(x: 300, y: under - 20, window: low).placement.window)
        let pushed = snap(x: 300, y: under - 100, window: low)
        XCTAssertNil(pushed.placement.window, "100 pt past the window's place, though the screen stops it 10 pt lower")
        XCTAssertTrue(visible.contains(CGRect(origin: pushed.origin, size: size)))
    }

    func testAnEdgeWithoutRoomDoesNotCatch() {
        // A window as tall as the visible screen: no room under it.
        let tall = CGRect(x: 300, y: 80, width: 600, height: 870)
        XCTAssertNil(snap(x: 300, y: 82, window: tall).placement.window)
    }

    func testAHeldStripFollowsTheWindowsShapeAndPlace() {
        let hold = StripWindowHold(centered: true)
        let placement = StripPlacement(origin: nil, docked: false, centeredX: false, window: hold)
        // A portrait photo: the window narrows around the same centre.
        let portrait = CGRect(x: 550, y: 300, width: 400, height: 600)
        let origin = StripMagnet.origin(for: placement, size: size, screen: screen, visible: visible, window: portrait)
        XCTAssertEqual(origin, CGPoint(x: (portrait.midX - size.width / 2).rounded(), y: 300 - 8 - 82))
        let moved = portrait.offsetBy(dx: -200, dy: 100)
        XCTAssertEqual(StripMagnet.origin(for: placement, size: size, screen: screen, visible: visible, window: moved).y, 400 - 8 - 82)
    }

    func testAnOffsetIsKeptFromTheWindowsCentre() {
        let under = window.minY - StripMagnet.dockGap - size.height
        let held = snap(x: 500, y: under)
        let hold = try! XCTUnwrap(held.placement.window)
        XCTAssertEqual(hold.offset, 500 + size.width / 2 - window.midX)
        let narrower = window.insetBy(dx: 200, dy: 0)
        let origin = StripMagnet.origin(for: held.placement, size: size, screen: screen, visible: visible, window: narrower)
        XCTAssertEqual(origin.x, 500, "same centre, so the same place")
    }

    func testWithoutRoomItStaysOnScreenAndComesBack() {
        let placement = StripPlacement(origin: nil, docked: false, centeredX: false, window: StripWindowHold(centered: true))
        let tall = CGRect(x: 300, y: 80, width: 900, height: 870)
        let squeezed = StripMagnet.origin(for: placement, size: size, screen: screen, visible: visible, window: tall)
        XCTAssertTrue(visible.contains(CGRect(origin: squeezed, size: size)), "inside the visible screen, over the photo")
        let back = StripMagnet.origin(for: placement, size: size, screen: screen, visible: visible, window: window)
        XCTAssertEqual(back.y, window.minY - 8 - 82)
    }

    func testWithoutTheWindowItStaysWhereItLastWas() {
        let placement = StripPlacement(origin: CGPoint(x: 345, y: 210), docked: false, centeredX: false, window: StripWindowHold(centered: true))
        XCTAssertEqual(StripMagnet.origin(for: placement, size: size, screen: screen, visible: visible, window: nil), CGPoint(x: 345, y: 210))
    }

    func testAStripHeldByTheWindowStretchesAroundItsCentreOrFromASide() {
        let centred = StripPlacement(origin: nil, docked: true, centeredX: true, window: StripWindowHold(centered: true))
        XCTAssertEqual(StripResize.anchors(for: centred, sides: .right, screen: screen, visible: visible).x, .center)
        XCTAssertEqual(StripResize.anchors(for: centred, sides: .bottom, screen: screen, visible: visible).y, .upper, "hanging from the window, it grows downwards")
        let aside = StripPlacement(origin: nil, docked: true, centeredX: true, window: StripWindowHold(centered: false, offset: 40))
        XCTAssertEqual(StripResize.anchors(for: aside, sides: .right, screen: screen, visible: visible).x, .lower, "the screen's centre no longer holds it")
    }

    func testPlacementWithAHoldSurvivesARoundTripAndOldOnesStillLoad() throws {
        let placement = StripPlacement(origin: CGPoint(x: 1, y: 2), docked: false, centeredX: false, window: StripWindowHold(centered: false, offset: -12))
        XCTAssertEqual(try JSONDecoder().decode(StripPlacement.self, from: JSONEncoder().encode(placement)), placement)
        let old = Data(#"{"origin":[490,88],"docked":true,"centeredX":true,"centeredY":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(StripPlacement.self, from: old).window)
    }
}

/// The real panel held by a real window.
@MainActor
final class StripPanelFollowTests: XCTestCase {
    func testTheStripGoesWithTheWindow() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let viewer = NSWindow(contentRect: CGRect(x: visible.midX - 300, y: visible.midY - 150, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        viewer.isReleasedWhenClosed = false
        viewer.orderFront(nil)
        defer { viewer.orderOut(nil) }
        let hold = StripWindowHold(centered: true)
        let strip = StripPanel(placement: StripPlacement(origin: nil, docked: false, centeredX: false, window: hold), size: StripSize(width: 500, height: 82))
        strip.save = { _, _ in }
        strip.viewer = viewer
        strip.viewerFrame = { viewer.frame }
        strip.setVisible(true)
        defer { strip.setVisible(false) }
        XCTAssertEqual(strip.frame.maxY, viewer.frame.minY - StripMagnet.dockGap)
        XCTAssertEqual(strip.frame.midX, viewer.frame.midX, accuracy: 0.5)

        // A new photo's shape: narrower, around the same centre.
        viewer.setFrame(viewer.frame.insetBy(dx: 120, dy: 0), display: false)
        strip.followViewer()
        XCTAssertEqual(strip.frame.midX, viewer.frame.midX, accuracy: 0.5)

        // Moved by the user: the strip, a child window meanwhile, comes along.
        viewer.setFrameOrigin(CGPoint(x: viewer.frame.minX - 40, y: viewer.frame.minY + 30))
        strip.followViewer()
        XCTAssertEqual(strip.frame.maxY, viewer.frame.minY - StripMagnet.dockGap)
        XCTAssertEqual(strip.frame.midX, viewer.frame.midX, accuracy: 0.5)
    }
}
