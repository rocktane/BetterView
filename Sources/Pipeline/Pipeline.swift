import CoreGraphics
import Foundation
import IOKit.ps

/// Schedules decode work and owns the caches. All its state lives on the main thread, so
/// no locks are needed: workers are pure functions and report back on the main queue.
@MainActor
final class Pipeline {
    private enum Source: Sendable {
        case preview
        case disk(url: URL, nativeSize: CGSize)
        case render
    }

    private struct Job: Sendable {
        let key: FrameKey
        let source: Source
        let target: CGSize
        let visible: Bool
        let background: Bool
    }

    private enum Outcome: Sendable {
        case frame(Frame)
        case stale
        case failed
        case diskMiss
    }

    private struct EncodeJob {
        let frame: Frame
        let entry: DiskCache.Entry
        let generation: Int
    }

    private static let fastSlots = 4
    private static let encodeBacklog = 4
    /// Background rendering pauses beyond this, which bounds frames waiting for encoding.
    private static let backgroundEncodeBacklog = 2

    let cache: FrameCache
    let disk: DiskCache
    var onFrame: (Frame) -> Void = { _ in }
    var onFailed: (FrameKey) -> Void = { _ in }
    var onStale: (PhotoKey) -> Void = { _ in }
    var onNeedsReplan: () -> Void = {}
    /// Frames left the cache under memory pressure: a view still holding them keeps them alive.
    var onEvicted: () -> Void = {}

    private(set) var target = CGSize.zero
    private(set) var memoryLevel = MemoryLevel.normal

    private var fastQueue: [Job] = []
    private var gpuQueue: [Job] = []
    private var encodeQueue: [EncodeJob] = []
    private var inFlight: Set<FrameKey> = []
    private var failed: Set<FrameKey> = []
    private var fastRunning = 0
    private var gpuRunning = 0
    private var gpuVisibleRunning = 0
    private var fullRunning = 0
    private var encodeRunning = false
    private var memorySource: DispatchSourceMemoryPressure?

    init(budgets: FrameCache.Budgets, disk: DiskCache) {
        cache = FrameCache(budgets: budgets)
        self.disk = disk
        startMemoryMonitoring()
    }

    /// True once nothing is queued or running. Used by tests and the benchmark.
    var isIdle: Bool {
        fastQueue.isEmpty && gpuQueue.isEmpty && encodeQueue.isEmpty
            && fastRunning == 0 && gpuRunning == 0 && !encodeRunning
    }

    func hasFailed(_ key: FrameKey) -> Bool { failed.contains(key) }

    // MARK: Target size

    /// The screen tier fits the largest screen rather than the window, so resizing the
    /// window never renders again.
    func setTarget(_ newTarget: CGSize) {
        guard newTarget != target else { return }
        target = newTarget
        disk.setTarget(newTarget)
        cache.removeAll(.screen)
    }

    /// Fills `input` with screen-window sizes that always fit the memory budget, even on a
    /// 6K display where one frame is four times larger.
    func applyWindowSizes(to input: inout PlanInput) {
        let frameBytes = max(target.width * target.height * 4, 1)
        let affordable = Int(0.8 * Double(cache.budget(.screen)) / Double(frameBytes))
        let total = max(3, min(29, affordable))
        input.screenAhead = max(1, Int(Double(total) * 0.7))
        input.screenBehind = max(1, total - input.screenAhead - 1)
        input.memory = memoryLevel
    }

    // MARK: Planning

    /// Replaces all queued work. Running jobs finish, and their results are cached under
    /// their own key, so a late result cannot end up attached to another revision.
    func plan(photos: [PhotoKey], input: PlanInput) {
        let items = WindowPlanner.plan(input)
        fastQueue.removeAll(keepingCapacity: true)
        gpuQueue.removeAll(keepingCapacity: true)
        var protected = Set<FrameKey>(minimumCapacity: items.count)

        for item in items {
            let photo = photos[item.index]
            let key = FrameKey(photo: photo, tier: item.tier)
            if !item.background { protected.insert(key) }
            if inFlight.contains(key) || failed.contains(key) || cache.contains(key) { continue }

            switch item.tier {
            case .preview:
                if cache.contains(FrameKey(photo: photo, tier: .screen)) { continue }
                fastQueue.append(job(key, .preview, item))
            case .screen:
                if let entry = disk.entry(photo) {
                    if item.background { continue }
                    fastQueue.append(job(key, .disk(url: disk.url(entry), nativeSize: entry.nativeSize), item))
                } else {
                    gpuQueue.append(job(key, .render, item))
                }
            case .full:
                gpuQueue.append(job(key, .render, item))
            }
        }
        cache.protected = protected
        pump()
    }

    private func job(_ key: FrameKey, _ source: Source, _ item: PlanItem) -> Job {
        Job(key: key, source: source, target: target, visible: item.visible, background: item.background)
    }

    // MARK: Running

    private var gpuSlots: Int {
        let info = ProcessInfo.processInfo
        let constrained = info.isLowPowerModeEnabled
            || info.thermalState == .serious || info.thermalState == .critical
        return constrained ? 2 : 3
    }

    private func pump() {
        while fastRunning < Self.fastSlots, !fastQueue.isEmpty {
            let job = fastQueue.removeFirst()
            fastRunning += 1
            start(job)
        }
        // One GPU slot is held back for the photo on screen. While that photo renders,
        // speculative work slows down: concurrent renders share the GPU and delay it.
        let slots = gpuSlots
        // A 100 % render holds about 2.5 GB of Core Image surfaces: one at a time. It waits
        // without blocking the screen renders queued behind it.
        while let at = gpuQueue.firstIndex(where: { $0.key.tier != .full || fullRunning == 0 }) {
            let next = gpuQueue[at]
            let limit = next.visible ? slots : (gpuVisibleRunning > 0 ? slots - 2 : slots - 1)
            guard gpuRunning < limit else { break }
            if next.background && encodeQueue.count >= Self.backgroundEncodeBacklog { break }
            gpuQueue.remove(at: at)
            gpuRunning += 1
            if next.visible { gpuVisibleRunning += 1 }
            if next.key.tier == .full { fullRunning += 1 }
            start(next)
        }
    }

    private func start(_ job: Job) {
        inFlight.insert(job.key)
        let qos: DispatchQoS.QoSClass = job.visible ? .userInteractive : (job.background ? .utility : .userInitiated)
        DispatchQueue.global(qos: qos).async { [weak self] in
            let outcome = Self.run(job)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finish(job, outcome) }
            }
        }
    }

    /// Checks the revision before and after decoding: pixels from a file replaced in
    /// between are rejected rather than cached under the old key.
    private nonisolated static func run(_ job: Job) -> Outcome {
        let photo = job.key.photo
        guard PhotoKey.read(path: photo.path) == photo else { return .stale }
        let frame: Frame?
        switch job.source {
        case .preview:
            frame = Decoders.preview(photo)
        case .disk(let url, let nativeSize):
            guard let read = DiskCodec.read(url, key: job.key, nativeSize: nativeSize) else { return .diskMiss }
            frame = read
        case .render:
            frame = Decoders.render(photo, tier: job.key.tier, target: job.target)
        }
        guard PhotoKey.read(path: photo.path) == photo else { return .stale }
        return frame.map(Outcome.frame) ?? .failed
    }

    private func finish(_ job: Job, _ outcome: Outcome) {
        inFlight.remove(job.key)
        if case .render = job.source {
            gpuRunning -= 1
            if job.visible { gpuVisibleRunning -= 1 }
            if job.key.tier == .full { fullRunning -= 1 }
        } else {
            fastRunning -= 1
        }

        switch outcome {
        case .frame(let frame):
            accept(frame, job)
        case .stale:
            onStale(job.key.photo)
        case .failed:
            failed.insert(job.key)
            onFailed(job.key)
        case .diskMiss:
            disk.invalidate(job.key.photo)
            onNeedsReplan()
        }
        pump()
    }

    private func accept(_ frame: Frame, _ job: Job) {
        // Rendered for a screen that is no longer the target.
        if job.key.tier != .full && job.target != target { return }
        if case .render = job.source, job.key.tier == .screen { enqueueEncode(frame) }
        if job.background { return }
        if memoryLevel != .normal && !cache.protected.contains(job.key) { return }
        cache.insert(frame, visible: job.visible ? job.key : nil)
        onFrame(frame)
    }

    // MARK: Disk writes

    private func enqueueEncode(_ frame: Frame) {
        guard memoryLevel != .critical, encodeQueue.count < Self.encodeBacklog else { return }
        let name = disk.entryName(frame.key.photo, nativeSize: frame.nativeSize)
        encodeQueue.append(EncodeJob(frame: frame, entry: .init(fileName: name, nativeSize: frame.nativeSize), generation: disk.generation))
        pumpEncode()
    }

    private func pumpEncode() {
        guard !encodeRunning, !encodeQueue.isEmpty else { return }
        let job = encodeQueue.removeFirst()
        encodeRunning = true
        let url = disk.url(job.entry)
        let frame = job.frame
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let written = DiskCodec.write(frame, to: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.encodeRunning = false
                    if written {
                        self.disk.noteWritten(photo: frame.key.photo, entry: job.entry, generation: job.generation)
                    }
                    self.pumpEncode()
                    self.pump()
                }
            }
        }
    }

    // MARK: Memory pressure

    private func startMemoryMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated {
                let level: MemoryLevel = event.contains(.critical) ? .critical : (event.contains(.warning) ? .warning : .normal)
                self?.setMemoryLevel(level)
            }
        }
        source.resume()
        memorySource = source
    }

    func setMemoryLevel(_ level: MemoryLevel) {
        memoryLevel = level
        switch level {
        case .normal:
            break
        case .warning:
            cache.retainOnly(.full, keep: cache.protected.filter { $0.tier == .full })
        case .critical:
            encodeQueue.removeAll()
        }
        onNeedsReplan()
        // Replanning shrank the protected set: what it no longer covers can now go.
        if level != .normal {
            cache.retainOnly(.screen, keep: cache.protected)
            cache.retainOnly(.preview, keep: cache.protected)
            cache.retainOnly(.full, keep: cache.protected)
            // A preview is only planned when its sharper frame is absent, which is only true now.
            onNeedsReplan()
            onEvicted()
        }
    }

    // MARK: System state

    static var canWorkInBackground: Bool {
        let info = ProcessInfo.processInfo
        guard !info.isLowPowerModeEnabled, info.thermalState == .nominal else { return false }
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        else { return true }
        return type == kIOPMACPowerKey
    }
}
