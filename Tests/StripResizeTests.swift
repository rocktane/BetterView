import XCTest
@testable import BetterView

@MainActor
final class StripResizeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let bottomDock = CGRect(x: 0, y: 80, width: 1512, height: 870)
    private let leftDock = CGRect(x: 70, y: 0, width: 1442, height: 950)
    private let rightDock = CGRect(x: 0, y: 0, width: 1440, height: 950)

    private func resized(_ start: CGRect, _ side: StripResize.Side, _ travel: CGFloat, _ anchor: StripResize.Anchor, visible: CGRect? = nil) -> CGRect {
        StripResize.frame(start: start, side: side, travel: travel, anchor: anchor, visible: visible ?? bottomDock)
    }

    func testTheOppositeSideStaysPut() {
        let start = CGRect(x: 200, y: 300, width: 820, height: 82)
        XCTAssertEqual(resized(start, .right, 100, .minX), CGRect(x: 200, y: 300, width: 920, height: 82))
        XCTAssertEqual(resized(start, .left, -100, .maxX), CGRect(x: 100, y: 300, width: 920, height: 82))
        XCTAssertEqual(resized(start, .left, 60, .maxX), CGRect(x: 260, y: 300, width: 760, height: 82), "shrinks too")
    }

    func testACentredStripGrowsOnBothSides() {
        let start = CGRect(x: 346, y: 88, width: 820, height: 82)
        let wider = resized(start, .right, 50, .center)
        XCTAssertEqual(wider.width, 920, "the side pulled follows the pointer")
        XCTAssertEqual(wider.midX, start.midX)
        let fromLeft = resized(start, .left, -50, .center)
        XCTAssertEqual(fromLeft, wider)
    }

    func testNeverWiderThanTheVisibleScreen() {
        let start = CGRect(x: 346, y: 88, width: 820, height: 82)
        let widest = resized(start, .right, 5000, .center)
        XCTAssertEqual(widest.width, 1512 - 2 * StripMagnet.dockGap)
        XCTAssertTrue(bottomDock.contains(widest))
        // A side stays where it was: the other side stops at the edge of the screen.
        let fromLeft = resized(CGRect(x: 1000, y: 300, width: 400, height: 82), .left, -5000, .maxX)
        XCTAssertEqual(fromLeft.minX, 0)
        XCTAssertEqual(fromLeft.maxX, 1400)
        let toRight = resized(CGRect(x: 1000, y: 300, width: 400, height: 82), .right, 5000, .minX)
        XCTAssertEqual(toRight.maxX, 1512)
    }

    func testNeverNarrowerThanTheMinimum() {
        let start = CGRect(x: 346, y: 88, width: 820, height: 82)
        XCTAssertEqual(resized(start, .right, -5000, .minX).width, StripResize.minWidth)
        XCTAssertEqual(resized(start, .right, -5000, .center).width, StripResize.minWidth)
        XCTAssertEqual(resized(start, .right, -5000, .center).midX, start.midX)
    }

    func testTheAnchorFollowsTheMagnets() {
        let free = StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false)
        XCTAssertEqual(StripResize.anchor(for: free, side: .right, screen: screen, visible: bottomDock), .minX)
        XCTAssertEqual(StripResize.anchor(for: free, side: .left, screen: screen, visible: bottomDock), .maxX)
        let centred = StripPlacement(origin: nil, docked: true, centeredX: true)
        XCTAssertEqual(StripResize.anchor(for: centred, side: .left, screen: screen, visible: bottomDock), .center)
        let dockedOnly = StripPlacement(origin: nil, docked: true, centeredX: false)
        XCTAssertEqual(StripResize.anchor(for: dockedOnly, side: .left, screen: screen, visible: bottomDock), .maxX, "the bottom Dock does not hold a side")
        XCTAssertEqual(StripResize.anchor(for: centred, side: .right, screen: screen, visible: leftDock), .minX, "against a Dock on the left")
        XCTAssertEqual(StripResize.anchor(for: centred, side: .left, screen: screen, visible: rightDock), .maxX, "against a Dock on the right")
    }

    func testAStretchedStripLandsWhereItsPlacementPutsIt() {
        // Docked and centred: the remembered placement must give back the stretched frame.
        let placement = StripPlacement(origin: nil, docked: true, centeredX: true)
        let size = StripResize.fitted(.standard, visible: bottomDock)
        let start = CGRect(origin: StripMagnet.origin(for: placement, size: size, screen: screen, visible: bottomDock), size: size)
        let wider = resized(start, .right, 120, .center)
        XCTAssertEqual(StripMagnet.origin(for: placement, size: wider.size, screen: screen, visible: bottomDock), wider.origin)
    }

    func testTheChosenWidthWaitsForALargerScreen() {
        let small = CGRect(x: 0, y: 80, width: 1000, height: 870)
        let chosen = StripSize(width: 1400, height: 82)
        XCTAssertEqual(StripResize.fitted(chosen, visible: small).width, 1000 - 2 * StripMagnet.dockGap)
        XCTAssertEqual(StripResize.fitted(chosen, visible: bottomDock).width, 1400)
        XCTAssertEqual(StripResize.fitted(StripSize(width: 10, height: 82), visible: bottomDock).width, StripResize.minWidth)
        XCTAssertEqual(StripResize.fitted(chosen, visible: small).height, StripSize.standard.height)
    }

    func testASmallerScreenStillLetsItShrink() {
        // Wider than this screen allows, from a larger one: shrinking works, growing does not.
        let start = CGRect(x: 0, y: 88, width: 1400, height: 82)
        let small = CGRect(x: 0, y: 80, width: 1000, height: 870)
        XCTAssertLessThan(resized(start, .right, -100, .minX, visible: small).width, 1400)
        XCTAssertLessThanOrEqual(resized(start, .right, 100, .minX, visible: small).width, 1400)
    }

    func testSizeSurvivesARoundTrip() throws {
        let size = StripSize(width: 1234, height: 82)
        XCTAssertEqual(try JSONDecoder().decode(StripSize.self, from: JSONEncoder().encode(size)), size)
    }

    func testAWiderStripIsGivenMorePhotos() {
        let metrics = StripPanel.metrics(height: StripSize.standard.height)
        XCTAssertLessThanOrEqual(StripView.reach(width: 820, metrics: metrics), 14, "the usual 14 still cover the usual width")
        let wide = StripView.reach(width: 2544, metrics: metrics)
        // Even all portrait, the photos given reach past both edges.
        let narrowest = (metrics.height * 2 / 3).rounded() + metrics.gap
        XCTAssertGreaterThan(CGFloat(wide) * narrowest, 2544 / 2 + narrowest)
    }
}

/// The real panel and view, driven through their mouse events, with the pointer given by hand.
@MainActor
final class StripPanelStretchTests: XCTestCase {
    private var pointer = CGPoint.zero
    private var saved: [(StripPlacement, StripSize)] = []

    private func makePanel(placement: StripPlacement) -> StripPanel {
        let strip = StripPanel(placement: placement, size: .standard)
        strip.save = { [unowned self] in saved.append(($0, $1)) }
        strip.view.pointerLocation = { [unowned self] in pointer }
        let photos = (0..<29).map { PhotoKey(path: "/photos/\($0).arw", device: 1, inode: UInt64($0), size: 1, mtimeSeconds: 0, mtimeNanoseconds: 0) }
        strip.view.update(cells: photos.enumerated().map { StripCell(photo: $1, mark: $0 == 14 ? .current : .none) }, anchor: 14, cut: (true, true))
        strip.fitToScreen()
        return strip
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, in strip: StripPanel, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )!
    }

    /// Presses at `point` in the view, moves the pointer by `steps`, and lets go; checks after
    /// each step that the current photo is in the middle of the strip.
    private func gesture(_ strip: StripPanel, from point: CGPoint, steps: [CGPoint], modifiers: NSEvent.ModifierFlags = [], file: StaticString = #filePath, line: UInt = #line) {
        let view = strip.view
        pointer = CGPoint(x: strip.frame.minX + point.x, y: strip.frame.minY + point.y)
        view.mouseDown(with: event(.leftMouseDown, at: point, in: strip, modifiers: modifiers))
        for step in steps {
            pointer.x += step.x
            pointer.y += step.y
            view.mouseDragged(with: event(.leftMouseDragged, at: point, in: strip, modifiers: modifiers))
            XCTAssertEqual(view.cellFrames[14].midX, view.bounds.midX, accuracy: 1, "the current photo stays in the middle", file: file, line: line)
            XCTAssertEqual(view.bounds.width, strip.frame.width, "the view follows the panel at each step", file: file, line: line)
        }
        view.mouseUp(with: event(.leftMouseUp, at: point, in: strip, modifiers: modifiers))
    }

    func testTheRightGripStretchesAFreeStripToTheRight() {
        let strip = makePanel(placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false))
        let start = strip.frame
        gesture(strip, from: CGPoint(x: start.width - 3, y: 40), steps: Array(repeating: CGPoint(x: 15, y: 2), count: 10))
        XCTAssertEqual(strip.frame.minX, start.minX, "the left side stays")
        XCTAssertEqual(strip.frame.width, start.width + 150, "the right side follows the pointer")
        XCTAssertEqual(strip.frame.minY, start.minY, "a stretch never moves it up or down")
        XCTAssertEqual(saved.last?.1.width, start.width + 150, "the width is saved once let go")
        XCTAssertEqual(saved.count, 1)
    }

    func testAWiderStripAsksForMorePhotosAsItStretches() {
        let strip = makePanel(placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false))
        var asked = 0
        strip.onWidthChanged = { asked += 1 }
        let reach = strip.reach
        gesture(strip, from: CGPoint(x: strip.frame.width - 3, y: 40), steps: Array(repeating: CGPoint(x: 60, y: 0), count: 8))
        XCTAssertEqual(asked, 8, "each step, so the photos come in while stretching")
        XCTAssertGreaterThan(strip.reach, reach)
    }

    func testACentredStripStaysCentred() {
        let strip = makePanel(placement: StripPlacement(origin: nil, docked: false, centeredX: true))
        let start = strip.frame
        gesture(strip, from: CGPoint(x: 2, y: 40), steps: Array(repeating: CGPoint(x: -10, y: 0), count: 5))
        XCTAssertEqual(strip.frame.width, start.width + 100)
        XCTAssertEqual(strip.frame.midX, start.midX, accuracy: 0.5)
    }

    func testAPressOnTheGripThatDoesNotTravelStillClicks() {
        let strip = makePanel(placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false))
        var clicked: [PhotoKey] = []
        strip.view.onClick = { photo, _ in clicked.append(photo) }
        let start = strip.frame
        gesture(strip, from: CGPoint(x: start.width - 3, y: 40), steps: [CGPoint(x: 2, y: 0)])
        XCTAssertEqual(strip.frame, start)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertEqual(clicked.count, 1, "the photo under the grip is still clicked")
    }

    func testDraggingAwayFromTheGripsStillMovesTheStrip() {
        let strip = makePanel(placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false))
        let start = strip.frame
        gesture(strip, from: CGPoint(x: start.width / 2, y: 40), steps: Array(repeating: CGPoint(x: 0, y: 20), count: 5))
        XCTAssertEqual(strip.frame.size, start.size, "same size")
        XCTAssertNotEqual(strip.frame.origin, start.origin, "moved")
    }
}
