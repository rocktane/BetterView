import XCTest
@testable import BetterView

func photo(_ name: String, inode: UInt64 = 1, folder: String = "/photos") -> PhotoKey {
    PhotoKey(path: "\(folder)/\(name)", device: 1, inode: inode, size: 10, mtimeSeconds: 1, mtimeNanoseconds: 0)
}

final class PhotoListTests: XCTestCase {
    func testNaturalOrder() {
        let sorted = [photo("A10.ARW"), photo("A2.ARW"), photo("A1.ARW")].sorted(by: PhotoList.ordered)
        XCTAssertEqual(sorted.map(\.name), ["A1.ARW", "A2.ARW", "A10.ARW"])
    }

    func testRemoveFollowsDirection() {
        let photos = ["a", "b", "c"].map { photo($0) }
        var forward = PhotoList(photos: photos, selecting: "/photos/b")
        _ = forward.removeCurrent(direction: 1)
        XCTAssertEqual(forward.current?.name, "c")

        var backward = PhotoList(photos: photos, selecting: "/photos/b")
        _ = backward.removeCurrent(direction: -1)
        XCTAssertEqual(backward.current?.name, "a")

        var last = PhotoList(photos: photos, selecting: "/photos/c")
        _ = last.removeCurrent(direction: 1)
        XCTAssertEqual(last.current?.name, "b")

        var only = PhotoList(photos: [photos[0]])
        _ = only.removeCurrent(direction: 1)
        XCTAssertNil(only.current)
    }

    func testMergeKeepsCurrentAndHonoursTombstones() {
        var list = PhotoList(photos: ["a", "b", "c"].map { photo($0) }, selecting: "/photos/c")
        let changed = list.merge(scan: ["a", "b", "b2", "c"].map { photo($0) }, excluding: ["/photos/b"])
        XCTAssertTrue(changed)
        XCTAssertEqual(list.photos.map(\.name), ["a", "b2", "c"])
        XCTAssertEqual(list.current?.name, "c")
    }

    func testMergeCurrentGone() {
        var list = PhotoList(photos: ["a", "b", "c"].map { photo($0) }, selecting: "/photos/b")
        _ = list.merge(scan: ["a", "c"].map { photo($0) }, excluding: [])
        XCTAssertEqual(list.current?.name, "c")
    }

    func testMergeSeesNewRevisionOfCurrent() {
        var list = PhotoList(photos: [photo("a", inode: 1)])
        XCTAssertTrue(list.merge(scan: [photo("a", inode: 2)], excluding: []))
        XCTAssertEqual(list.current?.inode, 2)
    }

    func testIdenticalScanIsNotAChange() {
        var list = PhotoList(photos: [photo("a"), photo("b")])
        XCTAssertFalse(list.merge(scan: [photo("a"), photo("b")], excluding: []))
    }

    func testInsertSortedKeepsOrSelects() {
        var list = PhotoList(photos: [photo("a"), photo("c")], selecting: "/photos/c")
        list.insert(photo("b"), select: false)
        XCTAssertEqual(list.photos.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(list.current?.name, "c")
        list.insert(photo("b"), select: true)
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list.current?.name, "b")
    }
}
