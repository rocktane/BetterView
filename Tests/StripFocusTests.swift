import AppKit
import XCTest
@testable import BetterView

/// The strip shows only while the photo's window has the focus, whatever asks for it.
@MainActor
final class StripFocusTests: XCTestCase {
    private var focused = true
    private var strip: StripPanel!
    private var viewer: NSWindow!

    override func setUp() async throws {
        viewer = NSWindow(contentRect: CGRect(x: 200, y: 300, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        viewer.isReleasedWhenClosed = false
        strip = StripPanel(placement: StripPlacement(origin: CGPoint(x: 100, y: 100), docked: false, centeredX: false), size: .standard)
        strip.save = { _, _ in }
        strip.viewer = viewer
        strip.viewerHasFocus = { [unowned self] in focused }
    }

    override func tearDown() async throws {
        strip.setVisible(false)
        viewer.orderOut(nil)
    }

    func testClickingAnotherWindowOfTheAppHidesTheStripAndComingBackShowsIt() {
        strip.setVisible(true)
        XCTAssertTrue(strip.isVisible)
        // The settings or the deletion history become key: the app stays active.
        focused = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: viewer)
        XCTAssertFalse(strip.isVisible)
        focused = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: viewer)
        XCTAssertTrue(strip.isVisible)
    }

    func testAnotherAppHidesTheStrip() {
        strip.setVisible(true)
        focused = false
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(strip.isVisible)
    }

    func testAnUpdateWithoutTheFocusDoesNotBringItBack() {
        // A strip update after a navigation, a zoom, a comparison or a screen change, once
        // another window has the focus: the panel used to be ordered front regardless.
        focused = false
        strip.setVisible(true)
        XCTAssertFalse(strip.isVisible)
        strip.fitToScreen()
        strip.followViewer()
        XCTAssertFalse(strip.isVisible)
        focused = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertTrue(strip.isVisible, "back as soon as the photo's window has the focus")
    }

    func testNotWantedStaysHiddenEvenWithTheFocus() {
        strip.setVisible(false)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: viewer)
        XCTAssertFalse(strip.isVisible)
    }

    func testTheStripNeverTakesTheKeyboardNorHidesByItself() {
        strip.setVisible(true)
        XCTAssertFalse(strip.view.window?.canBecomeKey ?? true)
        XCTAssertFalse((strip.view.window as? NSPanel)?.hidesOnDeactivate ?? true, "AppKit would show it again on reactivation")
    }

    func testTheDefaultRuleWantsTheAppActiveAndTheViewerKey() {
        let strip = StripPanel(placement: nil, size: .standard)
        strip.viewer = viewer
        XCTAssertEqual(strip.viewerHasFocus(), NSApp.isActive && viewer.isKeyWindow)
        strip.viewer = nil
        XCTAssertFalse(strip.viewerHasFocus(), "no photo window, no strip")
    }
}
