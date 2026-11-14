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

    func testALoneThumbnailIsAlwaysConfirmedBeforeTheTrash() {
        XCTAssertTrue(PhotoMenuTarget.confirmsDeletion(isSelection: false, asksForSelections: false), "the selections' setting does not cover it")
        XCTAssertTrue(PhotoMenuTarget.confirmsDeletion(isSelection: false, asksForSelections: true))
        XCTAssertFalse(PhotoMenuTarget.confirmsDeletion(isSelection: true, asksForSelections: false))
        XCTAssertTrue(PhotoMenuTarget.confirmsDeletion(isSelection: true, asksForSelections: true))
    }

    @MainActor
    func testEveryLightroomIsRecognisedWhereverItIsInstalled() {
        let elsewhere = URL(fileURLWithPath: "/Volumes/Apps/Lightroom.app")
        XCTAssertTrue(ExternalApps.App(url: elsewhere, name: "Lightroom", bundleIdentifier: "com.adobe.lightroomCC").isLightroom)
        XCTAssertTrue(ExternalApps.App(url: elsewhere, name: "Classic", bundleIdentifier: ExternalApps.lightroomClassic).isLightroom)
        XCTAssertFalse(ExternalApps.App(url: elsewhere, name: "Aperçu", bundleIdentifier: "com.apple.Preview").isLightroom)
        XCTAssertFalse(ExternalApps.App(url: elsewhere, name: "Sans identifiant", bundleIdentifier: nil).isLightroom)
    }

    /// A file replaced at the same path after the menu opened is not the photo the user chose:
    /// nothing is sent. The app named here does not exist, so nothing could open anyway.
    @MainActor
    func testAPhotoReplacedOnDiskIsNotSent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.arw")
        try Data("first".utf8).write(to: file)
        let seen = try XCTUnwrap(PhotoKey.read(path: file.path))
        try Data("replaced, and longer".utf8).write(to: file)

        let app = ExternalApps.App(url: directory.appendingPathComponent("Absente.app"), name: "Absente", bundleIdentifier: nil)
        let reported = expectation(description: "failure reported")
        var failure: ExternalApps.OpenFailure?
        ExternalApps.open([seen], with: app) {
            failure = $0
            reported.fulfill()
        }
        wait(for: [reported], timeout: 5)
        XCTAssertEqual(failure, .changed)
    }
}
