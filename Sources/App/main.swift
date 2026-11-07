import AppKit

if let at = CommandLine.arguments.firstIndex(of: "--verify-previews"), at + 1 < CommandLine.arguments.count {
    Benchmark.verifyPreviews(folder: URL(fileURLWithPath: CommandLine.arguments[at + 1]))
    exit(0)
}
let appDelegate = AppDelegate()
let benchmark = Benchmark.fromArguments()
NSApplication.shared.delegate = appDelegate
if let benchmark {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { benchmark.start(viewer: appDelegate.viewer) }
    }
}
NSApplication.shared.run()
