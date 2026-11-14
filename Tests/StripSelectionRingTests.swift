import AppKit
import XCTest
@testable import BetterView

/// Once a photo is checked, every thumbnail shows a ring that checks it with one click.
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
        view.update(cells: cells, anchor: 2, selecting: !checked.isEmpty)
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

    func testOneCheckedShowsARingOnEveryOther() {
        show(checked: [1])
        XCTAssertEqual(view.cornerMarks, [.ring, .check, .ring, .ring, .ring])
        show(checked: [])
        XCTAssertEqual(view.cornerMarks, Array(repeating: .none, count: 5), "the rings go with the last check")
    }

    func testClickingARingChecksAndClickingElsewhereShowsThePhoto() {
        show(checked: [1])
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
        show(checked: [1])
        click(ring(4), modifiers: .shift)
        XCTAssertEqual(clicks.last?.1, .shift)
    }

    func testWithoutAnyCheckTheCornerIsAPlainClick() {
        show(checked: [])
        click(ring(3))
        XCTAssertEqual(clicks.last?.1, [])
    }
}
