import XCTest
@testable import BetterView

@MainActor
final class StripResizeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let bottomDock = CGRect(x: 0, y: 80, width: 1512, height: 870)
    private let leftDock = CGRect(x: 70, y: 0, width: 1442, height: 950)
    private let rightDock = CGRect(x: 0, y: 0, width: 1440, height: 950)
    private typealias Anchor = StripResize.Anchor

    /// Across only.
    private func resized(_ start: CGRect, _ sides: StripResize.Sides, _ travel: CGFloat, _ anchor: Anchor, visible: CGRect? = nil) -> CGRect {
        StripResize.frame(start: start, sides: sides, travel: CGPoint(x: travel, y: 0), anchors: (anchor, .lower), visible: visible ?? bottomDock)
    }

    private func stretched(_ start: CGRect, _ sides: StripResize.Sides, _ travel: CGPoint, _ anchors: (x: Anchor, y: Anchor), visible: CGRect? = nil) -> CGRect {
        StripResize.frame(start: start, sides: sides, travel: travel, anchors: anchors, visible: visible ?? bottomDock)
    }

    func testTheOppositeSideStaysPut() {
        let start = CGRect(x: 200, y: 300, width: 820, height: 82)
        XCTAssertEqual(resized(start, .right, 100, .lower), CGRect(x: 200, y: 300, width: 920, height: 82))
        XCTAssertEqual(resized(start, .left, -100, .upper), CGRect(x: 100, y: 300, width: 920, height: 82))
        XCTAssertEqual(resized(start, .left, 60, .upper), CGRect(x: 260, y: 300, width: 760, height: 82), "shrinks too")
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
        let fromLeft = resized(CGRect(x: 1000, y: 300, width: 400, height: 82), .left, -5000, .upper)
        XCTAssertEqual(fromLeft.minX, 0)
        XCTAssertEqual(fromLeft.maxX, 1400)
        let toRight = resized(CGRect(x: 1000, y: 300, width: 400, height: 82), .right, 5000, .lower)
        XCTAssertEqual(toRight.maxX, 1512)
    }

    func testNeverNarrowerThanTheMinimum() {
        let start = CGRect(x: 346, y: 88, width: 820, height: 82)
        XCTAssertEqual(resized(start, .right, -5000, .lower).width, StripResize.minSize.width)
        XCTAssertEqual(resized(start, .right, -5000, .center).width, StripResize.minSize.width)
        XCTAssertEqual(resized(start, .right, -5000, .center).midX, start.midX)
    }

    func testTheTopSideStretchesItTaller() {
        let start = CGRect(x: 200, y: 300, width: 820, height: 82)
        XCTAssertEqual(stretched(start, .top, CGPoint(x: 30, y: 40), (.lower, .lower)), CGRect(x: 200, y: 300, width: 820, height: 122), "the bottom stays, the width does not move")
        XCTAssertEqual(stretched(start, .bottom, CGPoint(x: 0, y: -40), (.lower, .upper)), CGRect(x: 200, y: 260, width: 820, height: 122), "the top stays")
        XCTAssertEqual(stretched(start, .top, CGPoint(x: 0, y: 5000), (.lower, .lower)).height, StripResize.maxHeight)
        XCTAssertEqual(stretched(start, .top, CGPoint(x: 0, y: -5000), (.lower, .lower)).height, StripResize.minSize.height)
    }

    func testACornerStretchesBothWays() {
        let start = CGRect(x: 200, y: 300, width: 820, height: 82)
        let frame = stretched(start, [.right, .top], CGPoint(x: 100, y: 40), (.lower, .lower))
        XCTAssertEqual(frame, CGRect(x: 200, y: 300, width: 920, height: 122))
        let other = stretched(start, [.left, .bottom], CGPoint(x: -100, y: -40), (.upper, .upper))
        XCTAssertEqual(other, CGRect(x: 100, y: 260, width: 920, height: 122))
    }

    func testNeverTallerThanTheVisibleScreen() {
        let short = CGRect(x: 0, y: 25, width: 1512, height: 120)
        XCTAssertEqual(StripResize.maxSize(visible: short).height, 120 - 2 * StripMagnet.dockGap)
        let start = CGRect(x: 200, y: 33, width: 820, height: 82)
        let tallest = stretched(start, .top, CGPoint(x: 0, y: 500), (.lower, .lower), visible: short)
        XCTAssertLessThanOrEqual(tallest.maxY, short.maxY)
    }

    func testTheAnchorsFollowTheMagnets() {
        let free = StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false)
        XCTAssertEqual(StripResize.anchors(for: free, sides: .right, screen: screen, visible: bottomDock).x, .lower)
        XCTAssertEqual(StripResize.anchors(for: free, sides: .left, screen: screen, visible: bottomDock).x, .upper)
        XCTAssertEqual(StripResize.anchors(for: free, sides: .top, screen: screen, visible: bottomDock).y, .lower)
        XCTAssertEqual(StripResize.anchors(for: free, sides: .bottom, screen: screen, visible: bottomDock).y, .upper)
        let centred = StripPlacement(origin: nil, docked: true, centeredX: true)
        XCTAssertEqual(StripResize.anchors(for: centred, sides: .left, screen: screen, visible: bottomDock).x, .center)
        XCTAssertEqual(StripResize.anchors(for: centred, sides: .bottom, screen: screen, visible: bottomDock).y, .lower, "the bottom Dock holds the bottom: the top moves")
        let dockedOnly = StripPlacement(origin: nil, docked: true, centeredX: false)
        XCTAssertEqual(StripResize.anchors(for: dockedOnly, sides: .left, screen: screen, visible: bottomDock).x, .upper, "the bottom Dock does not hold a side")
        XCTAssertEqual(StripResize.anchors(for: centred, sides: .right, screen: screen, visible: leftDock).x, .lower, "against a Dock on the left")
        XCTAssertEqual(StripResize.anchors(for: centred, sides: .left, screen: screen, visible: rightDock).x, .upper, "against a Dock on the right")
        XCTAssertEqual(StripResize.anchors(for: centred, sides: .top, screen: screen, visible: leftDock).y, .lower, "a side Dock does not hold the height")
        let middle = StripPlacement(origin: nil, docked: false, centeredX: true, centeredY: true)
        XCTAssertEqual(StripResize.anchors(for: middle, sides: .top, screen: screen, visible: bottomDock).y, .center)
    }

    func testAStretchedStripLandsWhereItsPlacementPutsIt() {
        // Docked and centred: the remembered placement must give back the stretched frame.
        let placement = StripPlacement(origin: nil, docked: true, centeredX: true)
        let size = StripResize.fitted(.standard, visible: bottomDock)
        let start = CGRect(origin: StripMagnet.origin(for: placement, size: size, screen: screen, visible: bottomDock), size: size)
        let anchors = StripResize.anchors(for: placement, sides: [.right, .top], screen: screen, visible: bottomDock)
        let larger = stretched(start, [.right, .top], CGPoint(x: 120, y: 30), anchors)
        XCTAssertEqual(larger.size, CGSize(width: 1060, height: 112))
        XCTAssertEqual(StripMagnet.origin(for: placement, size: larger.size, screen: screen, visible: bottomDock), larger.origin)
    }

    func testTheChosenSizeWaitsForALargerScreen() {
        let small = CGRect(x: 0, y: 80, width: 1000, height: 870)
        let chosen = StripSize(width: 1400, height: 120)
        XCTAssertEqual(StripResize.fitted(chosen, visible: small).width, 1000 - 2 * StripMagnet.dockGap)
        XCTAssertEqual(StripResize.fitted(chosen, visible: bottomDock).width, 1400)
        XCTAssertEqual(StripResize.fitted(StripSize(width: 10, height: 10), visible: bottomDock), StripResize.minSize)
        XCTAssertEqual(StripResize.fitted(chosen, visible: small).height, 120)
        XCTAssertEqual(StripResize.fitted(StripSize(width: 800, height: 900), visible: small).height, StripResize.maxHeight)
    }

    func testASmallerScreenStillLetsItShrink() {
        // Wider than this screen allows, from a larger one: shrinking works, growing does not.
        let start = CGRect(x: 0, y: 88, width: 1400, height: 82)
        let small = CGRect(x: 0, y: 80, width: 1000, height: 870)
        XCTAssertLessThan(resized(start, .right, -100, .lower, visible: small).width, 1400)
        XCTAssertLessThanOrEqual(resized(start, .right, 100, .lower, visible: small).width, 1400)
    }

    func testSizeSurvivesARoundTrip() throws {
        let size = StripSize(width: 1234, height: 120)
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

    func testThumbnailsStaySharpUpToTheTallestStrip() {
        XCTAssertEqual(ThumbnailStore.pixels(forHeight: 66, scale: 2), 200, "the usual strip keeps the usual size")
        let tallest = StripPanel.metrics(height: StripResize.maxHeight).height
        let pixels = ThumbnailStore.pixels(forHeight: tallest, scale: 2)
        XCTAssertGreaterThanOrEqual(CGFloat(pixels), tallest * 2 * 1.5, "a 3:2 photo at full height on a Retina screen")
        XCTAssertEqual(pixels, 440)
        XCTAssertEqual(ThumbnailStore.pixels(forHeight: 70, scale: 2), 280, "in steps")
        XCTAssertEqual(ThumbnailStore.pixels(forHeight: tallest, scale: 1), 280, "less on a standard screen")
    }

    func testThumbnailsGoWhenTheBudgetIsReachedThoseShownLast() {
        let sizes = ["a": 40, "b": 30, "c": 20]
        XCTAssertEqual(ThumbnailStore.evicted(sizes: sizes, asked: ["a"], adding: 10, budget: 100), [], "it fits")
        XCTAssertEqual(ThumbnailStore.evicted(sizes: sizes, asked: ["a", "c"], adding: 30, budget: 100), ["b"], "only what is no longer asked for")
        XCTAssertEqual(ThumbnailStore.evicted(sizes: sizes, asked: ["a", "b", "c"], adding: 30, budget: 100), ["a", "b", "c"], "all, when what is shown does not fit")
    }
}

/// The real panel and view, driven through their mouse events, with the pointer given by hand.
@MainActor
final class StripPanelStretchTests: XCTestCase {
    private var pointer = CGPoint.zero
    private var saved: [(StripPlacement, StripSize)] = []

    private func makePanel(placement: StripPlacement, size: StripSize = .standard) -> StripPanel {
        let strip = StripPanel(placement: placement, size: size)
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

    func testStretchingTheHeightKeepsAWidthTheScreenHoldsBack() {
        // Chosen wider than this screen, on a larger one.
        let strip = makePanel(placement: StripPlacement(origin: CGPoint(x: 0, y: 300), docked: false, centeredX: false), size: StripSize(width: 9000, height: 82))
        let start = strip.frame
        XCTAssertLessThan(start.width, 9000)
        gesture(strip, from: CGPoint(x: start.width / 2, y: start.height - 2), steps: [CGPoint(x: 0, y: 20)])
        XCTAssertEqual(saved.last?.1, StripSize(width: 9000, height: 102), "only the height pulled is taken")
    }

    func testAScreenOfAnotherScaleAsksForOtherThumbnails() throws {
        let strip = makePanel(placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false))
        var asked = 0
        strip.onSizeChanged = { asked += 1 }
        let window = try XCTUnwrap(strip.view.window)
        NotificationCenter.default.post(name: NSWindow.didChangeBackingPropertiesNotification, object: window)
        XCTAssertEqual(asked, 1)
    }

    func testAWiderStripAsksForMorePhotosAsItStretches() {
        let strip = makePanel(placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false))
        var asked = 0
        strip.onSizeChanged = { asked += 1 }
        let reach = strip.reach
        gesture(strip, from: CGPoint(x: strip.frame.width - 3, y: 40), steps: Array(repeating: CGPoint(x: 60, y: 0), count: 8))
        XCTAssertEqual(asked, 8, "each step, so the photos come in while stretching")
        XCTAssertGreaterThan(strip.reach, reach)
    }

    func testTheTopGripMakesTheThumbnailsTaller() {
        let strip = makePanel(placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false))
        let start = strip.frame
        let before = strip.view.cellFrames[14]
        gesture(strip, from: CGPoint(x: start.width / 2, y: start.height - 2), steps: Array(repeating: CGPoint(x: 0, y: 10), count: 4))
        XCTAssertEqual(strip.frame, CGRect(x: start.minX, y: start.minY, width: start.width, height: start.height + 40), "the bottom stays")
        XCTAssertEqual(strip.view.cellFrames[14].height, before.height + 40, "the thumbnails take the height")
        XCTAssertEqual(strip.view.cellFrames[14].minY, before.minY, "the margins stay the same")
        XCTAssertEqual(saved.last?.1, StripSize(width: start.width, height: start.height + 40))
        XCTAssertGreaterThan(strip.thumbnailPixels, 200, "and asks for larger thumbnails")
    }

    func testACornerGripStretchesBothWays() {
        let strip = makePanel(placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false))
        let start = strip.frame
        gesture(strip, from: CGPoint(x: start.width - 4, y: start.height - 4), steps: Array(repeating: CGPoint(x: 10, y: 10), count: 3))
        XCTAssertEqual(strip.frame, CGRect(x: start.minX, y: start.minY, width: start.width + 30, height: start.height + 30))
    }

    func testAStripUnderTheWindowGrowsDownwards() {
        let viewer = CGRect(x: 300, y: 400, width: 900, height: 500)
        let strip = makePanel(placement: StripPlacement(origin: nil, docked: false, centeredX: false, window: StripWindowHold(centered: true)))
        strip.viewerFrame = { viewer }
        strip.fitToScreen()
        let start = strip.frame
        XCTAssertEqual(start.maxY, viewer.minY - StripMagnet.dockGap)
        gesture(strip, from: CGPoint(x: start.width / 2, y: 2), steps: Array(repeating: CGPoint(x: 0, y: -10), count: 3))
        XCTAssertEqual(strip.frame.maxY, start.maxY, "it still hangs from the window")
        XCTAssertEqual(strip.frame.height, start.height + 30)
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
