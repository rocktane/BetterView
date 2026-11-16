import AppKit
import XCTest
@testable import BetterView

@MainActor
final class AutoComparisonTests: XCTestCase {
    private func frame(_ side: Int) -> Frame {
        Frame(key: FrameKey(photo: photo("a"), tier: .screen),
              surface: PixelFormat.makeSurface(width: side, height: side)!,
              nativeSize: CGSize(width: 6000, height: 4000))
    }

    func testSeparatorKeepsBothVersionsAlignedThroughZoomAndResize() {
        let view = ViewerView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        view.show(frame(64), auto: frame(32))
        view.moveAutoDivider(to: 225)
        XCTAssertEqual(view.autoSplitFraction, 0.25)
        XCTAssertEqual(view.autoComparisonFrames.clip.minX, 225)
        XCTAssertEqual(view.autoComparisonFrames.original, view.autoComparisonFrames.enhanced)
        view.zoom(onNormalized: CGPoint(x: 0.2, y: 0.7), level: 2)
        XCTAssertEqual(view.autoComparisonFrames.original, view.autoComparisonFrames.enhanced)
        XCTAssertEqual(view.autoComparisonFrames.clip.minX, 225, "zoom leaves divider in viewport coordinates")
        let beforePan = view.autoComparisonFrames.original
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                             wheel1: 40, wheel2: 70, wheel3: 0)!
        view.scrollWheel(with: NSEvent(cgEvent: scroll)!)
        XCTAssertNotEqual(view.autoComparisonFrames.original, beforePan)
        XCTAssertEqual(view.autoComparisonFrames.original, view.autoComparisonFrames.enhanced)
        view.setFrameSize(CGSize(width: 1200, height: 800))
        view.layout()
        XCTAssertEqual(view.autoComparisonFrames.clip.minX, 300)
        XCTAssertEqual(view.autoComparisonFrames.original, view.autoComparisonFrames.enhanced)
    }

    func testAutoCardIsBelowPhotoInformation() throws {
        let view = ViewerView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        view.pointerInWindow = { CGPoint(x: 450, y: 300) }
        view.setInfo(name: "photo.arw", settings: "ISO 100", date: "Aujourd’hui", position: "1 / 2")
        view.setAutoPreview(available: true, active: false, busy: false)
        view.refreshHover()
        view.layoutSubtreeIfNeeded()
        let card = try XCTUnwrap(view.subviews.first { panel in
            panel.subviews.contains { ($0 as? NSButton)?.accessibilityIdentifier() == "autoPreview" }
        })
        let info = try XCTUnwrap(view.subviews.first { panel in
            panel.subviews.contains { ($0 as? NSTextField)?.stringValue == "photo.arw" }
        })
        let button = try XCTUnwrap(card.subviews.first as? NSButton)
        XCTAssertEqual(button.title, "Amélioration auto")
        XCTAssertNotNil(button.image)
        XCTAssertFalse(card.isHidden)
        XCTAssertLessThan(card.frame.maxY, info.frame.minY)
    }

    func testSpaceVersionsAndReturningToSplitKeepZoomAndPosition() {
        let view = ViewerView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        let original = frame(64), auto = frame(32)
        view.show(original, auto: auto)
        view.moveAutoDivider(to: 300)
        view.zoom(onNormalized: CGPoint(x: 0.3, y: 0.6), level: 1)
        let rect = view.autoComparisonFrames.original
        view.toggleAutoVersion()
        XCTAssertEqual(view.autoDisplayMode, .original)
        view.toggleAutoVersion()
        XCTAssertEqual(view.autoDisplayMode, .enhanced)
        XCTAssertEqual(view.autoComparisonFrames.clip.minX, 0)
        XCTAssertEqual(view.autoComparisonFrames.original, view.autoComparisonFrames.enhanced)
        view.show(original, auto: auto) // A pipeline refresh must not reset the chosen version.
        XCTAssertEqual(view.autoDisplayMode, .enhanced)
        view.restoreAutoSplit()
        XCTAssertEqual(view.autoDisplayMode, .split)
        XCTAssertEqual(view.autoSplitFraction, 1 / 3, accuracy: 0.001)
        XCTAssertEqual(view.autoComparisonFrames.original, rect)
        XCTAssertEqual(view.zoom, 1)
        view.show(original) // Navigation/original display releases the comparison.
        view.toggleAutoVersion()
        XCTAssertEqual(view.autoDisplayMode, .split)
    }
}
