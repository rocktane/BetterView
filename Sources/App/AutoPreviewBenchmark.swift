import Foundation
import Darwin

/// Read-only benchmark of the same screen render used by the Auto button.
enum AutoPreviewBenchmark {
    static func run(folder: URL, enhanced: Bool, side: Int) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "arw" }.sorted { $0.path < $1.path }.prefix(5)
        print("mode=\(enhanced ? "auto" : "original") target=\(side) files=\(files.count) rssStartMB=\(rssMB())")
        var durations: [Double] = []
        for round in 0..<3 {
            for file in files {
                autoreleasepool {
                    guard let photo = PhotoKey.read(path: file.path) else { return }
                    let start = ProcessInfo.processInfo.systemUptime
                    guard let frame = Decoders.render(photo, tier: .screen,
                        target: CGSize(width: side, height: side), autoEnhance: enhanced) else {
                        print("FAILED \(file.lastPathComponent)"); return
                    }
                    let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    durations.append(ms)
                    print(String(format: "round=%d file=%@ ms=%.1f surfaceMB=%.1f rssMB=%.1f size=%dx%d", round,
                        file.lastPathComponent, ms, Double(frame.byteCost) / 1e6, rssMB(), frame.surface.width, frame.surface.height))
                }
            }
        }
        let warm = durations.dropFirst().sorted()
        if !warm.isEmpty {
            print(String(format: "firstMS=%.1f warmMedianMS=%.1f warmP95MS=%.1f", durations[0], warm[warm.count / 2], warm[min(warm.count - 1, Int(Double(warm.count) * 0.95))]))
        }
        Thread.sleep(forTimeInterval: 2)
        print("rssAfterIdleMB=\(rssMB())")
    }

    private static func rssMB() -> Double {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, $0, size)
        }
        return result == size ? Double(info.pti_resident_size) / 1e6 : -1
    }
}
