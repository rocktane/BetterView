import AppKit
import XCTest
@testable import BetterView

/// A checked photo keeps its check; an unchecked one shows a ring only under the pointer.
@MainActor
final class StripSelectionRingTests: XCTestCase {
    private var view: StripView!
    private var clicks: [(PhotoKey, NSEvent.ModifierFlags)] = []
    private let photos = (0..<5).map { PhotoKey(path: "/photos/\($0).arw", device: 1, inode: UInt64($0), size: 1, mtimeSeconds: 0, mtimeNanoseconds: 0) }

    override func setUp() async throws {
        view = StripView(metrics: StripPanel.metrics(height: 82))
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 82)
        view.onClick = { [unowned self] in clicks.append(($0, $1)) }
    }

    private func show(checked: Set<Int>) {
        let cells = photos.enumerated().map { StripCell(photo: $1, mark: $0 == 2 ? .current : .none, selected: checked.contains($0)) }
        view.update(cells: cells, anchor: 2)
    }

    private func click(_ point: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }

    /// The centre of the ring of cell `at`, in the view: top right corner, inside the border.
    private func ring(_ at: Int) -> CGPoint {
        let frame = view.cellFrames[at]
        return CGPoint(x: frame.maxX - 4 - 8, y: frame.maxY - 4 - 8)
    }

    func testNothingCheckedShowsNoRing() {
        show(checked: [])
        XCTAssertEqual(view.cornerMarks, Array(repeating: .none, count: 5))
    }

    func testOneCheckedShowsNoRingOnTheOthers() {
        show(checked: [1])
        XCTAssertEqual(view.cornerMarks, [.none, .check, .none, .none, .none])
    }

    func testClickingARingChecksAndClickingElsewhereShowsThePhoto() {
        view.showsRingOnHover = true
        show(checked: [1])
        move(to: ring(3))
        click(ring(3))
        XCTAssertEqual(clicks.last?.0, photos[3])
        XCTAssertEqual(clicks.last?.1, .command, "checks or unchecks, as Command+click")
        click(ring(1))
        XCTAssertEqual(clicks.last?.1, .command, "a check unchecks the same way")
        let frame = view.cellFrames[3]
        click(CGPoint(x: frame.minX + 10, y: frame.minY + 10))
        XCTAssertEqual(clicks.last?.0, photos[3])
        XCTAssertEqual(clicks.last?.1, [], "elsewhere on the thumbnail: show the photo")
    }

    func testShiftClickStillSelectsARange() {
        view.showsRingOnHover = true
        show(checked: [1])
        click(ring(4), modifiers: .shift)
        XCTAssertEqual(clicks.last?.1, .shift)
    }

    func testWithoutAnyCheckTheCornerIsAPlainClick() {
        show(checked: [])
        click(ring(3))
        XCTAssertEqual(clicks.last?.1, [])
    }

    // MARK: Hover

    private func move(to point: CGPoint) {
        view.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
    }

    private func leave() {
        view.mouseExited(with: NSEvent.mouseEvent(with: .mouseMoved, location: CGPoint(x: -50, y: -50), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!)
    }

    private func middle(_ at: Int) -> CGPoint { CGPoint(x: view.cellFrames[at].midX, y: view.cellFrames[at].midY) }

    func testTheThumbnailUnderThePointerShowsARing() {
        view.showsRingOnHover = true
        show(checked: [])
        move(to: middle(3))
        XCTAssertEqual(view.cornerMarks, [.none, .none, .none, .ring, .none])
        move(to: middle(1))
        XCTAssertEqual(view.cornerMarks, [.none, .ring, .none, .none, .none], "it follows the pointer")
        leave()
        XCTAssertEqual(view.cornerMarks, Array(repeating: .none, count: 5), "and goes when it leaves the strip")
    }

    func testAHoveredRingChecksWithOneClickEvenWithNothingChecked() {
        view.showsRingOnHover = true
        show(checked: [])
        move(to: ring(3))
        click(ring(3))
        XCTAssertEqual(clicks.last?.0, photos[3])
        XCTAssertEqual(clicks.last?.1, .command)
        let frame = view.cellFrames[3]
        click(CGPoint(x: frame.minX + 10, y: frame.minY + 10))
        XCTAssertEqual(clicks.last?.1, [], "elsewhere: show the photo")
    }

    func testWithAPhotoCheckedTheRingStillOnlyFollowsThePointer() {
        view.showsRingOnHover = true
        show(checked: [1])
        move(to: middle(3))
        XCTAssertEqual(view.cornerMarks, [.none, .check, .none, .ring, .none])
        leave()
        XCTAssertEqual(view.cornerMarks, [.none, .check, .none, .none, .none])
    }

    func testTheRingFollowsWhatMovesUnderAStillPointer() async throws {
        view.showsRingOnHover = true
        // More photos than the strip shows: the current one stays in the middle.
        let many = (0..<9).map { PhotoKey(path: "/photos/m\($0).arw", device: 1, inode: UInt64(100 + $0), size: 1, mtimeSeconds: 0, mtimeNanoseconds: 0) }
        func showMany(current: Int) {
            view.update(cells: many.enumerated().map { StripCell(photo: $1, mark: $0 == current ? .current : .none) }, anchor: current)
        }
        showMany(current: 4)
        let pointer = middle(4)
        move(to: pointer)
        XCTAssertEqual(view.cornerMarks[4], .ring)
        // Keyboard navigation: the next photo comes to the middle, under the still pointer.
        showMany(current: 5)
        // The row slides there: at each step, the ring is on what is under the pointer.
        XCTAssertEqual(view.cornerMarks.firstIndex(of: .ring), view.cellFrames.firstIndex { $0.contains(pointer) })
        try await Task.sleep(for: .milliseconds(600))
        let under = view.cellFrames.firstIndex { $0.contains(pointer) }
        XCTAssertEqual(under, 5, "the new middle photo is under the pointer")
        XCTAssertEqual(view.cornerMarks.firstIndex(of: .ring), under)
        XCTAssertEqual(view.cornerMarks.filter { $0 == .ring }.count, 1)
    }

    func testPhotoActionsStayUnderThePointerAcrossTwoRotations() throws {
        view = StripView(metrics: StripPanel.metrics(height: 82), actionOverhang: StripView.floatingActionOverhang)
        view.onScroll = { _ in }
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 82 + StripView.floatingActionOverhang)
        let context = try XCTUnwrap(CGContext(data: nil, width: 90, height: 30, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        var cells = photos.map { StripCell(photo: $0, image: image) }
        view.update(cells: cells, anchor: 2)
        let originalFrames = view.cellFrames
        view.showsPhotoActions = true

        let bar = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier() == "stripPhotoActions" })
        let trigger = try XCTUnwrap(view.subviews.first { $0.accessibilityIdentifier() == "stripPhotoActionTrigger" })
        XCTAssertTrue(bar.isHidden)
        XCTAssertTrue(trigger.isHidden)
        move(to: middle(1))
        XCTAssertTrue(bar.isHidden)
        XCTAssertFalse(trigger.isHidden)
        XCTAssertEqual(trigger.frame.minY, view.cellFrames[1].maxY)
        XCTAssertEqual(trigger.frame.maxY, 82)
        move(to: CGPoint(x: trigger.frame.midX, y: trigger.frame.midY))
        XCTAssertFalse(bar.isHidden)
        XCTAssertEqual(view.cellFrames, originalFrames)
        XCTAssertGreaterThanOrEqual(bar.frame.minY, view.cellFrames[1].maxY)
        XCTAssertGreaterThan(bar.frame.maxY, view.cellFrames[1].maxY)
        XCTAssertGreaterThan(bar.frame.maxY, 82)
        XCTAssertLessThanOrEqual(bar.frame.maxY, view.bounds.maxY)

        let right = try XCTUnwrap(bar.subviews.last as? NSButton)
        let point = CGPoint(x: bar.frame.minX + right.frame.midX, y: bar.frame.minY + right.frame.midY)
        move(to: point)
        XCTAssertIdentical(view.hitTest(point), right)
        XCTAssertNotNil(right.layer?.backgroundColor)
        XCTAssertTrue(view.isHoveringActions)
        let initialFrame = bar.frame
        var rotated: [PhotoKey] = []
        view.onRotate = { [self] photo, _ in
            rotated.append(photo)
            cells[1].rotation = rotated.count == 1 ? .right : .upsideDown
            view.update(cells: cells, anchor: 2)
        }
        let thumbnailWidth = view.cellFrames[1].width
        right.performClick(nil)
        XCTAssertNotEqual(view.cellFrames[1].width, thumbnailWidth)
        XCTAssertEqual(view.cellFrames[1].midX, trigger.frame.midX, accuracy: 0.5)
        XCTAssertEqual(bar.frame, initialFrame)
        XCTAssertIdentical(view.hitTest(point), right)
        right.performClick(nil)
        XCTAssertEqual(rotated, [photos[1], photos[1]])
        XCTAssertEqual(view.cellFrames[1].midX, trigger.frame.midX, accuracy: 0.5)
        XCTAssertEqual(bar.frame, initialFrame)

        let bookmark = try XCTUnwrap(bar.subviews[1] as? NSButton)
        let bookmarkPoint = CGPoint(x: bar.frame.minX + bookmark.frame.midX, y: point.y)
        move(to: bookmarkPoint)
        XCTAssertIdentical(view.hitTest(bookmarkPoint), bookmark)
        XCTAssertNil(right.layer?.backgroundColor)
        XCTAssertNotNil(bookmark.layer?.backgroundColor)
        view.onToggleMark = { [self] photo in
            XCTAssertEqual(photo, photos[1])
            cells[1].marked = true
            view.update(cells: cells, anchor: 2)
        }
        bookmark.performClick(nil)
        XCTAssertEqual(bookmark.toolTip, "Retirer le marque-page")
        XCTAssertEqual(bar.frame, initialFrame)

        leave()
        XCTAssertTrue(trigger.isHidden)
        XCTAssertTrue(bar.isHidden)
        XCTAssertNil(bookmark.layer?.backgroundColor)
        XCTAssertFalse(view.isHoveringActions)
        view.showsPhotoActions = false
        move(to: middle(1))
        XCTAssertTrue(bar.isHidden)
    }

    func testWithoutHoverRingsThePointerChangesNothing() {
        // The comparison row: no selection there.
        show(checked: [])
        move(to: middle(3))
        XCTAssertEqual(view.cornerMarks, Array(repeating: .none, count: 5))
        click(ring(3))
        XCTAssertEqual(clicks.last?.1, [])
    }
}
