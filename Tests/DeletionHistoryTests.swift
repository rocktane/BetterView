import XCTest
@testable import BetterView

/// The history and its journal, with a fake Trash in a temporary folder: never the real one,
/// never the real Application Support.
@MainActor
final class DeletionHistoryTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var trash: URL!
    private var journalURL: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BVHistory-\(UUID().uuidString)")
        folder = root.appendingPathComponent("photos")
        trash = root.appendingPathComponent("trash")
        journalURL = root.appendingPathComponent("support/suppressions.jsonl")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        for name in ["a", "b", "c", "d"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent("\(name).arw"))
        }
    }

    override func tearDown() async throws {
        _ = chmod(trash.path, 0o755)
        try? FileManager.default.removeItem(at: root)
    }

    private func ops() -> FileOps {
        let trash = trash!
        return FileOps(
            trash: { url in
                let destination = trash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            },
            restore: { try FileManager.default.moveItem(at: $0, to: $1) },
            deletePermanently: { try FileManager.default.removeItem(at: $0) }
        )
    }

    private func session(journal: Bool = false) -> LibrarySession {
        LibrarySession(fileOps: ops(), journal: journal ? DeletionJournal(url: journalURL) : nil)
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), "timed out")
    }

    private func open(_ session: LibrarySession) async {
        session.open([folder])
        await spin { session.list.count == 4 }
    }

    private func trashAll(_ session: LibrarySession, _ count: Int) async {
        for _ in 0..<count { session.trashCurrent(direction: 1) }
        await spin { !session.hasPendingIO }
    }

    private func entry(_ session: LibrarySession, _ name: String) -> DeletionRecord? {
        session.history.newestFirst.first { $0.name == name }
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    // MARK: Restoring one entry

    func testRestoringOneEntryKeepsLaterDeletions() async throws {
        let session = session()
        await open(session)
        await trashAll(session, 3)
        XCTAssertEqual(session.history.newestFirst.map(\.name), ["c.arw", "b.arw", "a.arw"])
        let a = try XCTUnwrap(entry(session, "a.arw"))
        XCTAssertEqual(session.history.status(a.id), .inTrash)
        XCTAssertEqual(a.trashPath, trash.appendingPathComponent("a.arw").path, "the URL returned by the move")

        XCTAssertTrue(session.restore(a.id))
        await spin { !session.hasPendingIO }
        XCTAssertTrue(exists("a.arw"))
        XCTAssertFalse(exists("b.arw"))
        XCTAssertFalse(exists("c.arw"))
        XCTAssertEqual(session.list.current?.name, "a.arw")
        guard case .restored = session.history.status(a.id) else { return XCTFail("restored expected") }
        XCTAssertFalse(session.restore(a.id), "only once")

        // ⌘Z still takes the latest deletion, then the one before, and skips the restored one.
        XCTAssertTrue(session.undo())
        await spin { !session.hasPendingIO }
        XCTAssertTrue(exists("c.arw"))
        XCTAssertTrue(session.undo())
        await spin { !session.hasPendingIO }
        XCTAssertTrue(exists("b.arw"))
        XCTAssertFalse(session.undo())
    }

    func testUndoSkipsAnEntryAlreadyRestoredFromTheHistory() async throws {
        let session = session()
        await open(session)
        await trashAll(session, 2)
        let b = try XCTUnwrap(entry(session, "b.arw"))
        session.restore(b.id)
        await spin { !session.hasPendingIO }
        XCTAssertTrue(session.undo())
        await spin { !session.hasPendingIO }
        XCTAssertTrue(exists("a.arw"))
        XCTAssertFalse(session.undo())
    }

    // MARK: Edge cases

    func testFileTakenOutOfTheTrashIsUnavailable() async throws {
        let session = session()
        await open(session)
        var messages: [String] = []
        session.onEvent = { if case .restoreFailed(_, let message) = $0 { messages.append(message) } }
        await trashAll(session, 1)
        let a = try XCTUnwrap(entry(session, "a.arw"))
        try FileManager.default.removeItem(at: trash.appendingPathComponent("a.arw"))

        session.history.check([a.id])
        await spin { session.history.status(a.id) != .inTrash }
        guard case .unavailable = session.history.status(a.id) else { return XCTFail("unavailable expected") }

        XCTAssertTrue(session.undo(), "the history only knew it was in the Trash")
        await spin { !session.hasPendingIO && messages.count == 1 }
        XCTAssertTrue(messages[0].contains("plus dans la corbeille"))
        guard case .unavailable = session.history.status(a.id) else { return XCTFail("unavailable expected") }
        XCTAssertFalse(session.undo(), "a restore that can never work leaves the stack")
        XCTAssertFalse(exists("a.arw"))
    }

    /// Permission refused is not the same as absent, and stays retryable.
    func testInaccessibleTrashIsNotMissing() async throws {
        let session = session()
        await open(session)
        await trashAll(session, 1)
        let a = try XCTUnwrap(entry(session, "a.arw"))
        XCTAssertEqual(chmod(trash.path, 0), 0)
        session.history.check([a.id])
        await spin { session.history.status(a.id) != .inTrash }
        guard case .inaccessible = session.history.status(a.id) else {
            return XCTFail("inaccessible expected, got \(String(describing: session.history.status(a.id)))")
        }
        XCTAssertTrue(session.undo())
        await spin { !session.hasPendingIO }
        XCTAssertFalse(exists("a.arw"))

        XCTAssertEqual(chmod(trash.path, 0o755), 0)
        XCTAssertTrue(session.undo(), "still undoable once access is back")
        await spin { !session.hasPendingIO }
        XCTAssertTrue(exists("a.arw"))
    }

    func testOccupiedOriginIsRefusedAndRetryableFromTheHistory() async throws {
        let session = session()
        await open(session)
        await trashAll(session, 1)
        let a = try XCTUnwrap(entry(session, "a.arw"))
        let path = folder.appendingPathComponent("a.arw")
        try Data("new".utf8).write(to: path)
        XCTAssertTrue(session.restore(a.id))
        await spin { !session.hasPendingIO }
        XCTAssertEqual(try Data(contentsOf: path), Data("new".utf8))
        XCTAssertEqual(session.history.status(a.id), .inTrash)
        try FileManager.default.removeItem(at: path)
        XCTAssertTrue(session.restore(a.id))
        await spin { !session.hasPendingIO }
        XCTAssertEqual(try Data(contentsOf: path), Data("a".utf8))
    }

    func testPermanentDeletionIsRecordedWithoutRestore() async throws {
        let session = session()
        await open(session)
        let photo = try XCTUnwrap(session.list.current)
        session.deletePermanently(photo)
        await spin { !session.hasPendingIO }
        let a = try XCTUnwrap(entry(session, "a.arw"))
        XCTAssertEqual(session.history.status(a.id), .deletedPermanently)
        XCTAssertFalse(session.history.status(a.id)!.canRestore)
        XCTAssertFalse(session.restore(a.id))
    }

    func testFailedOrRefusedDeletionLeavesNoEntry() async throws {
        var fileOps = ops()
        fileOps.trash = { _ in throw CocoaError(.fileWriteVolumeReadOnly) }
        let session = LibrarySession(fileOps: fileOps, journal: DeletionJournal(url: journalURL))
        await open(session)
        session.trashCurrent(direction: 1)
        await spin { !session.hasPendingIO }
        XCTAssertTrue(session.history.newestFirst.isEmpty)
        XCTAssertTrue(DeletionJournal(url: journalURL).load().isEmpty)
    }

    // MARK: Journal

    /// An unwritable journal never blocks a deletion, and says so once.
    func testUnwritableJournalIsReportedOnceAndDeletionsGoOn() async throws {
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let session = LibrarySession(fileOps: ops(), journal: DeletionJournal(url: blocker.appendingPathComponent("j.jsonl")))
        await open(session)
        var reports = 0
        session.onEvent = { if case .historyNotSaved = $0 { reports += 1 } }
        await trashAll(session, 2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(reports, 1)
        XCTAssertFalse(exists("a.arw"))
        XCTAssertTrue(session.undo())
        await spin { !session.hasPendingIO }
        XCTAssertTrue(exists("b.arw"))
    }

    func testHistoryAndRestoreSurviveARelaunch() async throws {
        let first = session(journal: true)
        await open(first)
        await trashAll(first, 2)
        let a = try XCTUnwrap(entry(first, "a.arw"))

        let second = session(journal: true)
        await spin { second.history.newestFirst.count == 2 }
        XCTAssertEqual(second.history[a.id], a)
        XCTAssertFalse(second.undo(), "⌘Z belongs to the launch that deleted")
        second.open([folder])
        await spin { second.list.count == 2 }
        XCTAssertTrue(second.restore(a.id))
        await spin { !second.hasPendingIO }
        XCTAssertTrue(exists("a.arw"))
        XCTAssertEqual(second.list.current?.name, "a.arw")

        let third = session(journal: true)
        await spin { third.history.newestFirst.count == 2 }
        guard case .restored = third.history.status(a.id) else { return XCTFail("restored expected") }
    }

    private func write(_ records: [DeletionRecord]) throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let journal = DeletionJournal(url: journalURL)
        records.forEach(journal.append)
    }

    private func key(_ name: String, in directory: URL? = nil) throws -> PhotoKey {
        try XCTUnwrap(PhotoKey.read(path: (directory ?? folder).appendingPathComponent(name).path))
    }

    /// Interrupted between the move and the next line: no false certainty either way.
    func testInterruptedDeletionIsLeftToCheck() async throws {
        let stillHere = DeletionRecord(photo: try key("a.arw"), phase: .trashing)
        let moved = DeletionRecord(photo: try key("b.arw"), phase: .trashing)
        try FileManager.default.moveItem(at: folder.appendingPathComponent("b.arw"), to: trash.appendingPathComponent("b.arw"))
        try write([stillHere, moved])

        let loaded = DeletionJournal(url: journalURL).load()
        XCTAssertEqual(loaded.map(\.id), [moved.id], "a file still in place was never deleted")
        XCTAssertEqual(loaded.first?.phase, .unverified)
        XCTAssertNil(loaded.first?.trashPath, "the Trash is never searched")
    }

    func testInterruptedRestoreIsSettledFromTheDisk() async throws {
        func trashed(_ name: String) throws -> DeletionRecord {
            let photo = try key(name)
            try FileManager.default.moveItem(at: folder.appendingPathComponent(name), to: trash.appendingPathComponent(name))
            var record = DeletionRecord(photo: photo, phase: .restoring)
            record.trashPath = trash.appendingPathComponent(name).path
            record.trashRevision = try key(name, in: trash).revision
            return record
        }
        let notMoved = try trashed("a.arw")
        let movedBack = try trashed("b.arw")
        try FileManager.default.moveItem(at: trash.appendingPathComponent("b.arw"), to: folder.appendingPathComponent("b.arw"))
        let lost = try trashed("c.arw")
        try FileManager.default.removeItem(at: trash.appendingPathComponent("c.arw"))
        try write([notMoved, movedBack, lost])

        let loaded = Dictionary(uniqueKeysWithValues: DeletionJournal(url: journalURL).load().map { ($0.id, $0.phase) })
        XCTAssertEqual(loaded[notMoved.id], .inTrash)
        XCTAssertEqual(loaded[movedBack.id], .restored)
        XCTAssertEqual(loaded[lost.id], .unverified)
    }

    func testJournalSkipsDamagedLinesAndKeepsTheNewest() async throws {
        let photo = try key("a.arw")
        var records: [DeletionRecord] = []
        for i in 0..<5 {
            var record = DeletionRecord(photo: photo, phase: .deleted, date: Date(timeIntervalSince1970: Double(i)))
            record.trashPath = nil
            records.append(record)
        }
        try write(records)
        let handle = try FileHandle(forWritingTo: journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\": broken".utf8))
        try handle.close()

        let loaded = DeletionJournal(url: journalURL, limit: 3).load()
        XCTAssertEqual(loaded.map(\.id), records.suffix(3).reversed().map(\.id))
        let lines = try String(contentsOf: journalURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3, "compacted")
    }
}
