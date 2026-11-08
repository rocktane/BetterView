import XCTest
@testable import BetterView

private func photo(_ name: String, revision: Int = 0) -> PhotoKey {
    PhotoKey(path: "/photos/\(name).arw", device: 1, inode: 1, size: 1, mtimeSeconds: revision, mtimeNanoseconds: 0)
}

private func photos(_ names: String...) -> [PhotoKey] { names.map { photo($0) } }

final class PhotoGroupsTests: XCTestCase {
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testPhotosTakenCloseTogetherFormARun() {
        let dates: [Date?] = [date(0), date(100), date(101), date(103), date(200)]
        XCTAssertEqual(PhotoGroups.bursts(dates: dates), [1...3])
    }

    func testTheGapIsInclusiveAndAWiderOneSplits() {
        XCTAssertEqual(PhotoGroups.bursts(dates: [date(0), date(2)]), [0...1])
        XCTAssertEqual(PhotoGroups.bursts(dates: [date(0), date(3)]), [])
    }

    func testARunReachingTheEndIsKept() {
        XCTAssertEqual(PhotoGroups.bursts(dates: [date(0), date(50), date(51)]), [1...2])
    }

    func testAPhotoWithoutADateBreaksTheRun() {
        XCTAssertEqual(PhotoGroups.bursts(dates: [date(0), nil, date(1)]), [])
        XCTAssertEqual(PhotoGroups.bursts(dates: []), [])
        XCTAssertEqual(PhotoGroups.bursts(dates: [nil, nil]), [])
    }
}

final class ComparisonModelTests: XCTestCase {
    func testOnePhotoIsNotAComparison() {
        XCTAssertNil(ComparisonModel(photos: photos("a"), focusing: nil))
    }

    func testFourShownAndTheRestWaiting() throws {
        let model = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c", "d", "e"), focusing: photo("c")))
        XCTAssertEqual(model.shown, photos("a", "b", "c", "d"))
        XCTAssertEqual(model.waiting, photos("e"))
        XCTAssertEqual(model.focused, photo("c"))
    }

    func testTheNextPhotoTakesTheSlotAndTheOthersStay() throws {
        var model = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c", "d", "e"), focusing: photo("b")))
        model.remove(photos("b"))
        XCTAssertEqual(model.slots, [photo("a"), photo("e"), photo("c"), photo("d")])
        XCTAssertEqual(model.focused, photo("e"), "the focus stays on the slot")
        XCTAssertEqual(model.remaining, 4)
    }

    func testLosingOneOfFourMovesNothingButTwoShareTheSpace() throws {
        var model = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c", "d"), focusing: nil))
        XCTAssertEqual(model.layout, [0, 1, 2, 3])
        model.remove(photos("b"))
        XCTAssertEqual(model.layout, [0, 1, 2, 3], "the empty cell stays")
        model.remove(photos("a"))
        XCTAssertEqual(model.layout, [2, 3])
    }

    func testKeepingOnlyTouchesWhatIsOnScreen() throws {
        var model = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c", "d", "e", "f"), focusing: photo("b")))
        XCTAssertEqual(model.shownOthers, photos("a", "c", "d"))
        model.remove(model.shownOthers)
        XCTAssertEqual(model.slots, [photo("e"), photo("b"), photo("f"), nil])
        XCTAssertEqual(model.focused, photo("b"))
        XCTAssertEqual(model.remaining, 3, "the two waiting photos come in unseen, not deleted")
    }

    func testTheFocusLeavesAnEmptiedSlot() throws {
        var model = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c"), focusing: photo("c")))
        model.remove(photos("c"))
        XCTAssertEqual(model.focused, photo("a"))
    }

    func testFocusSkipsEmptySlotsBothWays() throws {
        var model = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c", "d"), focusing: nil))
        model.remove(photos("b"))
        model.moveFocus(by: 1)
        XCTAssertEqual(model.focused, photo("c"))
        model.moveFocus(by: -1)
        XCTAssertEqual(model.focused, photo("a"))
        model.moveFocus(by: -1)
        XCTAssertEqual(model.focused, photo("d"), "it wraps around")
        model.setFocus(slot: 1)
        XCTAssertEqual(model.focused, photo("d"), "an empty slot cannot take the focus")
    }

    func testUndoingAKeepRestoresTheExactArrangement() throws {
        let original = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c", "d", "e"), focusing: photo("b")))
        var model = original
        let others = model.shownOthers
        model.remove(others)
        for removed in others.reversed() { XCTAssertTrue(model.restore(removed)) }
        XCTAssertEqual(model.slots, original.slots)
        XCTAssertEqual(model.waiting, original.waiting)
    }

    /// Undo during a deletion restores in deletion order, not in reverse.
    func testUndoingAKeepGivesTheSameResultInAnyOrder() throws {
        let original = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c", "d", "e", "f", "g", "h"), focusing: photo("b")))
        var model = original
        let others = model.shownOthers
        model.remove(others)
        for removed in others { XCTAssertTrue(model.restore(removed)) }
        XCTAssertEqual(model.slots, original.slots)
        XCTAssertEqual(model.waiting, photos("e", "f", "g", "h"))
    }

    func testAFailedDeletionComesBackToItsSlot() throws {
        var model = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c", "d", "e"), focusing: photo("a")))
        model.remove(photos("a"))
        XCTAssertEqual(model.slots[0], photo("e"))
        // The session puts it back in the list when the trash refuses it.
        model.reconcile(with: photos("a", "b", "c", "d", "e"))
        XCTAssertEqual(model.slots, [photo("a"), photo("b"), photo("c"), photo("d")])
        XCTAssertEqual(model.waiting, photos("e"))
    }

    func testAFileChangedDuringItsDeletionComesBackWithItsNewRevision() throws {
        var model = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c"), focusing: nil))
        model.remove(photos("a"))
        model.reconcile(with: [photo("a", revision: 1), photo("b"), photo("c")])
        XCTAssertEqual(model.slots[0], photo("a", revision: 1))
        XCTAssertEqual(model.members[0], photo("a", revision: 1))
    }

    /// Trash refused, then the permanent deletion the user confirmed fails too.
    func testAFailedPermanentDeletionAlsoComesBack() throws {
        var model = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c", "d", "e"), focusing: photo("a")))
        model.remove(photos("a"))
        model.reconcile(with: photos("a", "b", "c", "d", "e"))
        model.remove(photos("a"))
        model.reconcile(with: photos("b", "c", "d", "e"))
        XCTAssertEqual(model.slots[0], photo("e"))
        model.reconcile(with: photos("a", "b", "c", "d", "e"))
        XCTAssertEqual(model.slots, [photo("a"), photo("b"), photo("c"), photo("d")])
    }

    func testARemovedPhotoStaysOutWhileTheListDoesNotHaveIt() throws {
        var model = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c"), focusing: nil))
        model.remove(photos("a"))
        model.reconcile(with: photos("b", "c"))
        XCTAssertEqual(model.shown, photos("b", "c"))
        XCTAssertEqual(model.remaining, 2)
    }

    func testRestoringAPhotoItDidNotRemoveChangesNothing() throws {
        var model = try XCTUnwrap(ComparisonModel(photos: photos("a", "b"), focusing: nil))
        XCTAssertFalse(model.restore(photo("z")))
        XCTAssertEqual(model.shown, photos("a", "b"))
    }

    func testFollowsTheFolder() throws {
        var model = try XCTUnwrap(ComparisonModel(photos: photos("a", "b", "c", "d", "e"), focusing: photo("a")))
        // a is replaced on disk, b disappears, and e waits to take over.
        model.reconcile(with: [photo("a", revision: 1), photo("c"), photo("d"), photo("e")])
        XCTAssertEqual(model.slots, [photo("a", revision: 1), photo("e"), photo("c"), photo("d")])
        XCTAssertEqual(model.focused, photo("a", revision: 1))
        XCTAssertEqual(model.waiting, [])
    }
}

final class StripMagnetTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let bottomDock = CGRect(x: 0, y: 80, width: 1512, height: 870)
    private let leftDock = CGRect(x: 70, y: 0, width: 1442, height: 950)
    private let size = CGSize(width: 763, height: 92)

    private func snap(x: CGFloat, y: CGFloat, visible: CGRect) -> (origin: CGPoint, placement: StripPlacement) {
        StripMagnet.snap(proposed: CGRect(origin: CGPoint(x: x, y: y), size: size), screen: screen, visible: visible)
    }

    func testFindsTheDock() {
        XCTAssertEqual(StripMagnet.dockEdge(screen: screen, visible: bottomDock), .bottom)
        XCTAssertEqual(StripMagnet.dockEdge(screen: screen, visible: leftDock), .left)
        XCTAssertEqual(StripMagnet.dockEdge(screen: screen, visible: CGRect(x: 0, y: 0, width: 1440, height: 950)), .right)
        XCTAssertEqual(StripMagnet.dockEdge(screen: screen, visible: CGRect(x: 0, y: 4, width: 1512, height: 946)), .bottom, "a hidden Dock")
    }

    func testNearTheDockItIsCaught() {
        let result = snap(x: 100, y: 80 + 8 + 30, visible: bottomDock)
        XCTAssertEqual(result.origin, CGPoint(x: 100, y: 88))
        XCTAssertTrue(result.placement.docked)
        XCTAssertFalse(result.placement.centeredX)
    }

    func testPushedIntoTheDockItStopsAboveIt() {
        let result = snap(x: 100, y: -200, visible: bottomDock)
        XCTAssertEqual(result.origin.y, 88)
        XCTAssertTrue(result.placement.docked)
    }

    func testFarFromTheDockItIsFree() {
        let result = snap(x: 100, y: 300, visible: bottomDock)
        XCTAssertEqual(result.origin, CGPoint(x: 100, y: 300))
        XCTAssertFalse(result.placement.docked)
    }

    func testNearTheCentreItIsCaughtOnEachAxis() {
        let centered = (bottomDock.midX - size.width / 2).rounded()
        let horizontal = snap(x: centered + 20, y: 300, visible: bottomDock)
        XCTAssertEqual(horizontal.origin, CGPoint(x: centered, y: 300))
        XCTAssertTrue(horizontal.placement.centeredX)
        XCTAssertFalse(horizontal.placement.centeredY)

        let middle = (bottomDock.midY - size.height / 2).rounded()
        let both = snap(x: centered - 15, y: middle + 15, visible: bottomDock)
        XCTAssertEqual(both.origin, CGPoint(x: centered, y: middle))
        XCTAssertTrue(both.placement.centeredX && both.placement.centeredY)
    }

    func testBothMagnetsAtOnce() {
        let centered = (bottomDock.midX - size.width / 2).rounded()
        let result = snap(x: centered + 10, y: 95, visible: bottomDock)
        XCTAssertEqual(result.origin, CGPoint(x: centered, y: 88))
        XCTAssertTrue(result.placement.docked && result.placement.centeredX)
    }

    func testADockOnTheSideHoldsItThere() {
        let result = snap(x: 90, y: 300, visible: leftDock)
        XCTAssertEqual(result.origin, CGPoint(x: 78, y: 300))
        XCTAssertTrue(result.placement.docked)
    }

    func testStaysWithinTheVisibleArea() {
        let result = snap(x: 5000, y: 5000, visible: bottomDock)
        XCTAssertTrue(bottomDock.contains(CGRect(origin: result.origin, size: size)))
    }

    func testAPlacementFollowsTheDockAndTheScreen() {
        let held = StripPlacement(origin: CGPoint(x: 100, y: 88), docked: true, centeredX: true)
        let wider = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let moved = StripMagnet.origin(for: held, size: size, screen: wider, visible: CGRect(x: 0, y: 60, width: 2560, height: 1350))
        XCTAssertEqual(moved, CGPoint(x: ((2560 - 763) / 2 as CGFloat).rounded(), y: 68))
    }

    func testTheDockWinsOverARememberedCentreOnItsAxis() {
        // Docked at the bottom and centred, then the Dock moves to the left.
        let held = StripPlacement(origin: CGPoint(x: 374, y: 88), docked: true, centeredX: true)
        let origin = StripMagnet.origin(for: held, size: size, screen: screen, visible: leftDock)
        XCTAssertEqual(origin.x, 78, "against the Dock, not centred")
        XCTAssertEqual(StripMagnet.origin(for: StripPlacement(), size: size, screen: screen, visible: leftDock).x, 78, "the first placement too")
    }

    func testAFreePlacementStaysWhereItWas() {
        let free = StripPlacement(origin: CGPoint(x: 100, y: 300), docked: false, centeredX: false)
        XCTAssertEqual(StripMagnet.origin(for: free, size: size, screen: screen, visible: bottomDock), CGPoint(x: 100, y: 300))
    }

    func testTheFirstPlacementIsCenteredOnTheDock() {
        let origin = StripMagnet.origin(for: StripPlacement(), size: size, screen: screen, visible: bottomDock)
        XCTAssertEqual(origin, CGPoint(x: ((1512 - 763) / 2 as CGFloat).rounded(), y: 88))
    }

    func testPlacementSurvivesARoundTrip() throws {
        let placement = StripPlacement(origin: CGPoint(x: 12, y: 34), docked: false, centeredX: true, centeredY: true)
        XCTAssertEqual(try JSONDecoder().decode(StripPlacement.self, from: JSONEncoder().encode(placement)), placement)
    }
}

final class ComparisonGeometryTests: XCTestCase {
    func testGridsInReadingOrder() {
        let area = CGRect(x: 0, y: 0, width: 1003, height: 603)
        let two = ComparisonGeometry.grid(in: area, count: 2)
        XCTAssertEqual(two[0].minX, 0)
        XCTAssertGreaterThan(two[1].minX, two[0].maxX - 1)
        XCTAssertEqual(two[0].height, 603)

        let four = ComparisonGeometry.grid(in: area, count: 4)
        XCTAssertGreaterThan(four[0].minY, four[2].minY, "the first row is on top")
        XCTAssertEqual(four[0].minX, four[2].minX)
        XCTAssertLessThan(four[0].minX, four[1].minX)
        XCTAssertTrue(four.allSatisfy { area.contains($0) })
    }

    func testFitLeavesThePhotoWholeAndCentered() {
        let frame = ComparisonGeometry.imageFrame(slot: CGSize(width: 600, height: 600), native: CGSize(width: 6000, height: 4000), zoom: nil, pointsPerPixel: 0.5, center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(frame, CGRect(x: 0, y: 100, width: 600, height: 400))
    }

    func testEveryPhotoLooksAtTheSamePointAt100Percent() {
        let frame = ComparisonGeometry.imageFrame(slot: CGSize(width: 600, height: 400), native: CGSize(width: 6000, height: 4000), zoom: 1, pointsPerPixel: 0.5, center: CGPoint(x: 0.25, y: 0.5))
        XCTAssertEqual(frame.size, CGSize(width: 3000, height: 2000))
        XCTAssertEqual(frame.minX + 0.25 * frame.width, 300, accuracy: 1, "that point is in the middle")
    }

    func testAPanCannotLeaveThePhoto() {
        let frame = ComparisonGeometry.imageFrame(slot: CGSize(width: 600, height: 400), native: CGSize(width: 6000, height: 4000), zoom: 1, pointsPerPixel: 0.5, center: CGPoint(x: -3, y: 9))
        XCTAssertEqual(frame.minX, 0)
        XCTAssertEqual(frame.maxY, 400)
    }
}

final class ComparisonPlanningTests: XCTestCase {
    private func input(zoomed: Bool = false, memory: MemoryLevel = .normal) -> PlanInput {
        var input = PlanInput(count: 100, current: 50)
        input.comparison = ComparisonPlan(shown: [50, 49, 51, 52], waiting: [53, 54])
        input.zoomed = zoomed
        input.memory = memory
        return input
    }

    func testEveryPhotoOnScreenIsVisibleDemandAndNothingElseIsPlanned() {
        let items = WindowPlanner.plan(input())
        for index in [50, 49, 51, 52] {
            XCTAssertTrue(items.contains(PlanItem(index: index, tier: .screen, visible: true)))
        }
        XCTAssertEqual(Set(items.map(\.index)), [49, 50, 51, 52, 53, 54], "no window around the current photo")
        XCTAssertFalse(items.contains { $0.tier == .full })
        XCTAssertFalse(items.contains { $0.background })
    }

    func testZoomRendersThemAllFocusFirst() {
        let full = WindowPlanner.plan(input(zoomed: true)).filter { $0.tier == .full }
        XCTAssertEqual(full.map(\.index), [50, 49, 51, 52])
        XCTAssertTrue(full.allSatisfy(\.visible))
    }

    func testMemoryPressureKeepsOnlyTheFocusSharp() {
        let warning = WindowPlanner.plan(input(zoomed: true, memory: .warning))
        XCTAssertEqual(warning.filter { $0.tier == .full }.map(\.index), [50])
        XCTAssertEqual(Set(warning.map(\.index)), [49, 50, 51, 52], "nothing speculative")

        let critical = WindowPlanner.plan(input(memory: .critical))
        XCTAssertEqual(critical.filter { $0.tier == .screen }.map(\.index), [50])
        XCTAssertEqual(critical.filter { $0.tier == .preview }.count, 4, "the others stay recognisable")
    }

    func testPositionsOutOfBoundsAreDropped() {
        var input = input()
        input.comparison = ComparisonPlan(shown: [50, 200], waiting: [-1])
        XCTAssertEqual(Set(WindowPlanner.plan(input).map(\.index)), [50])
    }
}

final class GroupDeletionListTests: XCTestCase {
    func testRemovingAnotherPhotoKeepsTheCurrentOne() {
        var list = PhotoList(photos: photos("a", "b", "c", "d"), selecting: "/photos/c.arw")
        XCTAssertTrue(list.remove(photo("a")))
        XCTAssertEqual(list.current, photo("c"))
        XCTAssertTrue(list.remove(photo("d")))
        XCTAssertEqual(list.current, photo("c"))
    }

    func testRemovingTheCurrentPhotoMovesOn() {
        var list = PhotoList(photos: photos("a", "b", "c"), selecting: "/photos/b.arw")
        XCTAssertTrue(list.remove(photo("b")))
        XCTAssertEqual(list.current, photo("c"))
    }

    func testAnotherRevisionIsNotRemoved() {
        var list = PhotoList(photos: photos("a", "b"))
        XCTAssertFalse(list.remove(photo("a", revision: 9)))
        XCTAssertEqual(list.count, 2)
    }
}

final class ComparisonShortcutTests: XCTestCase {
    func testDefaultKeys() {
        let map = ShortcutMap.defaults
        XCTAssertEqual(map.action(for: .character("c")), .compare)
        XCTAssertEqual(map.action(for: .character("b")), .toggleStrip)
        XCTAssertEqual(map.action(for: .code(36)), .keepSelected)
    }

    func testKeepingNeverGetsAPlainMenuKey() {
        XCTAssertNil(ShortcutMap.defaults.menuBinding(for: .keepSelected), "Return in the settings window must delete nothing")
        var map = ShortcutMap.defaults
        map.assign(.code(36, modifiers: .command), to: .keepSelected)
        XCTAssertEqual(map.menuBinding(for: .keepSelected), .code(36, modifiers: .command))
    }
}

@MainActor
final class ComparisonMemoryTests: XCTestCase {
    /// A settled comparison has screen frames and no previews, since a screen frame drops its
    /// preview. Critical pressure takes the screen frames of the others: they must get a
    /// preview, or those slots would stay empty until the next action.
    func testCriticalPressureRequestsPreviewsForTheSlotsItEmptied() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BVMemory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = Pipeline(
            budgets: .init(preview: 1 << 30, screen: 1 << 30, full: 1 << 30),
            disk: DiskCache(directory: directory, budget: 1 << 30)
        )
        let list = photos("a", "b")
        for photo in list {
            let surface = try XCTUnwrap(PixelFormat.makeSurface(width: 8, height: 8))
            pipeline.cache.insert(Frame(key: FrameKey(photo: photo, tier: .screen), surface: surface, nativeSize: CGSize(width: 8, height: 8)))
        }
        pipeline.onNeedsReplan = {
            var input = PlanInput(count: 2, current: 0)
            input.comparison = ComparisonPlan(shown: [0, 1], waiting: [])
            input.memory = pipeline.memoryLevel
            pipeline.plan(photos: list, input: input)
        }
        // These files do not exist, so a job that really starts ends up reported as stale.
        var attempted: [PhotoKey] = []
        pipeline.onStale = { attempted.append($0) }
        var emptiedWhenNotified = false
        pipeline.onEvicted = { emptiedWhenNotified = !pipeline.cache.contains(FrameKey(photo: list[1], tier: .screen)) }

        pipeline.setMemoryLevel(.critical)

        XCTAssertTrue(emptiedWhenNotified)
        XCTAssertTrue(pipeline.cache.contains(FrameKey(photo: list[0], tier: .screen)), "the focused photo stays sharp")
        let deadline = Date().addingTimeInterval(5)
        while !attempted.contains(list[1]), Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(attempted.contains(list[1]), "the emptied slot gets its preview planned")
    }

    /// No preview to fall back on, and rendering is not an option under critical pressure.
    func testAPhotoWithoutAPreviewKeepsItsFrameUnderPressure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BVMemory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = Pipeline(
            budgets: .init(preview: 1 << 30, screen: 1 << 30, full: 1 << 30),
            disk: DiskCache(directory: directory.appendingPathComponent("cache"), budget: 1 << 30)
        )
        pipeline.setTarget(CGSize(width: 64, height: 64))
        var list: [PhotoKey] = []
        for name in ["a.arw", "b.arw"] {
            let url = directory.appendingPathComponent(name)
            try Data("not a photo".utf8).write(to: url)
            list.append(try XCTUnwrap(PhotoKey.read(path: url.path)))
        }
        let plan = {
            var input = PlanInput(count: 2, current: 0)
            input.comparison = ComparisonPlan(shown: [0, 1], waiting: [])
            input.memory = pipeline.memoryLevel
            pipeline.plan(photos: list, input: input)
        }
        pipeline.onNeedsReplan = plan
        plan()
        let preview = FrameKey(photo: list[1], tier: .preview)
        let deadline = Date().addingTimeInterval(5)
        while !pipeline.hasFailed(preview), Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(pipeline.hasFailed(preview))

        let surface = try XCTUnwrap(PixelFormat.makeSurface(width: 8, height: 8))
        let screen = FrameKey(photo: list[1], tier: .screen)
        pipeline.cache.insert(Frame(key: screen, surface: surface, nativeSize: CGSize(width: 8, height: 8)))
        pipeline.setMemoryLevel(.critical)
        XCTAssertTrue(pipeline.cache.contains(screen))
    }
}

final class StripWindowTests: XCTestCase {
    func testTheSameNumberOfPhotosEvenAtTheEnds() {
        XCTAssertEqual(StripView.window(around: 50, count: 133, reach: 14), 36...64)
        XCTAssertEqual(StripView.window(around: 0, count: 133, reach: 14), 0...28)
        XCTAssertEqual(StripView.window(around: 132, count: 133, reach: 14), 104...132)
        XCTAssertEqual(StripView.window(around: 3, count: 10, reach: 14), 0...9, "a short list is given whole")
        XCTAssertEqual(StripView.window(around: 0, count: 1, reach: 14), 0...0)
    }
}

@MainActor
final class StripLayoutTests: XCTestCase {
    private func portrait() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 3, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    private func strip(count: Int, anchor: Int, cut: (Bool, Bool)) throws -> StripView {
        let view = StripView(metrics: .init(height: 66, gap: 3, top: 7, fadesEdges: true))
        view.frame = CGRect(x: 0, y: 0, width: 820, height: 92)
        let image = try portrait()
        let cells = (0..<count).map { StripCell(photo: PhotoKey(path: "/p/\($0).arw", device: 1, inode: 1, size: 1, mtimeSeconds: 0, mtimeNanoseconds: 0), image: image) }
        view.update(cells: cells, anchor: anchor, cut: cut)
        return view
    }

    /// Portrait photos are 44 pt wide: 29 of them overflow 820 pt from either end.
    func testPortraitsFillTheStripAtBothEnds() throws {
        let start = try strip(count: 29, anchor: 0, cut: (false, true))
        XCTAssertEqual(start.cellFrames.first?.minX, 10)
        XCTAssertGreaterThanOrEqual(start.cellFrames.last?.maxX ?? 0, 820)

        let end = try strip(count: 29, anchor: 28, cut: (true, false))
        XCTAssertEqual(end.cellFrames.last?.maxX, 810)
        XCTAssertLessThanOrEqual(end.cellFrames.first?.minX ?? 1, 0)
    }

    func testTheCurrentPhotoIsCentredAwayFromTheEnds() throws {
        let middle = try strip(count: 29, anchor: 14, cut: (true, true))
        XCTAssertEqual(middle.cellFrames[14].midX, 410, accuracy: 1)
        XCTAssertEqual(middle.cellFrames[14].width, 44)
    }

    func testAShortListIsCentredWhole() throws {
        let short = try strip(count: 5, anchor: 0, cut: (false, false))
        let frames = short.cellFrames
        XCTAssertEqual(frames.first!.minX - 0, 820 - frames.last!.maxX, accuracy: 1)
    }
}
