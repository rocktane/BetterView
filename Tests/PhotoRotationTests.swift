import QuartzCore
import XCTest
@testable import BetterView

final class PhotoRotationTests: XCTestCase {
    func testTurningABurstPersistsEachOrientationAndKeepsOriginalFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("state/rotations.json")
        let original = Data([1, 2, 3])
        let photos = try (1...3).map { index in
            let file = folder.appendingPathComponent("\(index).arw")
            try original.write(to: file)
            return try XCTUnwrap(PhotoKey.read(path: file.path))
        }
        let empty = try PhotoRotations.read(from: url)
        let first = try empty.saving(.left, for: [photos[0]], to: url)
        _ = try first.saving(.right, for: Array(photos.prefix(2)), to: url)

        let reopened = try PhotoRotations.read(from: url)
        XCTAssertEqual(photos.map { reopened[$0] }, [.upright, .right, .upright])
        for photo in photos {
            XCTAssertEqual(try Data(contentsOf: photo.url), original)
        }

        try Data([4, 5]).write(to: photos[1].url, options: .atomic)
        XCTAssertThrowsError(try reopened.saving(.right, for: photos, to: url))
        let afterFailure = try PhotoRotations.read(from: url)
        XCTAssertEqual(afterFailure[photos[0]], .upright)
        let replacement = try XCTUnwrap(PhotoKey.read(path: photos[1].path))
        XCTAssertEqual(afterFailure[replacement], .upright)
    }

    func testResettingTheRotationKeepsTheBookmark() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("rotations.json")
        let file = folder.appendingPathComponent("a.arw")
        try Data([1]).write(to: file)
        let photo = try XCTUnwrap(PhotoKey.read(path: file.path))
        let state = try PhotoRotations().saving(.left, for: [photo], to: url).togglingMark(for: photo, to: url)
        let reset = try state.resettingRotation(for: [photo], to: url)
        XCTAssertEqual(reset[photo], .upright)
        XCTAssertTrue(reset.isMarked(photo))
        let reopened = try PhotoRotations.read(from: url)
        XCTAssertEqual(reopened[photo], .upright)
        XCTAssertTrue(reopened.isMarked(photo))
    }

    @MainActor
    func testClockwiseRotationKeepsTheLayerAndCameraPointInTheSameGeometry() {
        let layer = CALayer()
        let rect = CGRect(x: 10, y: 20, width: 300, height: 400)
        layer.placeImage(in: rect, rotation: .right)
        XCTAssertEqual(layer.frame, rect)
        XCTAssertEqual(layer.bounds.size, CGSize(width: 400, height: 300))
        XCTAssertEqual(CGPoint(x: -1, y: 1).applying(layer.affineTransform()), CGPoint(x: 1, y: 1))
        XCTAssertEqual(PhotoRotation.right.point(.zero), CGPoint(x: 1, y: 0))
        layer.placeImage(in: CGRect(x: 0, y: 0, width: 400, height: 300), rotation: .upright)
        XCTAssertTrue(layer.affineTransform().isIdentity)
    }
}
