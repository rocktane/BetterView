import XCTest
@testable import BetterView

/// The viewer as a whole, on a temporary folder of stand-in files: nothing here decodes, it
/// checks what the controller does with the zoom and the overlays.
@MainActor
final class ViewerBehaviorTests: XCTestCase {
    private var root: URL!
    private var controller: ViewerController!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BVViewer-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a", "b", "c", "d"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent("\(name).arw"))
        }
        // Deletions go to a folder of the test, never to the real Trash.
        let trash = root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let session = LibrarySession(fileOps: FileOps(
            trash: { url in
                let destination = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            },
            restore: { try FileManager.default.moveItem(at: $0, to: $1) },
            deletePermanently: { try FileManager.default.removeItem(at: $0) }
        ))
        controller = ViewerController(session: session, diskDirectory: root.appendingPathComponent("cache"))
        // The default, whatever the user chose in the app's settings.
        controller.keepsZoomAcrossPhotos = { false }
        controller.session.open([folder])
        await spin { self.controller.session.list.count == 4 }
    }

    override func tearDown() async throws {
        controller?.window.orderOut(nil)
        controller = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), "timed out")
    }

    // MARK: Zoom across photos

    func testAnotherPhotoOpensFitted() {
        controller.view.toggleZoom(at: nil)
        XCTAssertTrue(controller.view.isZoomed)
        controller.step(1)
        XCTAssertFalse(controller.view.isZoomed, "next photo")
        controller.view.zoom(onNormalized: CGPoint(x: 0.2, y: 0.2), level: 2.5)
        controller.step(-1)
        XCTAssertFalse(controller.view.isZoomed, "previous photo, after a pinch")
        controller.view.toggleZoom(at: nil)
        controller.perform(.last)
        XCTAssertFalse(controller.view.isZoomed, "a jump")
    }

    func testDeletingWhileZoomedOpensTheNextFitted() async {
        let before = controller.session.list.current
        // Nothing decodes here: the error screen with its name makes the photo deletable.
        await spin { self.controller.visiblePhoto == before }
        controller.view.toggleZoom(at: nil)
        XCTAssertTrue(controller.view.isZoomed)
        controller.deleteCurrent()
        XCTAssertNotEqual(controller.session.list.current, before)
        XCTAssertFalse(controller.view.isZoomed)
        await spin { !self.controller.session.hasPendingIO }
    }

    func testTheAFModeEndsOnAnotherPhotoByDefault() {
        controller.zoomToFocus()
        XCTAssertTrue(controller.followsFocus)
        controller.step(1)
        XCTAssertFalse(controller.view.isZoomed)
        XCTAssertFalse(controller.followsFocus, "the next A starts it again")
    }

    func testTheSettingKeepsTheZoomAndItsPosition() {
        controller.keepsZoomAcrossPhotos = { true }
        controller.view.zoom(onNormalized: CGPoint(x: 0.2, y: 0.3), level: 2.5)
        controller.step(1)
        XCTAssertEqual(controller.view.zoom, 2.5)
        controller.perform(.last)
        XCTAssertEqual(controller.view.zoom, 2.5, "a jump too")
    }

    func testTheSettingKeepsTheAFModeOnEachPhoto() {
        controller.keepsZoomAcrossPhotos = { true }
        controller.zoomToFocus()
        controller.view.zoom(onNormalized: CGPoint(x: 0.5, y: 0.5), level: 2.5)
        controller.step(1)
        XCTAssertTrue(controller.followsFocus)
        XCTAssertEqual(controller.view.zoom, 2.5, "as before: the zoom carries over, recentred on the AF position")
        controller.zoomToFocus()
        XCTAssertFalse(controller.view.isZoomed)
        XCTAssertFalse(controller.followsFocus)
    }

    // MARK: Overlays on hover

    private var closeButton: NSButton { controller.window.standardWindowButton(.closeButton)! }

    private func buttonShown(_ button: NSButton) -> Bool { !button.isHidden && button.alphaValue == 1 }

    /// A window that changes shape under a still pointer asks again where it is. The answer
    /// is the same as before, but the buttons were hidden meanwhile (a late fade, AppKit):
    /// asking again must show them, not only a change of answer.
    func testAskingAgainShowsWhatDriftedAway() {
        var pointer: CGPoint?
        controller.view.pointerInWindow = { pointer }
        pointer = CGPoint(x: controller.view.bounds.midX, y: controller.view.bounds.midY)
        controller.view.refreshHover()
        XCTAssertTrue(controller.view.isHovered)
        XCTAssertTrue(buttonShown(closeButton))
        closeButton.isHidden = true
        controller.view.refreshHover()
        XCTAssertTrue(buttonShown(closeButton), "the pointer did not leave: the buttons are shown again")
    }

    /// Another window was found under the pointer (a tooltip, the app switcher, a banner):
    /// everything hid. It went away without any event. The next move on the photo shows it all.
    func testAMoveOnThePhotoShowsEverythingAgain() {
        controller.view.pointerInWindow = { nil }
        controller.view.refreshHover()
        XCTAssertFalse(controller.view.isHovered)
        XCTAssertTrue(closeButton.isHidden || closeButton.alphaValue == 0)
        controller.view.pointerMoved(toWindowPoint: CGPoint(x: controller.view.bounds.midX, y: controller.view.bounds.midY))
        XCTAssertTrue(controller.view.isHovered)
        XCTAssertTrue(buttonShown(closeButton))
    }

    func testTheInformationFollowsTheSameRule() {
        let view = ViewerView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.pointerInWindow = { CGPoint(x: 450, y: 300) }
        view.setInfo(name: "A.arw", settings: "", date: "", position: "1 / 4")
        view.refreshHover()
        XCTAssertTrue(view.overlaysShown)
        view.pointerInWindow = { nil }
        view.refreshHover()
        XCTAssertFalse(view.isHovered)
        view.pointerMoved(toWindowPoint: CGPoint(x: 450, y: 300))
        XCTAssertTrue(view.overlaysShown, "shown at once, whatever the fade-out left")
    }

    /// A fade-out still running when the pointer comes back must not hide the view at its end.
    func testALateFadeOutDoesNotHideAViewShownSince() async {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        view.wantsLayer = true
        view.fade(visible: false)
        view.fade(visible: true)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(view.isHidden)
        XCTAssertEqual(view.alphaValue, 1)
    }

    // MARK: AF in the comparison

    func testAInTheComparisonFollowsEachAFPositionAndTogglesBack() {
        controller.perform(.compare)
        XCTAssertNil(controller.comparisonView.zoom)
        controller.perform(.zoomToFocus)
        XCTAssertEqual(controller.comparisonView.zoom, 1)
        XCTAssertTrue(controller.comparisonView.followsFocus)
        controller.perform(.zoomToFocus)
        XCTAssertNil(controller.comparisonView.zoom, "same key to leave")
        XCTAssertFalse(controller.comparisonView.followsFocus)
        controller.perform(.toggleZoom)
        XCTAssertFalse(controller.comparisonView.followsFocus, "Z keeps one point for all")
        controller.perform(.zoomToFocus)
        XCTAssertTrue(controller.comparisonView.followsFocus, "from Z to A")
        controller.perform(.exit)
        XCTAssertNil(controller.comparisonView.zoom)
        XCTAssertFalse(controller.comparisonView.followsFocus)
    }

    // MARK: Comparison, mouse only

    private func compareAll() async {
        controller.perform(.compare)
        await spin { self.controller.comparisonView.slotsShowingPhotos.count >= 2 }
    }

    func testNoKeyKeepsDeletesOrPicksAPhotoInTheComparison() async {
        await compareAll()
        let before = controller.session.list.photos
        let current = controller.session.list.current
        for action in [ShortcutAction.delete, .next, .previous, .jumpForward] {
            XCTAssertFalse(controller.isAvailable(action), action.rawValue)
            controller.perform(action)
        }
        XCTAssertEqual(controller.session.list.photos, before, "nothing deleted")
        XCTAssertEqual(controller.session.list.current, current, "nothing picked")
        for action in [ShortcutAction.undo, .toggleZoom, .zoomToFocus, .exit, .compare] {
            XCTAssertTrue(controller.isAvailable(action), action.rawValue)
        }
    }

    func testTheTrashButtonDeletesItsOwnPhoto() async {
        await compareAll()
        let second = controller.comparisonView.photo(inSlot: 1)
        XCTAssertNotNil(second)
        // The error screen with its name counts as visible: it is what a deletion would hit.
        await spin { self.controller.comparedVisible.contains(1) }
        controller.comparisonView.onCommand(.slotAction(.trash, slot: 1, photo: second))
        XCTAssertFalse(controller.session.list.photos.contains(second!))
        await spin { !self.controller.session.hasPendingIO }
    }
}
