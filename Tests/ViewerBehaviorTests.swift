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
        controller.view.toggleZoom(at: nil)
        let before = controller.session.list.current
        // Nothing decodes here: the error screen with its name makes the photo deletable.
        await spin { self.controller.visiblePhoto == before }
        controller.view.toggleZoom(at: nil)
        controller.deleteCurrent()
        XCTAssertNotEqual(controller.session.list.current, before)
        XCTAssertFalse(controller.view.isZoomed)
        await spin { !self.controller.session.hasPendingIO }
    }

    func testTheAFModeStaysAt100PercentOnEachPhoto() {
        controller.zoomToFocus()
        XCTAssertTrue(controller.followsFocus)
        controller.view.zoom(onNormalized: CGPoint(x: 0.5, y: 0.5), level: 2.5)
        controller.step(1)
        XCTAssertTrue(controller.followsFocus)
        XCTAssertEqual(controller.view.zoom, 1, "a pinch does not carry over to the next photo")
        controller.zoomToFocus()
        XCTAssertFalse(controller.view.isZoomed)
        XCTAssertFalse(controller.followsFocus)
    }
}
