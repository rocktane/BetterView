import XCTest
@testable import BetterView

final class PhotoMenuTargetTests: XCTestCase {
    private let folder = ["a", "b", "c", "d", "e"].map { photo($0) }

    func testASelectedPhotoActsOnTheWholeSelection() {
        let selection = [folder[1], folder[3]]
        let target = PhotoMenuTarget(clicked: folder[3], selection: selection, folder: folder)
        XCTAssertEqual(target.photos, selection)
        XCTAssertTrue(target.isSelection)
        XCTAssertEqual(target.otherSelection, [], "already the target")
        XCTAssertEqual(target.folder, folder)
    }

    func testAnUnselectedPhotoActsAloneAndOffersTheSelection() {
        let selection = [folder[1], folder[3]]
        let target = PhotoMenuTarget(clicked: folder[0], selection: selection, folder: folder)
        XCTAssertEqual(target.photos, [folder[0]])
        XCTAssertFalse(target.isSelection)
        XCTAssertEqual(target.otherSelection, selection)
    }

    func testAOnePhotoSelectionIsNotASecondTarget() {
        let target = PhotoMenuTarget(clicked: folder[2], selection: [folder[2]], folder: folder)
        XCTAssertEqual(target.photos, [folder[2]])
        XCTAssertFalse(target.isSelection)
        XCTAssertEqual(target.otherSelection, [])
    }

    func testTheFolderIsOfferedOnlyWhenItIsMore() {
        let alone = [folder[0]]
        XCTAssertEqual(PhotoMenuTarget(clicked: folder[0], selection: [], folder: alone).folder, [])
        let all = PhotoMenuTarget(clicked: folder[0], selection: folder, folder: folder)
        XCTAssertEqual(all.photos, folder)
        XCTAssertEqual(all.folder, [], "the selection is already the whole folder")
    }

    func testTitles() {
        let app = "Adobe Lightroom Classic"
        XCTAssertEqual(PhotoMenuTarget.openTitle(app: app, count: 1), "Ouvrir dans Adobe Lightroom Classic…")
        XCTAssertEqual(PhotoMenuTarget.openTitle(app: app, count: 3, selected: true), "Ouvrir les 3 photos sélectionnées dans Adobe Lightroom Classic…")
        XCTAssertEqual(PhotoMenuTarget.openTitle(app: app, count: 1, selected: true), "Ouvrir la photo sélectionnée dans Adobe Lightroom Classic…")
        XCTAssertEqual(PhotoMenuTarget.openTitle(app: app, count: 248, folder: true), "Ouvrir les 248 photos du dossier dans Adobe Lightroom Classic…")
    }
}
