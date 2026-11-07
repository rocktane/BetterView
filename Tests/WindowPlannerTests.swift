import XCTest
@testable import BetterView

final class WindowPlannerTests: XCTestCase {
    private func position(_ items: [PlanItem], _ index: Int, _ tier: Tier) -> Int? {
        items.firstIndex { $0.index == index && $0.tier == tier }
    }

    func testVisibleDemandComesFirstAndZoomBeatsSpeculation() {
        var input = PlanInput(count: 100, current: 50)
        input.zoomed = true
        let items = WindowPlanner.plan(input)
        XCTAssertEqual(Array(items.prefix(3).map(\.tier)), [.preview, .screen, .full])
        XCTAssertTrue(items.prefix(3).allSatisfy { $0.index == 50 && $0.visible })
        XCTAssertEqual(items.filter(\.visible).count, 3)
    }

    func testNoDuplicatesAndStaysInBounds() {
        for current in [0, 1, 50, 98, 99] {
            var input = PlanInput(count: 100, current: current)
            input.idle = true
            input.focused = true
            let items = WindowPlanner.plan(input)
            XCTAssertEqual(Set(items.map { "\($0.index)-\($0.tier)" }).count, items.count)
            XCTAssertTrue(items.allSatisfy { $0.index >= 0 && $0.index < 100 })
        }
    }

    func testDirectionFavoursTravel() {
        var input = PlanInput(count: 100, current: 50)
        input.direction = -1
        let items = WindowPlanner.plan(input)
        XCTAssertNotNil(position(items, 30, .screen))
        XCTAssertNil(position(items, 70, .screen))
        XCTAssertLessThan(position(items, 49, .screen)!, position(items, 51, .screen)!)
    }

    func testHeldKeyOnlyPlansPreviews() {
        var input = PlanInput(count: 100, current: 50)
        input.repeating = true
        input.settled = false
        let items = WindowPlanner.plan(input)
        XCTAssertTrue(items.allSatisfy { $0.tier == .preview })

        input.settled = true
        let settled = WindowPlanner.plan(input)
        XCTAssertEqual(settled.filter { $0.tier == .screen }.map(\.index), [50])
    }

    func testBackgroundOnlyWhenIdleAndAtTheEnd() {
        var input = PlanInput(count: 100, current: 50)
        XCTAssertFalse(WindowPlanner.plan(input).contains { $0.background })
        input.idle = true
        let items = WindowPlanner.plan(input)
        let firstBackground = items.firstIndex { $0.background }!
        XCTAssertTrue(items[firstBackground...].allSatisfy { $0.background && $0.tier == .screen })
        XCTAssertEqual(Set(items.filter { $0.tier == .screen }.map(\.index)).count, 100)
    }

    func testMemoryPressureReducesAdmission() {
        var input = PlanInput(count: 100, current: 50)
        input.idle = true
        input.focused = true
        input.memory = .warning
        let warned = WindowPlanner.plan(input)
        XCTAssertFalse(warned.contains { $0.background })
        XCTAssertFalse(warned.contains { $0.tier == .full })
        XCTAssertTrue(warned.allSatisfy { abs($0.index - 50) <= 3 })

        input.memory = .critical
        XCTAssertTrue(WindowPlanner.plan(input).allSatisfy { $0.index == 50 })
    }

    func testFocusDwellPreparesFullResolution() {
        var input = PlanInput(count: 100, current: 50)
        XCTAssertNil(position(WindowPlanner.plan(input), 50, .full))
        input.focused = true
        let items = WindowPlanner.plan(input)
        XCTAssertNotNil(position(items, 50, .full))
        XCTAssertNotNil(position(items, 51, .full))
        XCTAssertLessThan(position(items, 50, .full)!, position(items, 60, .screen)!, "a focus check beats distant photos")
    }
}
