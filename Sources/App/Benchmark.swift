import AppKit
import CoreImage

/// `BetterView --bench <folder> [--limit n]`: replays usage on real files in the real app and
/// prints the numbers from docs/ARCHITECTURE.md section 7.
/// Never touches the folder: the deletion phase works on clones in a temp folder, with a fake
/// Trash, and the disk cache lives in a temp folder too.
@MainActor
final class Benchmark {
    private let folder: URL
    private var viewer: ViewerController!
    private let work = Benchmark.workDirectory
    private let launchOnly = CommandLine.arguments.contains("--launch-only")

    private var firstPixel: Double?
    private var arrivals: [Tier?] = []

    private static let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("BetterViewBench-\(UUID().uuidString)")

    /// The benchmark must neither read nor write the user's real cache.
    static var diskDirectory: URL? {
        CommandLine.arguments.contains("--bench") ? workDirectory.appendingPathComponent("cache") : nil
    }

    private func finish() -> Never {
        // exit() skips defer blocks: this must stay explicit, the clones are real photos.
        try? FileManager.default.removeItem(at: work)
        exit(0)
    }

    /// Compares the hand-written ARW path with ImageIO, pixel by pixel, on real files.
    nonisolated static func verifyPreviews(folder: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".arw") }.sorted()
        var orientations: [Int: Int] = [:]
        var worstMean = 0.0, worstMax = 0, compared = 0, failures = 0
        for name in names {
            let path = folder.appendingPathComponent(name).path
            guard let key = PhotoKey.read(path: path),
                  let parsed = ARWPreview.read(key.url)?.preview,
                  let direct = Decoders.directPreview(key),
                  let reference = Decoders.imageIOPreview(key),
                  direct.surface.width == reference.surface.width,
                  direct.surface.height == reference.surface.height
            else {
                failures += 1
                print("MISMATCH \(name)")
                continue
            }
            orientations[parsed.orientation, default: 0] += 1
            direct.surface.lock(options: .readOnly, seed: nil)
            reference.surface.lock(options: .readOnly, seed: nil)
            let a = direct.surface.baseAddress.assumingMemoryBound(to: UInt8.self)
            let b = reference.surface.baseAddress.assumingMemoryBound(to: UInt8.self)
            var sum = 0, maximum = 0, samples = 0
            for y in stride(from: 0, to: direct.surface.height, by: 3) {
                for x in stride(from: 0, to: direct.surface.width * 4, by: 12) {
                    let at = y * direct.surface.bytesPerRow + x
                    for channel in 0..<3 {
                        let difference = abs(Int(a[at + channel]) - Int(b[at + channel]))
                        sum += difference
                        maximum = max(maximum, difference)
                        samples += 1
                    }
                }
            }
            direct.surface.unlock(options: .readOnly, seed: nil)
            reference.surface.unlock(options: .readOnly, seed: nil)
            worstMean = max(worstMean, Double(sum) / Double(samples))
            worstMax = max(worstMax, maximum)
            compared += 1
        }
        print(String(format: "verified %d files, failures %d, orientations %@, worst mean diff %.2f, worst pixel diff %d",
                     compared, failures, String(describing: orientations.sorted { $0.key < $1.key }), worstMean, worstMax))
    }

    /// Prints the AF position read by the app for each ARW, raw then upright, and checks it
    /// against the oriented extent of CIRAWFilter, which is what the viewer shows. Only reads.
    /// Lines start with "AF" and match `exiftool -T -FocusLocation` for comparison.
    nonisolated static func verifyFocus(folder: URL) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".arw") }.sorted()
        var points = 0, centres = 0, manual = 0, missing = 0, misaligned = 0
        for name in names {
            let url = folder.appendingPathComponent(name)
            let head = (try? FileHandle(forReadingFrom: url)).flatMap { handle in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 64 * 1024)
            }
            guard let head, let record = FocusRecord.parse(header: head) else {
                missing += 1
                print("AF\t\(name)\tnone")
                continue
            }
            var line = "AF\t\(name)\t\(record.width) \(record.height) \(record.x) \(record.y)\torientation \(record.orientation)\tmode \(record.focusMode.map(String.init) ?? "-")"
            switch record.focus {
            case .point(let point):
                points += 1
                if point.isCentre { centres += 1 }
                let extent = autoreleasepool { CIRAWFilter(imageURL: url)?.outputImage?.extent.size }
                let n = point.normalized
                line += String(format: "\tupright %d %d %d %d (%.4f, %.4f)", point.width, point.height, point.x, point.y, n.x, n.y)
                if let extent {
                    line += String(format: "\textent %.0f×%.0f", extent.width, extent.height)
                    // Same proportions, so the normalised position lands on the same pixel.
                    let aligned = abs(extent.width / extent.height - Double(point.width) / Double(point.height)) < 0.002
                    if !aligned {
                        misaligned += 1
                        line += "\tMISALIGNED"
                    }
                }
            case .manual: manual += 1
            case .absent: missing += 1
            }
            print(line)
        }
        print("verified \(names.count) files: \(points) AF positions (\(centres) at the exact centre), \(manual) manual, \(missing) without, \(misaligned) misaligned with the render")
    }

    static func fromArguments() -> Benchmark? {
        let args = CommandLine.arguments
        guard let at = args.firstIndex(of: "--bench"), at + 1 < args.count else { return nil }
        return Benchmark(folder: URL(fileURLWithPath: args[at + 1]))
    }

    private init(folder: URL) { self.folder = folder }

    private static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
    private static func ms(since start: UInt64) -> Double { Double(now() - start) / 1e6 }

    private static func processAge() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_starttime
        var nowTime = timeval()
        gettimeofday(&nowTime, nil)
        return Double(nowTime.tv_sec - start.tv_sec) * 1000 + Double(nowTime.tv_usec - start.tv_usec) / 1000
    }

    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1e6 : -1
    }

    private func dumpMemory() {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
        tool.arguments = ["--summary", String(getpid())]
        let pipe = Pipe()
        tool.standardOutput = pipe
        tool.standardError = Pipe()
        guard (try? tool.run()) != nil else { return }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        tool.waitUntilExit()
        let wanted = ["REGION TYPE", "IOSurface", "IOAccelerator", "MALLOC_LARGE", "MALLOC_SMALL", "VM_ALLOCATE", "mapped file", "Physical footprint"]
        for line in output.split(separator: "\n") where wanted.contains(where: { line.hasPrefix($0) }) { print(line) }
    }

    private func report(_ name: String, _ values: [Double]) {
        guard !values.isEmpty else {
            print("\(name): no samples")
            return
        }
        let sorted = values.sorted()
        func at(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        print(String(format: "%@: n=%d p50 %.1f p95 %.1f p99 %.1f max %.1f ms", name, sorted.count, at(0.5), at(0.95), at(0.99), sorted.last!))
    }

    private func reportTiers(_ name: String) {
        let total = max(arrivals.count, 1)
        func share(_ test: (Tier?) -> Bool) -> Double { 100 * Double(arrivals.filter(test).count) / Double(total) }
        print(String(format: "%@: n=%d full-or-screen %.1f%% preview %.1f%% blank %.1f%%", name, arrivals.count,
                     share { $0 == .screen || $0 == .full }, share { $0 == .preview }, share { $0 == nil }))
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func start(viewer: ViewerController) {
        self.viewer = viewer
        print(String(format: "run loop running at %.0f ms", Self.processAge()))
        Task { await run() }
    }

    private func navigate(_ delta: Int, repeating: Bool, samples: inout [Double]) {
        let start = Self.now()
        viewer.step(delta, repeating: repeating)
        samples.append(Self.ms(since: start))
        arrivals.append(viewer.shownTier)
    }

    /// Waits until the current photo shows `tier`, or the timeout. Milliseconds, or nil.
    private func waitForTier(_ tier: Tier, timeout: Double = 5) async -> Double? {
        let start = Self.now()
        while Self.ms(since: start) < timeout * 1000 {
            if viewer.shownTier == tier { return Self.ms(since: start) }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return nil
    }

    private func run() async {
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // Launch to the first pixels of the requested file.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path))?
            .filter { RawFormat.extensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted() ?? []
        guard let firstName = names.first else {
            print("no RAW files in \(folder.path)")
            exit(1)
        }
        print("photos: \(names.count)")
        viewer.onDisplayed = { [weak self] _, tier in
            guard let self, tier != nil, self.firstPixel == nil else { return }
            self.firstPixel = Self.processAge()
        }
        viewer.open([folder.appendingPathComponent(firstName)])
        while firstPixel == nil { await sleep(0.002) }
        viewer.onDisplayed = nil
        print(String(format: "launch to first pixel (process start, empty disk cache): %.0f ms", firstPixel!))
        if launchOnly {
            print(String(format: "list %d", viewer.session.list.count))
            finish()
        }
        if let render = await waitForTier(.screen) { print(String(format: "then screen tier: %.0f ms later", render)) }
        while viewer.session.list.count <= 1 { await sleep(0.01) }
        print("list ready: \(viewer.session.list.count)")

        // Culling at one photo per second, empty disk cache.
        await sleep(2)
        var samples: [Double] = []
        arrivals = []
        for _ in 0..<30 {
            navigate(1, repeating: false, samples: &samples)
            await sleep(1)
        }
        report("culling 1 photo/s, navigate commit", samples)
        reportTiers("culling 1 photo/s, arrival tier")
        print(String(format: "disk entries: %d, footprint %.0f MB, cached %.0f MB", viewer.pipeline.disk.count, Self.footprintMB(), Double(viewer.pipeline.cache.totalBytes) / 1e6))

        // Faster culling: 3 photos/s, above the renderer's sustained rate per photo.
        samples = []
        arrivals = []
        for _ in 0..<30 {
            navigate(1, repeating: false, samples: &samples)
            await sleep(0.333)
        }
        report("culling 3 photos/s, navigate commit", samples)
        reportTiers("culling 3 photos/s, arrival tier")

        // Holding a key at 30 Hz.
        await sleep(0.5)
        samples = []
        arrivals = []
        for i in 0..<120 {
            if i == 9 { arrivals = [] } // Ignore the first 300 ms.
            navigate(1, repeating: true, samples: &samples)
            await sleep(1.0 / 30)
        }
        viewer.step(0, repeating: false)
        report("held key 30 Hz, navigate commit", samples)
        reportTiers("held key 30 Hz, arrival tier (after 300 ms)")
        print(String(format: "footprint %.0f MB", Self.footprintMB()))

        // Jumping far away: the visible photo renders, competing with speculative work.
        await sleep(0.5)
        viewer.pipeline.disk.clear()
        samples = []
        var count = viewer.session.list.count
        var position = viewer.session.list.index ?? 0
        for _ in 0..<20 {
            position = (position + 53) % count
            let distance = position - (viewer.session.list.index ?? 0)
            viewer.pipeline.cache.removeAll(.screen)
            viewer.step(distance)
            if let elapsed = await waitForTier(.screen) { samples.append(elapsed) }
            await sleep(0.4)
        }
        report("jump, uncached, until screen tier", samples)

        // Coming back with memory cleared: the disk cache answers.
        viewer.pipeline.cache.removeAll(.screen)
        viewer.pipeline.cache.removeAll(.preview)
        samples = []
        let visited = viewer.session.list.photos.enumerated().filter { viewer.pipeline.disk.contains($0.element) }.map(\.offset)
        for index in visited.shuffled().prefix(15) {
            viewer.pipeline.cache.removeAll(.screen)
            viewer.step(index - (viewer.session.list.index ?? 0))
            if viewer.shownTier == .screen { continue }
            if let elapsed = await waitForTier(.screen) { samples.append(elapsed) }
            await sleep(0.3)
        }
        report("disk hit, until screen tier", samples)

        // Zoom: time from the key to full resolution when it was not prepared.
        samples = []
        for _ in 0..<6 {
            viewer.step(7)
            _ = await waitForTier(.screen)
            let start = Self.now()
            viewer.toggleZoom()
            if await waitForTier(.full) != nil { samples.append(Self.ms(since: start)) }
            viewer.toggleZoom()
            await sleep(0.2)
        }
        report("zoom immediately, until full tier", samples)
        samples = []
        for _ in 0..<6 {
            viewer.step(7)
            _ = await waitForTier(.screen)
            await sleep(1.2)
            let start = Self.now()
            viewer.toggleZoom()
            if await waitForTier(.full) != nil { samples.append(Self.ms(since: start)) }
            viewer.toggleZoom()
            await sleep(0.2)
        }
        report("zoom after 1.2 s on the photo, until full tier", samples)

        // Deleting, on clones and with a fake Trash.
        let clones = work.appendingPathComponent("photos")
        let fakeTrash = work.appendingPathComponent("trash")
        try? FileManager.default.createDirectory(at: clones, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        for name in names.prefix(40) {
            try? FileManager.default.copyItem(at: folder.appendingPathComponent(name), to: clones.appendingPathComponent(name))
        }
        let original = viewer.session.fileOps
        viewer.session.fileOps = FileOps(
            trash: { url in
                let destination = fakeTrash.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            },
            restore: original.restore,
            deletePermanently: { _ in throw CocoaError(.featureUnsupported) }
        )
        viewer.session.open([clones])
        while viewer.session.list.count < min(names.count, 40) { await sleep(0.01) }
        _ = await waitForTier(.screen)
        await sleep(2)
        samples = []
        arrivals = []
        for _ in 0..<15 {
            let start = Self.now()
            viewer.deleteCurrent()
            samples.append(Self.ms(since: start))
            arrivals.append(viewer.shownTier)
            await sleep(0.5)
        }
        report("delete to next photo shown", samples)
        reportTiers("delete, tier of next photo")
        let start = Self.now()
        viewer.undo()
        while viewer.session.hasPendingIO { await sleep(0.001) }
        print(String(format: "undo: %.1f ms, list %d", Self.ms(since: start), viewer.session.list.count))
        print(String(format: "final footprint %.0f MB, cached %.0f MB", Self.footprintMB(), Double(viewer.pipeline.cache.totalBytes) / 1e6))
        print("memory level \(viewer.pipeline.memoryLevel), thermal \(ProcessInfo.processInfo.thermalState.rawValue)")
        count = 0
        await sleep(3)
        print(String(format: "after 3 s idle: footprint %.0f MB, cached %.0f MB", Self.footprintMB(), Double(viewer.pipeline.cache.totalBytes) / 1e6))
        dumpMemory()
        finish()
    }
}
