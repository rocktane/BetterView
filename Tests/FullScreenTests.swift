import AppKit
import XCTest
@testable import BetterView

final class FullScreenLayoutTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)

    func testALandscapePhotoFitsAboveTheStrip() {
        let frame = FullScreenContainer.contentFrame(in: screen, bottomInset: 82, aspect: 1.5)
        XCTAssertEqual(frame.minY, 82, "never under the strip")
        XCTAssertEqual(frame.height, 1169 - 82)
        XCTAssertEqual(frame.width, ((1169 - 82) * 1.5).rounded())
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.5)
    }

    func testAPanoramaFitsTheWidth() {
        let frame = FullScreenContainer.contentFrame(in: screen, bottomInset: 82, aspect: 3)
        XCTAssertEqual(frame.width, 1800)
        XCTAssertEqual(frame.height, 600)
        XCTAssertEqual(frame.midY, 82 + (1169 - 82) / 2, accuracy: 0.5, "centred in the room above the strip")
    }

    func testWithoutTheStripThePhotoTakesTheWholeScreen() {
        let frame = FullScreenContainer.contentFrame(in: screen, bottomInset: 0, aspect: 2 / 3)
        XCTAssertEqual(frame.height, 1169)
        XCTAssertEqual(frame.minY, 0)
    }

    func testTheComparisonFillsTheRoom() {
        XCTAssertEqual(FullScreenContainer.contentFrame(in: screen, bottomInset: 82, aspect: nil), CGRect(x: 0, y: 82, width: 1800, height: 1087))
    }
}

@MainActor
final class FullScreenContainerTests: XCTestCase {
    func testTheContentIsClippedThereAndGivenBackAsItWas() {
        let container = FullScreenContainer(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169))
        let photo = NSView(frame: .zero)
        photo.wantsLayer = true
        container.content = photo
        XCTAssertEqual(photo.layer?.masksToBounds, true, "a zoomed photo stays within its frame")
        container.content = nil
        XCTAssertEqual(photo.layer?.masksToBounds, false, "back in the window as it was")
    }
}

@MainActor
final class StripFullScreenTests: XCTestCase {
    func testTheStripSpansTheBottomAndComesBackToItsPlace() {
        let strip = StripPanel(placement: StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false), size: StripSize(width: 700, height: 122))
        strip.save = { _, _ in XCTFail("full screen saves nothing") }
        strip.fitToScreen()
        let before = strip.frame
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        strip.setFullScreen(screen)
        XCTAssertEqual(strip.frame, CGRect(x: 0, y: 0, width: 1800, height: 122), "the whole width, at the bottom, at the size chosen")
        XCTAssertEqual(strip.fullScreenHeight(on: screen), 122)
        XCTAssertNil(strip.view.onDrag, "no moving in full screen")
        XCTAssertNil(strip.view.onResize, "nor stretching")
        XCTAssertTrue(strip.view.window?.collectionBehavior.contains(.fullScreenAuxiliary) ?? false, "it shows in the full screen space")
        XCTAssertEqual(strip.view.layer?.borderWidth, 0, "no light border")
        XCTAssertEqual(strip.view.layer?.cornerRadius, 0, "nor rounded corners")
        XCTAssertEqual(strip.view.window?.hasShadow, false, "nor shadow")
        strip.setFullScreen(nil)
        XCTAssertEqual(strip.frame, before, "back to its own place and size")
        XCTAssertEqual(strip.view.layer?.borderWidth, 1, "the window strip looks as before")
        XCTAssertEqual(strip.view.layer?.cornerRadius, 12)
        XCTAssertEqual(strip.view.window?.hasShadow, true)
        XCTAssertNotNil(strip.view.onDrag)
        XCTAssertNotNil(strip.view.onResize)
        XCTAssertFalse(strip.view.window?.collectionBehavior.contains(.fullScreenAuxiliary) ?? true)
    }
}

/// The controller's side, driven through its window delegate: the screen is never taken over.
@MainActor
final class ViewerFullScreenTests: XCTestCase {
    private var root: URL!
    private var controller: ViewerController!
    private var left = 0

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BVFullScreen-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["a", "b", "c"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent("\(name).arw"))
        }
        controller = ViewerController(session: LibrarySession(), diskDirectory: root.appendingPathComponent("cache"))
        controller.leaveFullScreen = { [unowned self] in left += 1 }
        controller.session.open([folder])
        let deadline = Date().addingTimeInterval(5)
        while controller.session.list.count < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    override func tearDown() async throws {
        controller?.window.orderOut(nil)
        controller = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func note(_ name: Notification.Name) -> Notification { Notification(name: name, object: controller.window) }

    func testThePhotoGoesIntoTheContainerAndComesBack() {
        let frame = controller.window.frame
        controller.windowWillEnterFullScreen(note(NSWindow.willEnterFullScreenNotification))
        let container = controller.fullScreenContainer
        XCTAssertNotNil(container)
        XCTAssertTrue(controller.window.contentView === container)
        XCTAssertTrue(container?.content === controller.view)
        controller.windowDidEnterFullScreen(note(NSWindow.didEnterFullScreenNotification))
        controller.windowWillExitFullScreen(note(NSWindow.willExitFullScreenNotification))
        controller.windowDidExitFullScreen(note(NSWindow.didExitFullScreenNotification))
        XCTAssertNil(controller.fullScreenContainer)
        XCTAssertTrue(controller.window.contentView === controller.view)
        XCTAssertEqual(controller.window.frame.size, frame.size, "nothing kept from the screen's size")
    }

    func testEscapeLeavesFullScreenOnlyWhenNothingElseIsLeft() {
        controller.windowWillEnterFullScreen(note(NSWindow.willEnterFullScreenNotification))
        controller.perform(.toggleSelection)
        controller.perform(.exit)
        XCTAssertEqual(left, 0, "the selection first")
        controller.perform(.exit)
        XCTAssertEqual(left, 1, "then full screen")
    }

    func testAScreenChangeMovesTheStripWithIt() throws {
        let strip = try XCTUnwrap(Mirror(reflecting: controller!).children.first { $0.label == "strip" }?.value as? StripPanel)
        controller.windowWillEnterFullScreen(note(NSWindow.willEnterFullScreenNotification))
        controller.windowDidEnterFullScreen(note(NSWindow.didEnterFullScreenNotification))
        let screen = try XCTUnwrap(controller.window.screen?.frame)
        // As if the screen had been another size when full screen began.
        strip.setFullScreen(CGRect(x: 0, y: 0, width: 640, height: 480))
        controller.windowDidChangeScreen(note(NSWindow.didChangeScreenNotification))
        XCTAssertEqual(strip.fullScreenFrame, screen)
        XCTAssertEqual(strip.frame.width, screen.width)
        controller.windowWillExitFullScreen(note(NSWindow.willExitFullScreenNotification))
        controller.windowDidExitFullScreen(note(NSWindow.didExitFullScreenNotification))
    }

    func testOutsideFullScreenEscapeDoesNotLeaveIt() {
        controller.perform(.exit)
        XCTAssertEqual(left, 0)
    }
}
