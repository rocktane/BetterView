import CoreGraphics
import Foundation
import ImageIO

/// Small images for the strip, made apart from the frame pipeline. Its previews do not stay
/// (a preview leaves the cache once the rendered frame exists), and keeping frames alive for
/// the strip would hold memory outside the frame budgets. Nothing here delays a photo: the
/// workers run at low priority, and a thumbnail fills in when it arrives.
@MainActor
final class ThumbnailStore {
    private final class Thumbnail: @unchecked Sendable {
        let image: CGImage?
        /// The longest side asked for: a taller strip asks again for larger ones.
        let pixels: Int
        init(_ image: CGImage?, pixels: Int) {
            self.image = image
            self.pixels = pixels
        }

        var bytes: Int { image.map { $0.bytesPerRow * $0.height } ?? 0 }
    }

    /// 40 MB: at the usual 200 px (106 KB each) about 380 thumbnails, at the largest, 440 px
    /// (516 KB), about 80, twice what the widest strip shows with its margin.
    private static let budget = 40_000_000
    private static let slots = 2

    private var known: [PhotoKey: Thumbnail] = [:]
    private var knownBytes = 0
    private var wanted: [PhotoKey] = []
    /// What the last request asked for, waiting or not: kept when room is needed.
    private var asked: Set<PhotoKey> = []
    private var running: Set<PhotoKey> = []
    /// The longest side of the thumbnails made from now on.
    var pixels = ThumbnailStore.pixels(forHeight: 66, scale: 2)
    private let queue = DispatchQueue(label: "betterview.thumbnails", qos: .utility, attributes: .concurrent)
    var onLoaded: (PhotoKey) -> Void = { _ in }
    /// The file is no longer this revision: the list needs a scan.
    var onStale: (PhotoKey) -> Void = { _ in }

    /// The longest side, in pixels, that keeps thumbnails `height` points tall sharp, for a
    /// 3:2 photo (a portrait one needs less). In steps of 80 px from 200 px, so that a strip
    /// being stretched asks again only a few times.
    nonisolated static func pixels(forHeight height: CGFloat, scale: CGFloat) -> Int {
        let needed = Int((height * scale * 1.5).rounded(.up))
        return 200 + max(0, needed - 200 + 79) / 80 * 80
    }

    /// nil while it is loading, and for a photo that has none. A thumbnail smaller than the
    /// size now asked for is still given until the larger one replaces it.
    func image(for photo: PhotoKey) -> CGImage? { known[photo]?.image }

    /// Replaces what is waiting, so holding an arrow key never builds a backlog.
    func request(_ photos: [PhotoKey]) {
        asked = Set(photos)
        wanted = photos.filter { (known[$0].map { $0.pixels < pixels } ?? true) && !running.contains($0) }
        pump()
    }

    /// What to let go to make room for `adding` bytes within `budget`: nothing while it fits,
    /// then the thumbnails no longer asked for, then, if that is not enough, all of them. The
    /// photos the strip shows keep theirs while it is stretched or moved along.
    nonisolated static func evicted<Key: Hashable>(sizes: [Key: Int], asked: Set<Key>, adding: Int, budget: Int) -> Set<Key> {
        let total = sizes.values.reduce(0, +)
        guard total + adding > budget else { return [] }
        let stale = Set(sizes.keys.filter { !asked.contains($0) })
        let left = total - stale.reduce(0) { $0 + sizes[$1, default: 0] }
        return left + adding > budget ? Set(sizes.keys) : stale
    }

    private func makeRoom(for bytes: Int) {
        guard knownBytes + bytes > Self.budget else { return }
        for photo in Self.evicted(sizes: known.mapValues(\.bytes), asked: asked, adding: bytes, budget: Self.budget) {
            if let gone = known.removeValue(forKey: photo) { knownBytes -= gone.bytes }
        }
    }

    private func pump() {
        while running.count < Self.slots, !wanted.isEmpty {
            let photo = wanted.removeFirst()
            let pixels = pixels
            running.insert(photo)
            queue.async { [weak self] in
                // Checked before and after, as for frames: a file replaced in between must not
                // lend its pixels to the old revision.
                let current = PhotoKey.read(path: photo.path) == photo
                let image = current ? Decoders.thumbnail(photo, maxPixels: pixels) : nil
                let thumbnail = current && PhotoKey.read(path: photo.path) == photo ? Thumbnail(image, pixels: pixels) : nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.running.remove(photo)
                        guard let thumbnail else {
                            self.onStale(photo)
                            self.pump()
                            return
                        }
                        if let old = self.known.removeValue(forKey: photo) { self.knownBytes -= old.bytes }
                        self.makeRoom(for: thumbnail.bytes)
                        self.known[photo] = thumbnail
                        self.knownBytes += thumbnail.bytes
                        self.onLoaded(photo)
                        self.pump()
                    }
                }
            }
        }
    }
}

extension Decoders {
    /// Upright, decoded, and small. Sony files go through the JPEG cut out of the file, so
    /// ImageIO's RAW plugin stays unloaded here too.
    static func thumbnail(_ photo: PhotoKey, maxPixels: Int) -> CGImage? {
        thumbnail(at: photo.url, maxPixels: maxPixels)
    }

    /// Same, for any file and size: the deletion history reads files in the Trash.
    static func thumbnail(at url: URL, maxPixels thumbnailPixels: Int) -> CGImage? {
        autoreleasepool { () -> CGImage? in
            if let parsed = ARWPreview.read(url)?.preview,
               let source = CGImageSourceCreateWithData(parsed.jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
               ] as CFDictionary) {
                return upright(image, orientation: parsed.orientation)
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: false,
                      kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                      kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary)
            else { return nil }
            return upright(image, orientation: 1)
        }
    }

    /// Draws into a bitmap of ours, which also forces the decoding to happen here.
    private static func upright(_ image: CGImage, orientation: Int) -> CGImage? {
        let (w, h) = (image.width, image.height)
        let swapped = orientation == 6 || orientation == 8
        guard let context = CGContext(
            data: nil, width: swapped ? h : w, height: swapped ? w : h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: PixelFormat.displayP3, bitmapInfo: PixelFormat.bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .medium
        switch orientation {
        case 3: context.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: CGFloat(w), ty: CGFloat(h)))
        case 6: context.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(w)))
        case 8: context.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0))
        default: break
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
