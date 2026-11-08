import CoreGraphics
import Foundation

/// Small previews for the history window, read on request from the file where it is now (the
/// Trash URL returned by the move, or the origin once restored). One at a time, below the
/// priority of the viewer's work, and only for rows on screen. Kept as small CGImages, never
/// as IOSurfaces, and dropped when the window closes. A missing preview never blocks a restore.
@MainActor
final class HistoryThumbnails {
    /// 180 × 120 points on a Retina screen.
    nonisolated static let maxPixel = 360
    private static let capacity = 200
    private static let maxQueued = 40

    var onLoaded: (UUID) -> Void = { _ in }

    private var images: [UUID: CGImage] = [:]
    private var order: [UUID] = []
    /// Known to have no preview at that revision: not asked again until the entry changes.
    private var absent: [UUID: String] = [:]
    private var queued: [UUID: Operation] = [:]
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "betterview.history.thumbnails"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }()

    func image(_ id: UUID) -> CGImage? { images[id] }

    /// Where a preview can be read for this entry, if anywhere, with the revision it must have.
    static func source(of record: DeletionRecord) -> (path: String, revision: FileRevision)? {
        switch record.phase {
        case .inTrash: record.trashPath.map { ($0, record.expectedInTrash) }
        case .restored: (record.originPath, record.source)
        default: nil
        }
    }

    func request(_ record: DeletionRecord) {
        let id = record.id
        guard images[id] == nil, queued[id] == nil, let source = Self.source(of: record) else { return }
        let tag = "\(record.phase.rawValue)|\(source.path)"
        guard absent[id] != tag else { return }
        if queued.count >= Self.maxQueued, let oldest = queued.first {
            oldest.value.cancel()
            queued[oldest.key] = nil
        }
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation] in
            guard operation?.isCancelled == false else { return }
            let image = Self.load(path: source.path, revision: source.revision)
            let box = ImageBox(image: image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, self.queued[id] === operation else { return }
                    self.queued[id] = nil
                    if let image = box.image {
                        self.store(id, image)
                    } else {
                        self.absent[id] = tag
                    }
                    self.onLoaded(id)
                }
            }
        }
        queued[id] = operation
        queue.addOperation(operation)
    }

    /// The row left the screen: its preview is no longer worth reading.
    func cancel(_ id: UUID) {
        queued.removeValue(forKey: id)?.cancel()
    }

    func forget(_ id: UUID) {
        cancel(id)
        images[id] = nil
        absent[id] = nil
        order.removeAll { $0 == id }
    }

    func clear() {
        queue.cancelAllOperations()
        queued = [:]
        images = [:]
        order = []
        absent = [:]
    }

    private func store(_ id: UUID, _ image: CGImage) {
        images[id] = image
        order.append(id)
        if order.count > Self.capacity {
            images[order.removeFirst()] = nil
        }
    }

    private struct ImageBox: @unchecked Sendable { let image: CGImage? }

    /// Reads the embedded preview, only if the file is still the expected revision before and
    /// after. Blocking.
    nonisolated static func load(path: String, revision: FileRevision) -> CGImage? {
        guard PathState.inspect(path) == .file(revision) else { return nil }
        let image = Decoders.thumbnail(at: URL(fileURLWithPath: path), maxPixels: maxPixel)
        guard PathState.inspect(path) == .file(revision) else { return nil }
        return image
    }
}
