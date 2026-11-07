import CoreGraphics
import CoreVideo
import Foundation
import IOSurface

enum PixelFormat {
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    static func makeSurface(width: Int, height: Int) -> IOSurface? {
        guard let surface = IOSurface(properties: [
            .width: width,
            .height: height,
            .bytesPerElement: 4,
            .pixelFormat: Int(kCVPixelFormatType_32BGRA),
        ]) else { return nil }
        if let tag = displayP3.copyPropertyList() {
            IOSurfaceSetValue(unsafeBitCast(surface, to: IOSurfaceRef.self), kIOSurfaceColorSpace, tag)
        }
        return surface
    }

    /// Decodes an image into a new surface: every pixel is in memory when this returns.
    static func materialize(_ image: CGImage) -> IOSurface? {
        guard let surface = makeSurface(width: image.width, height: image.height) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let context = CGContext(
            data: surface.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow,
            space: displayP3, bitmapInfo: bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return surface
    }
}

struct IOSurfaceBox {
    let surface: IOSurface
}

/// An immutable, fully decoded image. An IOSurface is handed to Core Animation without a
/// copy, which avoids the first-display texture upload measured for CGImage (M0: 51 ms).
final class Frame: @unchecked Sendable {
    let key: FrameKey
    let surface: IOSurface
    /// Oriented size of the whole image at 100 %, whatever the size of this frame.
    let nativeSize: CGSize

    init(key: FrameKey, surface: IOSurface, nativeSize: CGSize) {
        self.key = key
        self.surface = surface
        self.nativeSize = nativeSize
    }

    var byteCost: Int { surface.allocationSize }
}
