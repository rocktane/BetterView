import AppKit
import XCTest
@testable import BetterView

/// The strip is no wider than its photos when they are the whole folder, up to the size chosen.
@MainActor
final class StripContentWidthTests: XCTestCase {
    private var pointer = CGPoint.zero
    private var saved: [(StripPlacement, StripSize?)] = []

    private func photos(_ count: Int) -> [PhotoKey] {
        (0..<count).map { PhotoKey(path: "/photos/\($0).arw", device: 1, inode: UInt64($0), size: 1, mtimeSeconds: 0, mtimeNanoseconds: 0) }
    }

    private func makePanel(_ count: Int, anchor: Int = 0, cut: Bool = false, placement: StripPlacement = StripPlacement(origin: nil, docked: false, centeredX: true), size: StripSize = .standard, portrait: Bool = false) -> StripPanel {
        let strip = StripPanel(placement: placement, size: size)
        strip.save = { [unowned self] in saved.append(($0, $1)) }
        strip.view.onScroll = { _ in }
        strip.view.pointerLocation = { [unowned self] in pointer }
        let image = portrait ? Self.image(width: 2, height: 3) : nil
        let cells = photos(count).enumerated().map { StripCell(photo: $1, image: image, mark: $0 == anchor ? .current : .none) }
        strip.view.update(cells: cells, anchor: anchor, cut: (cut, cut))
        return strip
    }

    private static func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    func testAFewPhotosGetAStripJustWideEnough() {
        // Three 3:2 placeholders 66 pt tall: 99 pt each, two 6 pt gaps, 8 pt margins.
        let strip = makePanel(3)
        XCTAssertEqual(strip.frame.width, 3 * 99 + 2 * 6 + 2 * 8)
        XCTAssertEqual(strip.view.cellFrames.first?.minX, 8)
        XCTAssertEqual(strip.view.cellFrames.last?.maxX, strip.frame.width - 8)
    }

    func testTheRowFillsTheStripAtEitherEnd() {
        let start = makePanel(29)
        XCTAssertEqual(start.view.cellFrames.first?.minX, 8)
        XCTAssertGreaterThanOrEqual(start.view.cellFrames.last?.maxX ?? 0, start.frame.width - 8)

        let end = makePanel(29, anchor: 28)
        XCTAssertLessThanOrEqual(end.view.cellFrames.first?.minX ?? .infinity, 8)
        XCTAssertEqual(end.view.cellFrames.last?.maxX, end.frame.width - 8)
    }

    func testAFastSwipeStopsAtTheAvailableThumbnails() throws {
        let strip = makePanel(29, anchor: 14, cut: true)
        for delta: Int32 in [4000, -4000] {
            let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                               wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0))
            let event = try XCTUnwrap(NSEvent(cgEvent: scroll))
            XCTAssertTrue(event.hasPreciseScrollingDeltas)
            strip.view.scrollWheel(with: event)
            XCTAssertLessThanOrEqual(strip.view.cellFrames.first?.minX ?? .infinity, 8)
            XCTAssertGreaterThanOrEqual(strip.view.cellFrames.last?.maxX ?? 0, strip.frame.width - 8)
        }
    }

    func testSwipingPastEitherFolderEdgeBouncesAndReturns() async throws {
        let start = makePanel(29)
        let end = makePanel(29, anchor: 28)
        for (strip, delta): (StripPanel, Int32) in [(start, 4000), (end, -4000)] {
            strip.view.onScroll = { _ in XCTFail("A bounce must not change the anchor") }
            let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                               wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0))
            let event = try XCTUnwrap(NSEvent(cgEvent: scroll))
            let before = strip.view.cellFrames
            strip.view.scrollWheel(with: event)
            let travel = strip.view.cellFrames[0].minX - before[0].minX
            XCTAssertGreaterThan(travel * (delta > 0 ? 1 : -1), 0)
            XCTAssertLessThanOrEqual(abs(travel), 12)

            // Quartz encodes momentum begin and continuation as 1 and 2.
            scroll.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
            let momentumStart = try XCTUnwrap(NSEvent(cgEvent: scroll))
            XCTAssertEqual(momentumStart.momentumPhase, .began)
            strip.view.scrollWheel(with: momentumStart)
            try await Task.sleep(for: .milliseconds(160))
            XCTAssertEqual(strip.view.cellFrames, before)

            scroll.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
            let momentumUpdate = try XCTUnwrap(NSEvent(cgEvent: scroll))
            XCTAssertEqual(momentumUpdate.momentumPhase, .changed)
            strip.view.scrollWheel(with: momentumUpdate)
            XCTAssertEqual(strip.view.cellFrames, before)
        }
    }

    func testSwipeReachesAnEdgeLessThanHalfAThumbnailAway() async throws {
        let strip = makePanel(29, anchor: 3, size: StripSize(width: 680, height: 82))
        let cells = strip.view.cells
        let start = try XCTUnwrap(strip.view.cellFrames.first?.minX)
        XCTAssertGreaterThan(8 - start, 0)
        XCTAssertLessThan(8 - start, 52)
        var anchor = 3
        strip.view.onScroll = { offset in
            anchor += offset
            strip.view.update(cells: cells, anchor: anchor)
        }
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                           wheelCount: 2, wheel1: 0, wheel2: 4000, wheel3: 0))
        strip.view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: scroll)))
        XCTAssertEqual(anchor, 0)
        XCTAssertGreaterThan(strip.view.cellFrames.first?.minX ?? 0, 8)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(strip.view.cellFrames.first?.minX, 8)

        scroll.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -200)
        strip.view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: scroll)))
        XCTAssertGreaterThan(anchor, 3, "reversing skips the anchors that share the edge")
    }

    func testACentredStripStaysCentredAsItsWidthFollowsThePhotos() throws {
        let strip = makePanel(3)
        let visible = try XCTUnwrap(NSScreen.main?.visibleFrame)
        XCTAssertEqual(strip.frame.midX, visible.midX, accuracy: 1)
        strip.view.update(cells: photos(5).enumerated().map { StripCell(photo: $1, mark: $0 == 0 ? .current : .none) }, anchor: 0)
        XCTAssertEqual(strip.frame.width, 5 * 99 + 4 * 6 + 2 * 8)
        XCTAssertEqual(strip.frame.midX, visible.midX, accuracy: 1)
    }

    func testUnderTheWindowItStaysCentredUnderIt() {
        let viewer = CGRect(x: 300, y: 400, width: 900, height: 500)
        let strip = makePanel(3, placement: StripPlacement(origin: nil, docked: false, centeredX: false, window: StripWindowHold(centered: true)))
        strip.viewerFrame = { viewer }
        strip.fitToScreen()
        XCTAssertEqual(strip.frame.midX, viewer.midX, accuracy: 1)
        XCTAssertEqual(strip.frame.width, 3 * 99 + 2 * 6 + 2 * 8)
    }

    func testAFolderLargerThanTheStripUsesTheSizeChosen() {
        XCTAssertEqual(makePanel(40, cut: true).frame.width, StripSize.standard.width, "more photos beyond the ends")
        XCTAssertEqual(makePanel(29).frame.width, StripSize.standard.width, "the whole folder, wider than the size chosen")
    }

    func testNeverNarrowerThanOnePortraitPhoto() {
        XCTAssertEqual(StripResize.minWidth(height: 82), 44 + 16)
        let strip = makePanel(1, portrait: true)
        XCTAssertEqual(strip.frame.width, StripResize.minWidth(height: 82))
    }

    func testStretchingPastThePhotosKeepsTheSizeChosen() {
        let strip = makePanel(3, placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false), size: StripSize(width: 1400, height: 82))
        let start = strip.frame
        let point = CGPoint(x: start.width - 3, y: 40)
        pointer = CGPoint(x: start.minX + point.x, y: start.minY + point.y)
        strip.view.mouseDown(with: event(.leftMouseDown, at: point))
        pointer.x += 100
        strip.view.mouseDragged(with: event(.leftMouseDragged, at: point))
        XCTAssertEqual(strip.frame, start, "the side stops at the last photo")
        strip.view.mouseUp(with: event(.leftMouseUp, at: point))
        XCTAssertEqual(saved.last?.1?.width, 1400, "the maximum chosen stays")

        // Narrower than the photos: what the user sees becomes the size.
        pointer = CGPoint(x: start.minX + point.x, y: start.minY + point.y)
        strip.view.mouseDown(with: event(.leftMouseDown, at: point))
        pointer.x -= 100
        strip.view.mouseDragged(with: event(.leftMouseDragged, at: point))
        strip.view.mouseUp(with: event(.leftMouseUp, at: point))
        XCTAssertEqual(strip.frame.width, start.width - 100)
        XCTAssertEqual(saved.last?.1?.width, start.width - 100)
    }

    func testATallerStripWidensForItsPhotosUpToTheSizeChosen() {
        let strip = makePanel(3, placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false))
        let start = strip.frame
        let point = CGPoint(x: start.width / 2, y: start.height - 2)
        pointer = CGPoint(x: start.minX + point.x, y: start.minY + point.y)
        strip.view.mouseDown(with: event(.leftMouseDown, at: point))
        pointer.y += 30
        strip.view.mouseDragged(with: event(.leftMouseDragged, at: point))
        strip.view.mouseUp(with: event(.leftMouseUp, at: point))
        // Thumbnails 96 pt tall: 3:2 placeholders 144 pt wide.
        XCTAssertEqual(strip.frame.size, CGSize(width: 3 * 144 + 2 * 6 + 2 * 8, height: 112))
        XCTAssertEqual(strip.frame.minX, start.minX)
    }

    func testWideningPastThePhotosFromASmallerMaximumKeepsThemAll() {
        // A maximum narrower than the three photos: widened past them in one move.
        let strip = makePanel(3, placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false), size: StripSize(width: 200, height: 82))
        let start = strip.frame
        XCTAssertEqual(start.width, 200)
        let point = CGPoint(x: start.width - 3, y: 40)
        pointer = CGPoint(x: start.minX + point.x, y: start.minY + point.y)
        strip.view.mouseDown(with: event(.leftMouseDown, at: point))
        pointer.x += 200
        strip.view.mouseDragged(with: event(.leftMouseDragged, at: point))
        strip.view.mouseUp(with: event(.leftMouseUp, at: point))
        let content: CGFloat = 3 * 99 + 2 * 6 + 2 * 8
        XCTAssertEqual(strip.frame.width, content, "still all the photos once let go")
        XCTAssertEqual(saved.last?.1?.width, content)
    }

    func testPhotosChangedDuringADragFitOnceItEnds() {
        let strip = makePanel(3, placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false))
        let start = strip.frame
        let point = CGPoint(x: start.width / 2, y: 40)
        pointer = CGPoint(x: start.minX + point.x, y: start.minY + point.y)
        strip.view.mouseDown(with: event(.leftMouseDown, at: point))
        pointer.y += 30
        strip.view.mouseDragged(with: event(.leftMouseDragged, at: point))
        // Portrait thumbnails arrive while the button is still held.
        let portrait = Self.image(width: 2, height: 3)
        strip.view.update(cells: photos(3).enumerated().map { StripCell(photo: $1, image: portrait, mark: $0 == 0 ? .current : .none) }, anchor: 0)
        XCTAssertEqual(strip.frame.width, start.width, "not during the gesture")
        strip.view.mouseUp(with: event(.leftMouseUp, at: point))
        XCTAssertEqual(strip.frame.width, 3 * 44 + 2 * 6 + 2 * 8, "once it ends")
        XCTAssertEqual(strip.frame.minX, start.minX, "a free strip keeps its left side")
    }

    func testAPresetAppliesAtOnce() {
        let strip = makePanel(40, cut: true)
        strip.applySize(StripSizePreset.large.size!)
        XCTAssertEqual(strip.frame.size, CGSize(width: 1200, height: 122))
        strip.applySize(StripSizePreset.small.size!)
        XCTAssertEqual(strip.frame.size, CGSize(width: 620, height: 66))
    }

    func testThePresetsAreOneStepEitherSideOfTheUsualSize() {
        let small = StripSizePreset.small.size!, normal = StripSizePreset.normal.size!, large = StripSizePreset.large.size!
        XCTAssertEqual(normal, .standard)
        XCTAssertLessThan(small.height, normal.height)
        XCTAssertLessThan(normal.height, large.height)
        XCTAssertLessThan(small.width, normal.width)
        XCTAssertLessThan(normal.width, large.width)
        XCTAssertGreaterThanOrEqual(small.height, StripResize.minHeight)
        XCTAssertLessThanOrEqual(large.height, StripResize.maxHeight)
        XCTAssertNil(StripSizePreset.custom.size)
        XCTAssertEqual(StripSizePreset.allCases.map(\.label), ["Petite", "Normale", "Grande", "Personnalisée"])
    }
}
