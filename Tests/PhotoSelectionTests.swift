import XCTest
@testable import BetterView

final class PhotoSelectionTests: XCTestCase {
    private let photos = ["a", "b", "c", "d", "e", "f"].map { photo($0) }

    private func names(_ selection: PhotoSelection) -> [String] {
        selection.photos(in: photos).map(\.name)
    }

    /// ⇧→ from b: b and c. Again: b to d. Then ⇧←: back to b and c, as in the Finder.
    func testShiftArrowsGrowAndShrinkFromTheAnchor() {
        var selection = PhotoSelection()
        selection.extend(from: 1, to: 2, in: photos)
        XCTAssertEqual(names(selection), ["b", "c"])
        selection.extend(from: 2, to: 3, in: photos)
        XCTAssertEqual(names(selection), ["b", "c", "d"])
        selection.extend(from: 3, to: 2, in: photos)
        XCTAssertEqual(names(selection), ["b", "c"])
        // Past the anchor, the run turns around it.
        selection.extend(from: 2, to: 1, in: photos)
        selection.extend(from: 1, to: 0, in: photos)
        XCTAssertEqual(names(selection), ["a", "b"])
    }

    /// Moving without Shift keeps the selection; the next run adds to it from there.
    func testNewRunKeepsEarlierPhotos() {
        var selection = PhotoSelection()
        selection.extend(from: 0, to: 1, in: photos)
        selection.endRun()
        selection.extend(from: 4, to: 5, in: photos)
        XCTAssertEqual(names(selection), ["a", "b", "e", "f"])
        selection.extend(from: 5, to: 4, in: photos)
        XCTAssertEqual(names(selection), ["a", "b", "e"])
    }

    /// Shift-click selects from the anchor up to the photo clicked, whichever side it is.
    func testShiftClickSelectsTheRange() {
        var selection = PhotoSelection()
        selection.extend(from: 2, to: 5, in: photos)
        XCTAssertEqual(names(selection), ["c", "d", "e", "f"])
        selection.extend(from: 2, to: 0, in: photos)
        XCTAssertEqual(names(selection), ["a", "b", "c"])
    }

    /// ⌘-click or S adds or removes one photo; an added photo anchors the next run.
    func testToggleAddsRemovesAndAnchors() {
        var selection = PhotoSelection()
        selection.toggle(photos[0])
        selection.toggle(photos[3])
        XCTAssertEqual(names(selection), ["a", "d"])
        selection.extend(from: 1, to: 5, in: photos)
        XCTAssertEqual(names(selection), ["a", "d", "e", "f"])
        selection.toggle(photos[3])
        XCTAssertEqual(names(selection), ["a", "e", "f"])
        // Removing ends the run: the next one starts from the photo shown.
        selection.extend(from: 1, to: 2, in: photos)
        XCTAssertEqual(names(selection), ["a", "b", "c", "e", "f"])
    }

    /// At the end of the folder, ⇧→ still selects the photo shown.
    func testExtendAtTheEndSelectsTheCurrentPhoto() {
        var selection = PhotoSelection()
        selection.extend(from: 5, to: 5, in: photos)
        XCTAssertEqual(names(selection), ["f"])
    }

    /// An anchor deleted from the list starts a new run from the photo shown.
    func testMissingAnchorRestartsFromCurrent() {
        var selection = PhotoSelection()
        selection.extend(from: 0, to: 1, in: photos)
        let remaining = Array(photos.dropFirst())
        selection.extend(from: 2, to: 3, in: remaining)
        XCTAssertEqual(selection.photos(in: remaining).map(\.name), ["b", "d", "e"])
    }

    func testNewKeysDoNotCollide() {
        let map = ShortcutMap.defaults
        XCTAssertEqual(map.action(for: .code(124, modifiers: .shift)), .extendNext)
        XCTAssertEqual(map.action(for: .code(123, modifiers: .shift)), .extendPrevious)
        XCTAssertEqual(map.action(for: .character("s")), .toggleSelection)
        XCTAssertEqual(map.action(for: .code(115)), .first)
        XCTAssertEqual(map.action(for: .code(119)), .last)
        XCTAssertEqual(map.action(for: .character("-", modifiers: .command)), .zoomOut)
        for action in ShortcutAction.allCases {
            XCTAssertEqual(map.keys(for: action), action.defaultBindings, "\(action)")
        }
    }
}
