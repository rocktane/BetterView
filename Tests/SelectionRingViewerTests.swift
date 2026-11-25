import AppKit
import XCTest
@testable import BetterView

/// The rings in the real controller: they follow the photos checked that are still there.
@MainActor
final class SelectionRingViewerTests: XCTestCase {
    private var root: URL!
    private var controller: ViewerController!
    private var strip: StripPanel!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BVRings-\(UUID().uuidString)")
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
        strip = Mirror(reflecting: controller!).children.first { $0.label == "strip" }?.value as? StripPanel
        strip.isAppActive = { true }
        strip.save = { _, _ in }
        controller.window.orderFront(nil)
        controller.session.open([folder])
        await spin { self.controller.session.list.count == 4 }
    }

    override func tearDown() async throws {
        strip?.setVisible(false)
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

    func testDeletingTheOnlyCheckedPhotoTakesTheRingsAway() async {
        let before = controller.session.list.current
        await spin { self.controller.visiblePhoto == before }
        controller.perform(.toggleSelection)
        await spin { self.strip.view.cornerMarks.contains(.ring) }
        controller.deleteCurrent()
        await spin { !self.controller.session.hasPendingIO }
        await spin { !self.strip.view.cornerMarks.isEmpty && !self.strip.view.cornerMarks.contains(.ring) }
        XCTAssertFalse(strip.view.cornerMarks.contains(.check))
    }

    func testSpaceDoesNothingInTheComparison() async throws {
        let before = controller.session.list.current
        await spin { self.controller.visiblePhoto == before }
        controller.perform(.compare)
        let comparison = { Mirror(reflecting: self.controller!).children.first { $0.label == "comparison" }?.value as? ComparisonModel }
        let selection = { Mirror(reflecting: self.controller!).children.first { $0.label == "selection" }?.value as? PhotoSelection }
        XCTAssertNotNil(comparison())
        let focused = comparison()?.focused
        let decision = controller.view.shortcuts.decide(.code(49), isRepeat: false)
        XCTAssertEqual(decision, .perform(.toggleSelection, repeating: false))
        controller.perform(.toggleSelection)
        XCTAssertEqual(comparison()?.focused, focused, "no move")
        XCTAssertEqual(selection()?.isEmpty, true, "no selection in this view")
        controller.perform(.exit)
    }
}
