import XCTest
@testable import BetterView

/// Scanner and file operations that wait until the test releases them, which lets the tests
/// force the exact interleavings the architecture has to survive.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiters: [DispatchSemaphore] = []

    func wait() {
        lock.lock()
        if open { lock.unlock(); return }
        let semaphore = DispatchSemaphore(value: 0)
        waiters.append(semaphore)
        lock.unlock()
        semaphore.wait()
    }

    func release() {
        lock.lock()
        open = true
        let all = waiters
        waiters = []
        lock.unlock()
        all.forEach { $0.signal() }
    }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

@MainActor
final class LibrarySessionTests: XCTestCase {
    private var folder: URL!
    private var trash: URL!

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BVTests-\(UUID().uuidString)")
        folder = root.appendingPathComponent("photos")
        trash = root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        for name in ["a", "b", "c", "d"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent("\(name).arw"))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    private func ops(gate: Gate? = nil) -> FileOps {
        let trash = trash!
        return FileOps(
            trash: { url in
                gate?.wait()
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

    private func names(_ session: LibrarySession) -> [String] { session.list.photos.map(\.name) }

    /// The real Trash, with a net effect of zero: the file comes back.
    func testSystemTrashThenRestore() async throws {
        let session = LibrarySession(fileOps: .system)
        await openFolder(session)
        let path = folder.appendingPathComponent("a.arw").path
        session.trashCurrent(direction: 1)
        await spin { !session.hasPendingIO }
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(session.undo())
        await spin { !session.hasPendingIO && session.list.count == 4 }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(session.list.current?.name, "a.arw")
    }

    func testDeletedPhotosDoNotComeBackDuringRescan() async throws {
        let gate = Gate()
        let session = LibrarySession(fileOps: ops(gate: gate))
        await openFolder(session)

        // a then b are queued, neither is trashed yet, and a scan sees both still on disk.
        session.trashCurrent(direction: 1)
        session.trashCurrent(direction: 1)
        XCTAssertEqual(names(session), ["c.arw", "d.arw"])
        session.requestScan()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(names(session), ["c.arw", "d.arw"], "a tombstone must beat the scan")

        gate.release()
        await spin { !session.hasPendingIO }
        session.requestScan()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(names(session), ["c.arw", "d.arw"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("a.arw").path))
    }

    func testScanStartedBeforeAnOperationFinishedIsDiscarded() async throws {
        let scanGate = Gate()
        let useGate = Box(false)
        let session = LibrarySession(fileOps: ops(), scanner: { folder, allowed in
            let snapshot = FolderScanner.scan(folder: folder, only: allowed)
            if useGate.value { scanGate.wait() }
            return snapshot
        })
        await openFolder(session)

        // This scan has already read a.arw when the deletion completes.
        useGate.value = true
        session.requestScan()
        try await Task.sleep(for: .milliseconds(50))
        session.trashCurrent(direction: 1)
        await spin { !session.hasPendingIO }
        useGate.value = false
        scanGate.release()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(names(session), ["b.arw", "c.arw", "d.arw"])
    }

    func testUndoDuringPendingTrashRestoresAfterwards() async throws {
        let gate = Gate()
        let session = LibrarySession(fileOps: ops(gate: gate))
        await openFolder(session)
        session.trashCurrent(direction: 1)
        XCTAssertTrue(session.undo())
        gate.release()
        await spin { !session.hasPendingIO && session.list.count == 4 }
        XCTAssertEqual(session.list.current?.name, "a.arw")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a.arw").path))
        XCTAssertFalse(session.undo(), "nothing left to undo")
    }

    func testUndoNeverOverwrites() async throws {
        let session = LibrarySession(fileOps: ops())
        await openFolder(session)
        var failed = false
        session.onEvent = { if case .restoreFailed = $0 { failed = true } }
        session.trashCurrent(direction: 1)
        await spin { !session.hasPendingIO }
        let path = folder.appendingPathComponent("a.arw")
        try Data("new".utf8).write(to: path)
        XCTAssertTrue(session.undo())
        await spin { failed }
        XCTAssertEqual(try Data(contentsOf: path), Data("new".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("a.arw").path))
    }

    func testReplacedFileIsNotDeleted() async throws {
        let session = LibrarySession(fileOps: ops())
        await openFolder(session)
        var changed = false
        session.onEvent = { if case .fileChanged = $0 { changed = true } }
        // Writing elsewhere then renaming over guarantees a new inode.
        let path = folder.appendingPathComponent("a.arw")
        let replacement = folder.appendingPathComponent(".replacement")
        try Data("other content".utf8).write(to: replacement)
        _ = rename(replacement.path, path.path)
        session.trashCurrent(direction: 1)
        await spin { changed }
        XCTAssertEqual(try Data(contentsOf: path), Data("other content".utf8), "a new revision must survive")
        await spin { session.list.photos.contains { $0.name == "a.arw" } }
    }

    func testFailedTrashReinserts() async throws {
        var fileOps = ops()
        fileOps.trash = { _ in throw CocoaError(.fileWriteVolumeReadOnly) }
        let session = LibrarySession(fileOps: fileOps)
        await openFolder(session)
        var failure: PhotoKey?
        session.onEvent = { if case .trashFailed(let photo, _) = $0 { failure = photo } }
        session.trashCurrent(direction: 1)
        await spin { failure != nil }
        XCTAssertEqual(names(session), ["a.arw", "b.arw", "c.arw", "d.arw"])
        XCTAssertFalse(session.undo(), "a failed deletion is not undoable")
    }

    func testPermanentDeleteIsNotUndoable() async throws {
        let session = LibrarySession(fileOps: ops())
        await openFolder(session)
        let photo = session.list.current!
        session.deletePermanently(photo)
        await spin { !session.hasPendingIO }
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertFalse(session.undo())
    }

    func testSnapshotFromPreviousFolderIsRejected() async throws {
        let scanGate = Gate()
        let other = folder.deletingLastPathComponent().appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("z".utf8).write(to: other.appendingPathComponent("z.arw"))
        let firstFolder = folder!
        let session = LibrarySession(fileOps: ops(), scanner: { folder, allowed in
            let snapshot = FolderScanner.scan(folder: folder, only: allowed)
            if folder == firstFolder { scanGate.wait() }
            return snapshot
        })
        session.open([firstFolder])
        try await Task.sleep(for: .milliseconds(50))
        session.open([other])
        // The serial scan queue runs the second scan only after the first one is released.
        scanGate.release()
        await spin { session.list.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(names(session), ["z.arw"])
    }

    func testChangeDuringScanTriggersANewScan() async throws {
        let scanGate = Gate()
        let useGate = Box(false)
        let session = LibrarySession(fileOps: ops(), scanner: { folder, allowed in
            let snapshot = FolderScanner.scan(folder: folder, only: allowed)
            if useGate.value {
                useGate.value = false
                scanGate.wait()
            }
            return snapshot
        })
        await openFolder(session)
        useGate.value = true
        session.requestScan()
        try await Task.sleep(for: .milliseconds(50))
        // Arrives while the scan runs: it must not be lost, and the later scan must win.
        try Data("e".utf8).write(to: folder.appendingPathComponent("e.arw"))
        session.requestScan()
        scanGate.release()
        await spin { session.list.count == 5 }
    }

    func testSingleFileIsPositionedOnIt() async throws {
        let session = LibrarySession(fileOps: ops())
        session.open([folder.appendingPathComponent("c.arw")])
        await spin { session.list.count == 4 }
        XCTAssertEqual(session.list.current?.name, "c.arw")
    }

    func testSeveralFilesOpenOnlyThose() async throws {
        let session = LibrarySession(fileOps: ops())
        session.open([folder.appendingPathComponent("b.arw"), folder.appendingPathComponent("d.arw")])
        await spin { session.list.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(names(session), ["b.arw", "d.arw"])
    }
}
