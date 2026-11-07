import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Screen-tier frames as JPEG on disk: reading one takes 25 ms against 270 ms for a RAW render.
///
/// The main thread only touches an in-memory index, so a lookup costs no I/O. A file named
/// `<hash>_<nativeWidth>x<nativeHeight>.jpg` carries the native size without having to read it.
@MainActor
final class DiskCache {
    struct Entry: Sendable {
        let fileName: String
        let nativeSize: CGSize
    }

    /// Bump when the rendering parameters change.
    private static let renderVersion = 1
    private static let systemVersion = ProcessInfo.processInfo.operatingSystemVersionString

    let directory: URL
    private(set) var budget: Int
    private(set) var generation = 0
    private var index: [String: Entry] = [:]
    private var hashes: [PhotoKey: String] = [:]
    private var target = CGSize.zero
    private var writesSinceTrim = 0
    private let queue = DispatchQueue(label: "betterview.diskcache", qos: .utility)

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("BetterView", isDirectory: true)
    }

    init(directory: URL, budget: Int) {
        self.directory = directory
        self.budget = budget
    }

    /// Loads the index off the main thread. Until then every lookup is a miss, which only
    /// costs a render.
    func load() {
        let directory = directory
        queue.async { [weak self] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let entries = names.compactMap(Self.parse)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for (hash, entry) in entries where self.index[hash] == nil { self.index[hash] = entry }
                    self.trim()
                }
            }
        }
    }

    nonisolated private static func parse(_ name: String) -> (String, Entry)? {
        guard name.hasSuffix(".jpg") else { return nil }
        let parts = name.dropLast(4).split(separator: "_")
        guard parts.count == 2 else { return nil }
        let size = parts[1].split(separator: "x")
        guard size.count == 2, let width = Int(size[0]), let height = Int(size[1]) else { return nil }
        return (String(parts[0]), Entry(fileName: name, nativeSize: CGSize(width: width, height: height)))
    }

    func setTarget(_ newTarget: CGSize) {
        guard newTarget != target else { return }
        target = newTarget
        hashes.removeAll()
    }

    func setBudget(_ bytes: Int) {
        budget = bytes
        trim()
    }

    func hash(_ photo: PhotoKey) -> String {
        if let known = hashes[photo] { return known }
        let identity = "\(photo.path)|\(photo.device)|\(photo.inode)|\(photo.size)|\(photo.mtimeSeconds).\(photo.mtimeNanoseconds)|\(Self.renderVersion)|\(Self.systemVersion)|\(Int(target.width))x\(Int(target.height))"
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(16)
        let value = digest.map { String(format: "%02x", $0) }.joined()
        hashes[photo] = value
        return value
    }

    func entry(_ photo: PhotoKey) -> Entry? { index[hash(photo)] }
    func contains(_ photo: PhotoKey) -> Bool { index[hash(photo)] != nil }
    func url(_ entry: Entry) -> URL { directory.appendingPathComponent(entry.fileName) }
    var count: Int { index.count }

    /// Drops an index entry, typically after a failed read, and removes the file.
    func invalidate(_ photo: PhotoKey) {
        let key = hash(photo)
        guard let entry = index.removeValue(forKey: key) else { return }
        let url = url(entry)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    func clear() {
        generation += 1
        index.removeAll()
        let directory = directory
        queue.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
        }
    }

    /// Registers a finished write, unless the cache was cleared while it ran: the file is
    /// then deleted so a clear really leaves nothing behind.
    func noteWritten(photo: PhotoKey, entry: Entry, generation written: Int) {
        guard written == generation else {
            let url = url(entry)
            queue.async { try? FileManager.default.removeItem(at: url) }
            return
        }
        index[hash(photo)] = entry
        writesSinceTrim += 1
        if writesSinceTrim >= 32 { trim() }
    }

    func entryName(_ photo: PhotoKey, nativeSize: CGSize) -> String {
        "\(hash(photo))_\(Int(nativeSize.width))x\(Int(nativeSize.height)).jpg"
    }

    /// Evicts the least recently used files, off the main thread.
    func trim() {
        writesSinceTrim = 0
        let directory = directory
        let budget = budget
        queue.async { [weak self] in
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
            var dated: [(url: URL, date: Date, size: Int)] = files.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }
            var total = dated.reduce(0) { $0 + $1.size }
            guard total > budget else { return }
            dated.sort { $0.date < $1.date }
            var removed: [String] = []
            for file in dated where total > budget {
                try? FileManager.default.removeItem(at: file.url)
                total -= file.size
                if let parsed = Self.parse(file.url.lastPathComponent) { removed.append(parsed.0) }
            }
            let names = removed
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for name in names { self.index[name] = nil }
                }
            }
        }
    }
}

/// Off-main JPEG encoding and decoding of frames.
enum DiskCodec {
    /// Atomic: a crash can never leave a truncated file under a valid name.
    static func write(_ frame: Frame, to url: URL) -> Bool {
        autoreleasepool {
            let surface = frame.surface
            surface.lock(options: .readOnly, seed: nil)
            let data = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * surface.height)
            let (width, height, bytesPerRow) = (surface.width, surface.height, surface.bytesPerRow)
            surface.unlock(options: .readOnly, seed: nil)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(
                      width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                      space: PixelFormat.displayP3, bitmapInfo: CGBitmapInfo(rawValue: PixelFormat.bitmapInfo),
                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { return false }
            let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
            guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                try? FileManager.default.removeItem(at: temp)
                return false
            }
            if rename(temp.path, url.path) != 0 {
                try? FileManager.default.removeItem(at: temp)
                return false
            }
            return true
        }
    }

    static func read(_ url: URL, key: FrameKey, nativeSize: CGSize) -> Frame? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let surface = PixelFormat.materialize(image)
            else { return nil }
            // Marks the file as recently used for eviction.
            utimes(url.path, nil)
            return Frame(key: key, surface: surface, nativeSize: nativeSize)
        }
    }
}
