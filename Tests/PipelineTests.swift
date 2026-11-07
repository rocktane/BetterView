import XCTest
import CoreGraphics
import IOSurface
import ImageIO
import UniformTypeIdentifiers
@testable import BetterView

@MainActor
final class FrameCacheTests: XCTestCase {
    private func frame(_ name: String, _ tier: Tier = .screen, side: Int = 100) -> Frame {
        Frame(key: FrameKey(photo: photo(name), tier: tier),
              surface: PixelFormat.makeSurface(width: side, height: side)!,
              nativeSize: CGSize(width: side, height: side))
    }

    func testEvictsOldestPastBudget() {
        let cost = frame("x").byteCost
        let cache = FrameCache(budgets: .init(preview: cost, screen: cost * 2, full: cost))
        cache.insert(frame("a"))
        cache.insert(frame("b"))
        _ = cache.frame(FrameKey(photo: photo("a"), tier: .screen)) // a is now the newest
        cache.insert(frame("c"))
        XCTAssertTrue(cache.contains(FrameKey(photo: photo("a"), tier: .screen)))
        XCTAssertFalse(cache.contains(FrameKey(photo: photo("b"), tier: .screen)))
        XCTAssertEqual(cache.bytes(.screen), cost * 2)
    }

    func testProtectedSurvivesUntilItAloneRemains() {
        let cost = frame("x").byteCost
        let cache = FrameCache(budgets: .init(preview: cost, screen: cost * 2, full: cost))
        let protectedKey = FrameKey(photo: photo("a"), tier: .screen)
        cache.protected = [protectedKey]
        cache.insert(frame("a"))
        cache.insert(frame("b"))
        cache.insert(frame("c"))
        XCTAssertTrue(cache.contains(protectedKey))
        XCTAssertFalse(cache.contains(FrameKey(photo: photo("b"), tier: .screen)))

        cache.protected = Set(["a", "c", "d"].map { FrameKey(photo: photo($0), tier: .screen) })
        cache.insert(frame("d"))
        XCTAssertLessThanOrEqual(cache.bytes(.screen), cost * 2, "the budget wins over the plan")
    }

    func testScreenFrameDropsPreview() {
        let cache = FrameCache(budgets: .init(preview: 1 << 30, screen: 1 << 30, full: 1 << 30))
        cache.insert(frame("a", .preview))
        cache.insert(frame("a", .screen))
        XCTAssertFalse(cache.contains(FrameKey(photo: photo("a"), tier: .preview)))
    }

    func testBestOrderDependsOnZoom() {
        let cache = FrameCache(budgets: .init(preview: 1 << 30, screen: 1 << 30, full: 1 << 30))
        cache.insert(frame("a", .full))
        cache.insert(frame("a", .screen))
        XCTAssertEqual(cache.best(photo("a"), zoomed: false)?.key.tier, .screen)
        XCTAssertEqual(cache.best(photo("a"), zoomed: true)?.key.tier, .full)
        XCTAssertNil(cache.best(photo("other"), zoomed: false))
    }

    func testNewRevisionNeverHitsOldFrame() {
        let cache = FrameCache(budgets: .init(preview: 1 << 30, screen: 1 << 30, full: 1 << 30))
        cache.insert(frame("a"))
        XCTAssertNil(cache.best(BetterViewTests.photo("a", inode: 2), zoomed: false))
    }

    func testBudgetScalesWithMemory() {
        XCTAssertEqual(FrameCache.Budgets.scaled(physicalMemory: 16 << 30).screen, 1_000_000_000)
        XCTAssertEqual(FrameCache.Budgets.scaled(physicalMemory: 8 << 30).screen, 500_000_000)
        XCTAssertEqual(FrameCache.Budgets.scaled(physicalMemory: 128 << 30).screen, 2_000_000_000)
    }
}

@MainActor
final class DiskCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BVDisk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func solidFrame(_ photoKey: PhotoKey) -> Frame {
        let surface = PixelFormat.makeSurface(width: 64, height: 32)!
        surface.lock(options: [], seed: nil)
        memset(surface.baseAddress, 0x7f, surface.bytesPerRow * surface.height)
        surface.unlock(options: [], seed: nil)
        return Frame(key: FrameKey(photo: photoKey, tier: .screen), surface: surface, nativeSize: CGSize(width: 640, height: 320))
    }

    func testKeyChangesWithRevisionAndTarget() {
        let cache = DiskCache(directory: directory, budget: 1 << 20)
        cache.setTarget(CGSize(width: 100, height: 100))
        let original = cache.hash(photo("a"))
        XCTAssertEqual(original, cache.hash(photo("a")))
        XCTAssertNotEqual(original, cache.hash(BetterViewTests.photo("a", inode: 2)))
        cache.setTarget(CGSize(width: 200, height: 100))
        XCTAssertNotEqual(original, cache.hash(photo("a")))
    }

    func testRoundTripKeepsNativeSize() {
        let cache = DiskCache(directory: directory, budget: 1 << 30)
        cache.setTarget(CGSize(width: 100, height: 100))
        let key = photo("a")
        let frame = solidFrame(key)
        let name = cache.entryName(key, nativeSize: frame.nativeSize)
        let entry = DiskCache.Entry(fileName: name, nativeSize: frame.nativeSize)
        XCTAssertTrue(DiskCodec.write(frame, to: cache.url(entry)))
        cache.noteWritten(photo: key, entry: entry, generation: cache.generation)
        XCTAssertTrue(cache.contains(key))
        let read = DiskCodec.read(cache.url(entry), key: frame.key, nativeSize: entry.nativeSize)
        XCTAssertEqual(read?.surface.width, 64)
        XCTAssertEqual(read?.nativeSize, CGSize(width: 640, height: 320))
    }

    func testWriteFinishingAfterClearIsDropped() async throws {
        let cache = DiskCache(directory: directory, budget: 1 << 30)
        cache.setTarget(CGSize(width: 100, height: 100))
        let key = photo("a")
        let entry = DiskCache.Entry(fileName: cache.entryName(key, nativeSize: .init(width: 1, height: 1)), nativeSize: .init(width: 1, height: 1))
        let startedGeneration = cache.generation
        cache.clear()
        try Data("x".utf8).write(to: cache.url(entry))
        cache.noteWritten(photo: key, entry: entry, generation: startedGeneration)
        XCTAssertFalse(cache.contains(key))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.url(entry).path))
    }

    func testIndexReloadsFromDisk() async throws {
        let first = DiskCache(directory: directory, budget: 1 << 30)
        first.setTarget(CGSize(width: 100, height: 100))
        let key = photo("a")
        let name = first.entryName(key, nativeSize: CGSize(width: 40, height: 20))
        try Data("x".utf8).write(to: directory.appendingPathComponent(name))

        let second = DiskCache(directory: directory, budget: 1 << 30)
        second.setTarget(CGSize(width: 100, height: 100))
        second.load()
        for _ in 0..<500 where !second.contains(key) { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(second.entry(key)?.nativeSize, CGSize(width: 40, height: 20))
    }
}

/// Pipeline behaviour on real files: a small JPEG named .arw has a readable header but is
/// no RAW, which conveniently exercises the failure paths.
@MainActor
final class PipelineFlowTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BVFlow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makePipeline() -> Pipeline {
        let disk = DiskCache(directory: root.appendingPathComponent("cache"), budget: 1 << 30)
        try? FileManager.default.createDirectory(at: disk.directory, withIntermediateDirectories: true)
        let pipeline = Pipeline(budgets: .init(preview: 1 << 30, screen: 1 << 30, full: 1 << 30), disk: disk)
        pipeline.setTarget(CGSize(width: 64, height: 64))
        return pipeline
    }

    private func writeJPEG(_ name: String) throws -> PhotoKey {
        let url = root.appendingPathComponent(name)
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: PixelFormat.displayP3, bitmapInfo: PixelFormat.bitmapInfo)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return PhotoKey.read(path: url.path)!
    }

    private func settle(_ pipeline: Pipeline) async {
        for _ in 0..<2500 where !pipeline.isIdle { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(pipeline.isIdle)
    }

    func testFileWithoutPreviewStillGetsItsFirstPixels() async throws {
        // A tiny image has no preview worth showing (below 640 px), and the disk cache is
        // empty. The screen job must still run: nothing waits on a preview having succeeded.
        let pipeline = makePipeline()
        let key = try writeJPEG("nopreview.arw")
        var frames: [Tier] = []
        var failures: [Tier] = []
        pipeline.onFrame = { frames.append($0.key.tier) }
        pipeline.onFailed = { failures.append($0.tier) }
        pipeline.plan(photos: [key], input: PlanInput(count: 1, current: 0))
        await settle(pipeline)
        XCTAssertTrue(failures.contains(.preview))
        XCTAssertTrue(frames.contains(.screen) || failures.contains(.screen), "the render must have been attempted")
    }

    func testMissingDiskEntryFallsBackToRender() async throws {
        let pipeline = makePipeline()
        let key = try writeJPEG("a.arw")
        let entry = DiskCache.Entry(fileName: pipeline.disk.entryName(key, nativeSize: .init(width: 64, height: 64)), nativeSize: .init(width: 64, height: 64))
        pipeline.disk.noteWritten(photo: key, entry: entry, generation: pipeline.disk.generation)
        XCTAssertTrue(pipeline.disk.contains(key), "the index claims a file that does not exist")

        var replans = 0
        pipeline.onNeedsReplan = {
            replans += 1
            pipeline.plan(photos: [key], input: PlanInput(count: 1, current: 0))
        }
        var attempted = false
        pipeline.onFrame = { if $0.key.tier == .screen { attempted = true } }
        pipeline.onFailed = { if $0.tier == .screen { attempted = true } }
        pipeline.plan(photos: [key], input: PlanInput(count: 1, current: 0))
        await settle(pipeline)
        XCTAssertEqual(replans, 1)
        // The render may write a valid entry back: what must not survive is an index entry
        // pointing at nothing.
        if let current = pipeline.disk.entry(key) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: pipeline.disk.url(current).path))
        }
        XCTAssertTrue(attempted, "a RAW render must follow the failed read")
    }

    func testReplacedFileIsRejectedAndNeverCached() async throws {
        let pipeline = makePipeline()
        let key = try writeJPEG("a.arw")
        // The job's key is out of date before it even starts.
        _ = try writeJPEG(".tmp")
        rename(root.appendingPathComponent(".tmp").path, key.path)
        var stale: [PhotoKey] = []
        pipeline.onStale = { stale.append($0) }
        pipeline.plan(photos: [key], input: PlanInput(count: 1, current: 0))
        await settle(pipeline)
        XCTAssertTrue(stale.contains(key))
        XCTAssertNil(pipeline.cache.best(key, zoomed: false))
        XCTAssertEqual(pipeline.disk.count, 0)
    }

    func testVisibleWorkGetsTheReservedSlot() async throws {
        let pipeline = makePipeline()
        let keys = try (0..<8).map { try writeJPEG("p\($0).arw") }
        var input = PlanInput(count: keys.count, current: 0)
        input.screenAhead = 7
        input.screenBehind = 0
        pipeline.plan(photos: keys, input: input)
        // The first job in the plan is the visible one: it must never be queued behind.
        let plan = WindowPlanner.plan(input)
        XCTAssertEqual(plan.first?.index, 0)
        XCTAssertTrue(plan.first?.visible == true)
        await settle(pipeline)
    }

    func testWindowAlwaysFitsBudget() {
        let pipeline = makePipeline()
        pipeline.setTarget(CGSize(width: 6016, height: 3384))
        var small = PlanInput(count: 100, current: 50)
        let tiny = Pipeline(budgets: .init(preview: 1, screen: 400_000_000, full: 1), disk: pipeline.disk)
        tiny.setTarget(CGSize(width: 6016, height: 3384))
        tiny.applyWindowSizes(to: &small)
        let frameBytes = 6016 * 3384 * 4
        XCTAssertLessThanOrEqual((small.screenAhead + small.screenBehind + 1) * frameBytes, 400_000_000)
    }
}

@MainActor
final class AssociationTests: XCTestCase {
    func testRestoreOnlyWhileStillEffectiveDefault() {
        XCTAssertEqual(FileAssociations.restoreTarget(effective: "me", me: "me", saved: "preview", available: true), "preview")
        XCTAssertNil(FileAssociations.restoreTarget(effective: "other", me: "me", saved: "preview", available: true),
                     "the user chose another app since: leave it")
        XCTAssertNil(FileAssociations.restoreTarget(effective: "me", me: "me", saved: "preview", available: false))
        XCTAssertNil(FileAssociations.restoreTarget(effective: "me", me: "me", saved: nil, available: true))
    }
}

final class ARWPreviewTests: XCTestCase {
    private struct Field { let tag: UInt16; let type: UInt16; let value: UInt32 }

    /// A little-endian TIFF with an IFD0 and a SubIFD holding the raw size.
    private func header(orientation: UInt16 = 6, offset: UInt32 = 4096, length: UInt32 = 100) -> Data {
        var data = Data([0x49, 0x49, 42, 0])
        func append16(_ v: UInt16) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        func append32(_ v: UInt32) { (0..<4).forEach { data.append(UInt8((v >> (8 * UInt32($0))) & 0xFF)) } }
        append32(8)
        let fields = [
            Field(tag: 0x0112, type: 3, value: UInt32(orientation)),
            Field(tag: 0x014A, type: 4, value: 80),
            Field(tag: 0x0201, type: 4, value: offset),
            Field(tag: 0x0202, type: 4, value: length),
        ]
        append16(UInt16(fields.count))
        for field in fields {
            append16(field.tag); append16(field.type); append32(1); append32(field.value)
        }
        data.append(Data(count: 80 - data.count))
        append16(2)
        append16(0x0100); append16(4); append32(1); append32(6000)
        append16(0x0101); append16(3); append32(1); append32(4000)
        return data
    }

    func testParsesLayout() {
        XCTAssertEqual(ARWPreview.parse(header: header()), .init(offset: 4096, length: 100, orientation: 6, rawSize: CGSize(width: 6000, height: 4000)))
    }

    func testUnexpectedFilesFallBack() {
        XCTAssertNil(ARWPreview.parse(header: Data()))
        XCTAssertNil(ARWPreview.parse(header: Data([0x4D, 0x4D, 0, 42, 0, 0, 0, 8, 0])), "big endian")
        XCTAssertNil(ARWPreview.parse(header: header(orientation: 2)), "mirrored orientation")
        XCTAssertNil(ARWPreview.parse(header: header(offset: 0)))
        XCTAssertNil(ARWPreview.parse(header: header(length: 0)))
    }

    func testTruncatedHeadersNeverCrash() {
        let whole = header()
        for size in 0..<whole.count { _ = ARWPreview.parse(header: whole.prefix(size)) }
        // An entry count pointing far beyond the data.
        var corrupt = whole
        corrupt[8] = 0xFF
        corrupt[9] = 0xFF
        _ = ARWPreview.parse(header: corrupt)
    }

    func testFileWithEmbeddedJPEGAndBadSignature() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BVARW-\(UUID().uuidString).arw")
        defer { try? FileManager.default.removeItem(at: url) }
        var file = header(offset: 200, length: 4)
        file.append(Data(count: 200 - file.count))
        file.append(contentsOf: [0xFF, 0xD8, 0xFF, 0xD9])
        try file.write(to: url)
        XCTAssertEqual(ARWPreview.read(url)?.jpeg, Data([0xFF, 0xD8, 0xFF, 0xD9]))

        file[200] = 0
        try file.write(to: url)
        XCTAssertNil(ARWPreview.read(url), "no JPEG signature at that offset")
    }

    /// Source: 4x2, left half red and right half blue, with the bottom-left pixel marked.
    private func pixel(_ surface: IOSurface, x: Int, y: Int) -> (red: UInt8, blue: UInt8) {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let at = y * surface.bytesPerRow + x * 4
        return (base[at + 2], base[at])
    }

    func testOrientationPutsTheRightCornerOnTop() throws {
        // The left half is red and the right half is blue.
        let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: PixelFormat.displayP3, bitmapInfo: PixelFormat.bitmapInfo)!
        context.setFillColor(CGColor(colorSpace: PixelFormat.displayP3, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        context.setFillColor(CGColor(colorSpace: PixelFormat.displayP3, components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        let image = context.makeImage()!

        // 1: unchanged. Top-left stays red.
        let upright = ARWPreview.materialize(image, orientation: 1)!.surface
        XCTAssertEqual(upright.width, 4)
        XCTAssertGreaterThan(pixel(upright, x: 0, y: 0).red, 200)

        // 3: half turn. Top-left is the old right side.
        let flipped = ARWPreview.materialize(image, orientation: 3)!.surface
        XCTAssertGreaterThan(pixel(flipped, x: 0, y: 0).blue, 200)

        // 6: quarter turn clockwise, the old left side is now on top.
        let clockwise = ARWPreview.materialize(image, orientation: 6)!.surface
        XCTAssertEqual(clockwise.width, 2)
        XCTAssertEqual(clockwise.height, 4)
        XCTAssertGreaterThan(pixel(clockwise, x: 0, y: 0).red, 200)
        XCTAssertGreaterThan(pixel(clockwise, x: 0, y: 3).blue, 200)

        // 8: quarter turn counter-clockwise, the old right side is now on top.
        let counter = ARWPreview.materialize(image, orientation: 8)!.surface
        XCTAssertGreaterThan(pixel(counter, x: 0, y: 0).blue, 200)
        XCTAssertGreaterThan(pixel(counter, x: 0, y: 3).red, 200)
    }
}
