import CoreImage
import Foundation
import ImageIO

/// Pure worker functions. They own no state, so they can run on any thread.
enum Decoders {
    private static let context = CIContext(options: [
        .cacheIntermediates: false,
        .workingFormat: CIFormat.RGBAh,
    ])

    // Measured on this context, keep before changing it:
    // - clearCaches() between renders takes the p95 from 355 ms to over 3 s under concurrency;
    // - memoryTarget gains nothing at 1024 MB and triples latency at 512 MB;
    // - its surface pool is outside the frame budgets (about 1 GB rendering the screen tier,
    //   2.5 GB rendering at 100 %) and falls back to almost nothing within 2 s of idle.

    /// Starts the Core Image and Metal setup ahead of the first RAW job, slightly later so it
    /// does not compete with the first preview. A RAW job arriving sooner initialises the
    /// context itself, so no image ever waits on this having run.
    static func warmUp() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { _ = context }
    }

    /// The JPEG embedded in the RAW, nil when the file has none worth showing, and the AF
    /// position the camera recorded, read from the same 64 KiB.
    static func preview(_ photo: PhotoKey) -> (frame: Frame?, focus: CameraFocus) {
        let header = ARWPreview.read(photo.url)
        let frame = header?.preview.flatMap { directPreview($0, photo) } ?? imageIOPreview(photo)
        return (frame, header?.focus ?? .absent)
    }

    /// Fast path for Sony files, which never loads ImageIO's RAW plugin.
    static func directPreview(_ photo: PhotoKey) -> Frame? {
        ARWPreview.read(photo.url)?.preview.flatMap { directPreview($0, photo) }
    }

    private static func directPreview(_ parsed: ARWPreview, _ photo: PhotoKey) -> Frame? {
        autoreleasepool { () -> Frame? in
            guard let source = CGImageSourceCreateWithData(parsed.jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  max(image.width, image.height) >= 640,
                  let box = ARWPreview.materialize(image, orientation: parsed.orientation)
            else { return nil }
            let swapped = parsed.orientation >= 5
            // The true size needs the RAW plugin: the header's size gives the right scale for
            // the moment until a rendered frame replaces this one.
            let raw = parsed.rawSize ?? CGSize(width: image.width, height: image.height)
            let native = swapped ? CGSize(width: raw.height, height: raw.width) : raw
            return Frame(key: FrameKey(photo: photo, tier: .preview), surface: box.surface, nativeSize: native)
        }
    }

    static func imageIOPreview(_ photo: PhotoKey) -> Frame? {
        autoreleasepool { () -> Frame? in
            guard let source = CGImageSourceCreateWithURL(photo.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: false,
                      kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                      kCGImageSourceThumbnailMaxPixelSize: 8192,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary),
                  max(image.width, image.height) >= 640,
                  let surface = PixelFormat.materialize(image)
            else { return nil }
            let native = nativeSize(source: source) ?? CGSize(width: image.width, height: image.height)
            return Frame(key: FrameKey(photo: photo, tier: .preview), surface: surface, nativeSize: native)
        }
    }

    private static func nativeSize(source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Renders the RAW through Core Image: fitted inside `target`, or at 100 % for `.full`.
    static func render(_ photo: PhotoKey, tier: Tier, target: CGSize) -> Frame? {
        autoreleasepool { () -> Frame? in
            guard let filter = CIRAWFilter(imageURL: photo.url), let whole = filter.outputImage else { return nil }
            let native = whole.extent.size
            guard native.width > 0, native.height > 0 else { return nil }

            var output = whole
            if tier != .full {
                let scale = min(1, target.width / native.width, target.height / native.height)
                if scale < 1 {
                    filter.scaleFactor = Float(scale)
                    guard let scaled = filter.outputImage else { return nil }
                    output = scaled
                }
            }
            let extent = output.extent.integral
            output = output.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            let bounds = CGRect(origin: .zero, size: extent.size)
            guard let surface = PixelFormat.makeSurface(width: Int(bounds.width), height: Int(bounds.height)) else { return nil }
            context.render(output, to: surface, bounds: bounds, colorSpace: PixelFormat.displayP3)
            // Taking the lock waits for the GPU to finish writing the surface.
            surface.lock(options: .readOnly, seed: nil)
            surface.unlock(options: .readOnly, seed: nil)
            return Frame(key: FrameKey(photo: photo, tier: tier), surface: surface, nativeSize: native)
        }
    }
}
