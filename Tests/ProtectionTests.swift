import XCTest
@testable import BetterView

/// Protected photos and typed deletion failures. Temporary files only, locked with `chflags`
/// or `chmod`, and a fake Trash: the real Trash and real photos are never touched.
@MainActor
final class ProtectionTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var trash: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BVProtection-\(UUID().uuidString)")
        folder = root.appendingPathComponent("photos")
        trash = root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        for name in ["a", "b", "c", "d"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent("\(name).arw"))
        }
    }

    /// Lifts every lock first, otherwise the cleanup itself would fail.
    override func tearDown() async throws {
        guard let root else { return }
        chmod(root.path, 0o755)
        chmod(folder.path, 0o755)
        let paths = FileManager.default.subpaths(atPath: root.path) ?? []
        for relative in paths {
            let path = root.appendingPathComponent(relative).path
            chflags(path, 0)
            chmod(path, 0o755)
        }
        try FileManager.default.removeItem(at: root)
    }

    private func path(_ name: String) -> String { folder.appendingPathComponent(name).path }

    private func lock(_ name: String) { XCTAssertEqual(chflags(path(name), UInt32(UF_IMMUTABLE)), 0) }
    private func unlock(_ name: String) { XCTAssertEqual(chflags(path(name), 0), 0) }

    private func ops(calls: Box<[String]>, error: Error? = nil) -> FileOps {
        let trash = trash!
        return FileOps(
            trash: { url in
                calls.value.append(url.lastPathComponent)
                if let error { throw error }
                let destination = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            },
            restore: { try FileManager.default.moveItem(at: $0, to: $1) },
            deletePermanently: { try FileManager.default.removeItem(at: $0) }
        )
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), "timed out")
    }

    private func openFolder(_ session: LibrarySession) async {
        session.open([folder])
        await spin { session.list.count == 4 }
    }

    // MARK: Identity

    /// chflags and chmod change the ctime only: the key, hence frames and disk cache, survive.
    func testLockingKeepsThePhotoKey() throws {
        let before = try XCTUnwrap(PhotoKey.read(path: path("a.arw")))
        var info = stat()
        stat(path("a.arw"), &info)
        let mtime = info.st_mtimespec, ctime = info.st_ctimespec
        usleep(20_000)

        lock("a.arw")
        XCTAssertEqual(PhotoKey.read(path: path("a.arw")), before)
        XCTAssertEqual(FileProtection.read(path: path("a.arw")), .locked)
        stat(path("a.arw"), &info)
        XCTAssertEqual(info.st_mtimespec.tv_sec, mtime.tv_sec)
        XCTAssertEqual(info.st_mtimespec.tv_nsec, mtime.tv_nsec)
        XCTAssertNotEqual(info.st_ctimespec.tv_nsec, ctime.tv_nsec, "the ctime moves, which PhotoKey ignores")

        unlock("a.arw")
        chmod(path("a.arw"), 0o444)
        XCTAssertEqual(PhotoKey.read(path: path("a.arw")), before)
        XCTAssertEqual(FileProtection.read(path: path("a.arw")), .readOnly)
    }

    func testScanCollectsProtection() {
        lock("a.arw")
        chmod(path("b.arw"), 0o444)
        let snapshot = FolderScanner.scan(folder: folder, only: nil)
        XCTAssertEqual(snapshot.photos.map(\.name), ["a.arw", "b.arw", "c.arw", "d.arw"])
        XCTAssertEqual(snapshot.protection, [path("a.arw"): .locked, path("b.arw"): .readOnly])
    }

    // MARK: Refusal

    func testKnownProtectionIsRefusedWithoutQueueing() async throws {
        lock("a.arw")
        let calls = Box<[String]>([])
        let session = LibrarySession(fileOps: ops(calls: calls))
        await openFolder(session)
        XCTAssertEqual(session.protection(of: session.list.current!), .locked)

        XCTAssertFalse(session.trashCurrent(direction: 1))
        XCTAssertFalse(session.hasPendingIO)
        XCTAssertEqual(session.list.count, 4)
        XCTAssertEqual(session.list.current?.name, "a.arw")
        XCTAssertEqual(calls.value, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("a.arw")))
    }

    /// The comparison's « keep this one » deletes the others in one gesture: a protected one stays.
    func testGroupedDeletionLeavesProtectedPhotos() async throws {
        lock("b.arw")
        let calls = Box<[String]>([])
        let session = LibrarySession(fileOps: ops(calls: calls))
        await openFolder(session)
        let photos = session.list.photos

        XCTAssertFalse(session.trash([photos[1]]), "only a protected photo: nothing to do")
        XCTAssertTrue(session.trash([photos[1], photos[2]]))
        await spin { !session.hasPendingIO }
        XCTAssertEqual(calls.value, ["c.arw"])
        XCTAssertEqual(session.list.photos.map(\.name), ["a.arw", "b.arw", "d.arw"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("b.arw")))
    }

    /// Locked after the scan: the queue sees it before the Trash is asked, and never unlocks it.
    func testLockSetAfterScanIsCaughtInTheQueue() async throws {
        let calls = Box<[String]>([])
        let session = LibrarySession(fileOps: ops(calls: calls))
        await openFolder(session)
        var failure: TrashFailure?
        session.onEvent = { if case .trashFailed(_, let f) = $0 { failure = f } }
        lock("a.arw")

        XCTAssertTrue(session.trashCurrent(direction: 1))
        await spin { failure != nil && !session.hasPendingIO }
        XCTAssertEqual(failure, .locked)
        XCTAssertFalse(failure!.allowsPermanentDelete)
        XCTAssertEqual(calls.value, [], "the Trash is not even tried")
        XCTAssertEqual(session.list.photos.map(\.name), ["a.arw", "b.arw", "c.arw", "d.arw"])
        XCTAssertEqual(session.protection[path("a.arw")], .locked, "badge and refusal from now on")
        XCTAssertEqual(FileProtection.read(path: path("a.arw")), .locked, "still locked")
        XCTAssertFalse(session.undo())
    }

    func testReadOnlyFileIsCaughtInTheQueue() async throws {
        let calls = Box<[String]>([])
        let session = LibrarySession(fileOps: ops(calls: calls))
        await openFolder(session)
        var failure: TrashFailure?
        session.onEvent = { if case .trashFailed(_, let f) = $0 { failure = f } }
        chmod(path("a.arw"), 0o444)

        session.trashCurrent(direction: 1)
        await spin { failure != nil }
        XCTAssertEqual(failure, .fileNotWritable)
        XCTAssertEqual(calls.value, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("a.arw")))
    }

    /// A real permission error from a folder without write access, not a simulated one.
    func testReadOnlyFolderIsNotOfferedPermanentDeletion() async throws {
        let calls = Box<[String]>([])
        let session = LibrarySession(fileOps: ops(calls: calls))
        await openFolder(session)
        var failure: TrashFailure?
        session.onEvent = { if case .trashFailed(_, let f) = $0 { failure = f } }
        chmod(folder.path, 0o555)

        session.trashCurrent(direction: 1)
        await spin { failure != nil }
        XCTAssertEqual(failure, .folderNotWritable)
        XCTAssertFalse(failure!.allowsPermanentDelete)
        chmod(folder.path, 0o755)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("a.arw")))
    }

    func testOnlyAVolumeWithoutTrashOffersPermanentDeletion() async throws {
        let calls = Box<[String]>([])
        let session = LibrarySession(fileOps: ops(calls: calls, error: CocoaError(.featureUnsupported)))
        await openFolder(session)
        var failure: TrashFailure?
        session.onEvent = { if case .trashFailed(_, let f) = $0 { failure = f } }

        session.trashCurrent(direction: 1)
        await spin { failure != nil }
        XCTAssertEqual(failure, .noTrash)
        XCTAssertTrue(failure!.allowsPermanentDelete)
        XCTAssertEqual(session.list.count, 4, "kept until the user confirms")
    }

    func testPermanentDeletionNeverBypassesALock() async throws {
        let session = LibrarySession(fileOps: ops(calls: Box([])))
        await openFolder(session)
        var message: String?
        session.onEvent = { if case .deleteFailed(_, let m) = $0 { message = m } }
        let photo = session.list.current!
        lock("a.arw")

        session.deletePermanently(photo)
        await spin { message != nil }
        XCTAssertEqual(message, TrashFailure.locked.explanation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("a.arw")))
        await spin { session.list.count == 4 }
    }

    // MARK: Updates

    /// Unlocking in the Finder shows up at the next scan as a badge change, not a list change.
    func testUnlockIsAProtectionChangeOnly() async throws {
        lock("a.arw")
        let session = LibrarySession(fileOps: ops(calls: Box([])))
        await openFolder(session)
        XCTAssertFalse(session.protection(of: session.list.current!).isEmpty)
        var events: [String] = []
        session.onEvent = { events.append("\($0)") }

        unlock("a.arw")
        session.requestScan()
        await spin { session.protection.isEmpty }
        XCTAssertEqual(events, ["protectionChanged"])
        XCTAssertTrue(session.trashCurrent(direction: 1))
        await spin { !session.hasPendingIO }
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("a.arw").path))
    }

    // MARK: Classification

    /// Codes measured with trashItem on disk images (macOS 27).
    func testClassificationLooksAtTheDiskFirst() {
        let denied = NSError(domain: NSCocoaErrorDomain, code: 513,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -5000)])
        let unsupported = NSError(domain: NSCocoaErrorDomain, code: 3328,
                                  userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -120)])

        XCTAssertEqual(TrashFailure.classify(denied, probe: TrashProbe(protection: .locked)), .locked)
        XCTAssertEqual(TrashFailure.classify(denied, probe: TrashProbe(protection: .readOnly)), .fileNotWritable)
        XCTAssertEqual(TrashFailure.classify(denied, probe: TrashProbe(folderWritable: false)), .folderNotWritable)
        // A read-only volume answers 3328, like a volume without Trash: it must not offer deletion.
        XCTAssertEqual(TrashFailure.classify(unsupported, probe: TrashProbe(volumeReadOnly: true)), .readOnlyVolume)
        XCTAssertEqual(TrashFailure.classify(CocoaError(.fileWriteVolumeReadOnly), probe: TrashProbe()), .readOnlyVolume)
        XCTAssertEqual(TrashFailure.classify(POSIXError(.EROFS), probe: TrashProbe()), .readOnlyVolume)
        XCTAssertEqual(TrashFailure.classify(unsupported, probe: TrashProbe()), .noTrash)
        // Unexplained or transient errors keep the file and offer nothing.
        guard case .other = TrashFailure.classify(denied, probe: TrashProbe()) else { return XCTFail() }
        guard case .other = TrashFailure.classify(POSIXError(.EBUSY), probe: TrashProbe()) else { return XCTFail() }

        let all: [TrashFailure] = [.locked, .fileNotWritable, .folderNotWritable, .readOnlyVolume, .noTrash, .other("x")]
        XCTAssertEqual(all.filter(\.allowsPermanentDelete), [.noTrash])
    }

    func testProbeReadsTheFolder() {
        XCTAssertEqual(TrashProbe.read(path: path("a.arw")), TrashProbe())
        chmod(folder.path, 0o555)
        XCTAssertFalse(TrashProbe.read(path: path("a.arw")).folderWritable)
        chmod(folder.path, 0o755)
    }
}
