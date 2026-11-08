import AppKit
import XCTest
@testable import BetterView

/// The history window on a fake Trash. With `TEST_RUNNER_BV_SAMPLE_ARW` (a folder of real ARW,
/// only copied) and `TEST_RUNNER_BV_SNAPSHOT` (a PNG path), it also renders the real window.
@MainActor
final class HistoryWindowTests: XCTestCase {
    private var root: URL!
    private var folder: URL!
    private var trash: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BVWindow-\(UUID().uuidString)")
        folder = root.appendingPathComponent("photos")
        trash = root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
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

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out")
    }

    /// Restored, taken out of the Trash, deleted for good, and two still in the Trash.
    private func populate(_ names: [String]) async throws -> LibrarySession {
        let session = LibrarySession(fileOps: ops())
        session.open([folder])
        await spin { session.list.count == names.count }
        for _ in 0..<(names.count - 1) {
            session.trashCurrent(direction: 1)
            await spin { !session.hasPendingIO }
            try await Task.sleep(for: .milliseconds(20))
        }
        let last = try XCTUnwrap(session.list.current)
        session.deletePermanently(last)
        await spin { !session.hasPendingIO }
        let entries = session.history.newestFirst.filter { $0.phase == .inTrash }.reversed()
        let restored = try XCTUnwrap(entries.first)
        session.restore(restored.id)
        await spin { !session.hasPendingIO }
        let gone = try XCTUnwrap(entries.dropFirst().first)
        try FileManager.default.removeItem(atPath: try XCTUnwrap(gone.trashPath))
        return session
    }

    private func rows(_ controller: HistoryWindowController) -> [HistoryRow] {
        let table = controller.window.contentView!.subviews.compactMap { $0 as? NSScrollView }.first!.documentView as! NSTableView
        table.layoutSubtreeIfNeeded()
        return (0..<table.numberOfRows).compactMap { table.view(atColumn: 0, row: $0, makeIfNecessary: true) as? HistoryRow }
    }

    private func texts(_ view: NSView) -> [String] {
        view.subviews.flatMap { sub -> [String] in
            if let label = sub as? NSTextField, !label.isHidden { return [label.stringValue] + texts(sub) }
            if let button = sub as? NSButton, !button.isHidden { return [button.title + (button.isEnabled ? "" : " (inactif)")] }
            return texts(sub)
        }
    }

    func testShowsTheFolderDeletionsWithRestoreOnlyWhenPossible() async throws {
        let names = ["a.arw", "b.arw", "c.arw", "d.arw", "e.arw"]
        for name in names { try Data(name.utf8).write(to: folder.appendingPathComponent(name)) }
        let session = try await populate(names)
        // Another folder's deletion stays out of this window.
        let elsewhere = try XCTUnwrap(PhotoKey.read(path: folder.appendingPathComponent("a.arw").path))
        session.history.update(DeletionRecord(photo: PhotoKey(
            path: "/elsewhere/z.arw", device: elsewhere.device, inode: 1, size: 1, mtimeSeconds: 0, mtimeNanoseconds: 0
        ), phase: .deleted))

        let folderPath = HistoryWindowController.standardized(folder.path)
        let controller = HistoryWindowController(session: session) { folderPath }
        controller.show()
        defer { controller.window.close() }
        await spin { controller.entries.count == 5 }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.window.title, "Suppressions · photos")
        XCTAssertEqual(controller.entries.map(\.name), ["e.arw", "d.arw", "c.arw", "b.arw", "a.arw"])
        let lines = rows(controller).map { texts($0).filter { $0 != "À l'instant" } }
        XCTAssertEqual(lines, [
            ["e.arw", "Supprimée définitivement"],
            ["d.arw", "Restaurer"],
            ["c.arw", "Restaurer"],
            ["b.arw", "Plus dans la corbeille"],
            ["a.arw", "Restaurée"],
        ])

        // The button goes through the same engine as ⌘Z, and later deletions stay.
        let c = try XCTUnwrap(controller.entries.first { $0.name == "c.arw" })
        XCTAssertTrue(session.restore(c.id))
        await spin { !session.hasPendingIO }
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("c.arw").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("d.arw").path))
        await spin { self.rows(controller).map(self.texts).contains { $0.first == "c.arw" && $0.contains("Restaurée") } }
    }

    func testEmptyWithoutAFolder() async throws {
        let controller = HistoryWindowController(session: LibrarySession(fileOps: ops())) { nil }
        controller.show()
        defer { controller.window.close() }
        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertTrue(texts(controller.window.contentView!).contains("Aucun dossier ouvert"))
    }

    func testDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(HistoryRow.format(now.addingTimeInterval(-5), now: now), "À l'instant")
        XCTAssertEqual(HistoryRow.format(now.addingTimeInterval(-150), now: now), "Il y a 2 min")
        XCTAssertTrue(HistoryRow.format(Date().addingTimeInterval(-86_400)).hasPrefix("Hier"))
        XCTAssertTrue(HistoryRow.format(now.addingTimeInterval(-86_400 * 10), now: now).contains("2027"))
    }

    /// Real previews from copies of real files, and a PNG of the real window.
    func testRenderWithRealPreviews() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let samples = env["BV_SAMPLE_ARW"], let output = env["BV_SNAPSHOT"] else {
            throw XCTSkip("BV_SAMPLE_ARW and BV_SNAPSHOT not set")
        }
        let sources = try FileManager.default.contentsOfDirectory(atPath: samples)
            .filter { $0.lowercased().hasSuffix(".arw") }.sorted().prefix(5)
        XCTAssertEqual(sources.count, 5)
        for name in sources {
            try FileManager.default.copyItem(atPath: (samples as NSString).appendingPathComponent(name),
                                             toPath: folder.appendingPathComponent(name).path)
        }
        let session = try await populate(Array(sources))
        let folderPath = HistoryWindowController.standardized(folder.path)
        let controller = HistoryWindowController(session: session) { folderPath }
        controller.window.setContentSize(NSSize(width: 620, height: 5 * HistoryRow.height))
        controller.show()
        defer { controller.window.close() }
        // In the Trash or restored: both have a preview; the others never do.
        await spin(until: {
            self.rows(controller).filter(\.hasThumbnail).count == 3
        }, timeout: 10)
        try await Task.sleep(for: .milliseconds(300))
        let content = try XCTUnwrap(controller.window.contentView)
        content.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
}
