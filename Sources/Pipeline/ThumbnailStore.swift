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
        init(_ image: CGImage?) { self.image = image }
    }

    /// About 35 MB, at 90 KB each.
    private static let capacity = 400
    private static let slots = 2

    private var known: [PhotoKey: Thumbnail] = [:]
    private var wanted: [PhotoKey] = []
    private var running: Set<PhotoKey> = []
    private let queue = DispatchQueue(label: "betterview.thumbnails", qos: .utility, attributes: .concurrent)
    var onLoaded: (PhotoKey) -> Void = { _ in }
    /// The file is no longer this revision: the list needs a scan.
    var onStale: (PhotoKey) -> Void = { _ in }

    /// nil while it is loading, and for a photo that has none.
    func image(for photo: PhotoKey) -> CGImage? { known[photo]?.image }

    /// Replaces what is waiting, so holding an arrow key never builds a backlog.
    func request(_ photos: [PhotoKey]) {
        wanted = photos.filter { known[$0] == nil && !running.contains($0) }
        pump()
    }

    private func pump() {
        while running.count < Self.slots, !wanted.isEmpty {
            let photo = wanted.removeFirst()
            running.insert(photo)
            queue.async { [weak self] in
                // Checked before and after, as for frames: a file replaced in between must not
                // lend its pixels to the old revision.
                let current = PhotoKey.read(path: photo.path) == photo
                let image = current ? Decoders.thumbnail(photo) : nil
                let thumbnail = current && PhotoKey.read(path: photo.path) == photo ? Thumbnail(image) : nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.running.remove(photo)
                        guard let thumbnail else {
                            self.onStale(photo)
                            self.pump()
                            return
                        }
                        if self.known.count >= Self.capacity { self.known.removeAll() }
                        self.known[photo] = thumbnail
                        self.onLoaded(photo)
                        self.pump()
                    }
                }
            }
        }
    }
}

extension Decoders {
    private static let thumbnailPixels = 200

    /// Upright, decoded, and small. Sony files go through the JPEG cut out of the file, so
    /// ImageIO's RAW plugin stays unloaded here too.
    static func thumbnail(_ photo: PhotoKey) -> CGImage? {
        autoreleasepool { () -> CGImage? in
            if let parsed = ARWPreview.read(photo.url)?.preview,
               let source = CGImageSourceCreateWithData(parsed.jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                   kCGImageSourceCreateThumbnailFromImageAlways: true,
                   kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
               ] as CFDictionary) {
                return upright(image, orientation: parsed.orientation)
            }
            guard let source = CGImageSourceCreateWithURL(photo.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
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
