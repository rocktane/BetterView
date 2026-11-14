import AppKit
import XCTest
@testable import BetterView

/// The strip shows while BetterView is active and the photo's window is on screen, whatever
/// window of the app has the focus, and never over another app.
@MainActor
final class StripFocusTests: XCTestCase {
    private var active = true
    private var strip: StripPanel!
    private var viewer: NSWindow!
    private var other: NSWindow!

    override func setUp() async throws {
        viewer = NSWindow(contentRect: CGRect(x: 200, y: 300, width: 600, height: 400), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        viewer.isReleasedWhenClosed = false
        other = NSWindow(contentRect: CGRect(x: 300, y: 350, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        viewer.orderFront(nil)
        strip = StripPanel(placement: StripPlacement(origin: CGPoint(x: 100, y: 100), docked: false, centeredX: false), size: .standard)
        strip.save = { _, _ in }
        strip.viewer = viewer
        strip.isAppActive = { [unowned self] in active }
    }

    override func tearDown() async throws {
        strip.setVisible(false)
        viewer.orderOut(nil)
        other.orderOut(nil)
    }

    func testAnotherWindowOfTheAppKeepsTheStrip() {
        strip.setVisible(true)
        XCTAssertTrue(strip.isVisible)
        // The settings, the history or a dialog take the focus: the app stays active.
        other.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: viewer)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: other)
        XCTAssertTrue(strip.isVisible)
    }

    func testAnotherAppHidesTheStripAndComingBackShowsIt() {
        strip.setVisible(true)
        active = false
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        XCTAssertFalse(strip.isVisible)
        active = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertTrue(strip.isVisible)
    }

    func testAnUpdateWhileInactiveDoesNotBringItBack() {
        // The original fault: launched or updated in the background, the panel floated over
        // the other apps.
        active = false
        strip.setVisible(true)
        XCTAssertFalse(strip.isVisible)
        strip.fitToScreen()
        strip.followViewer()
        XCTAssertFalse(strip.isVisible)
        active = true
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertTrue(strip.isVisible, "back as soon as the app is active")
    }

    func testWithoutThePhotosWindowOnScreenTheStripStaysHidden() {
        viewer.orderOut(nil)
        strip.setVisible(true)
        XCTAssertFalse(strip.isVisible, "closed")
        viewer.orderFront(nil)
        strip.setVisible(true)
        XCTAssertTrue(strip.isVisible)
        strip.viewer = nil
        strip.setVisible(false)
        strip.setVisible(true)
        XCTAssertFalse(strip.isVisible, "no photo window, no strip")
    }

    func testNotWantedStaysHiddenEvenWhenActive() {
        strip.setVisible(false)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        XCTAssertFalse(strip.isVisible)
    }

    func testTheStripNeverTakesTheKeyboardNorHidesByItself() {
        strip.setVisible(true)
        XCTAssertFalse(strip.view.window?.canBecomeKey ?? true)
        XCTAssertFalse((strip.view.window as? NSPanel)?.hidesOnDeactivate ?? true, "AppKit would show it again on reactivation")
    }

    func testTheDefaultRuleIsTheActiveApp() {
        let strip = StripPanel(placement: nil, size: .standard)
        strip.viewer = viewer
        XCTAssertEqual(strip.mayShow, NSApp.isActive)
    }
}
