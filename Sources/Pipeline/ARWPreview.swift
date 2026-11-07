import CoreGraphics
import Foundation

/// Cuts the embedded JPEG straight out of a Sony ARW. Going through ImageIO instead loads its
/// RAW plugin: measured on A7C files, 225 ms against 55 ms for the first preview of a launch,
/// then 30 ms against 15 ms each. Anything unexpected returns nil and falls back to ImageIO.
struct ARWPreview {
    let jpeg: Data
    /// EXIF orientation: only 1, 3, 6 and 8 are returned, the others fall back.
    let orientation: Int
    /// Size of the raw image, unoriented, when the header gives it.
    let rawSize: CGSize?

    private static let headerSize = 64 * 1024

    static func read(_ url: URL) -> ARWPreview? {
        guard url.pathExtension.lowercased() == "arw",
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerSize),
              let layout = parse(header: head),
              (try? handle.seek(toOffset: UInt64(layout.offset))) != nil,
              let jpeg = try? handle.read(upToCount: layout.length),
              jpeg.count == layout.length,
              jpeg.starts(with: [0xFF, 0xD8])
        else { return nil }
        return ARWPreview(jpeg: jpeg, orientation: layout.orientation, rawSize: layout.rawSize)
    }

    struct Layout: Equatable {
        let offset: Int
        let length: Int
        let orientation: Int
        let rawSize: CGSize?
    }

    /// Reads IFD0 of a little-endian TIFF. Every read is bounds-checked: a damaged file ends
    /// in nil rather than a crash.
    static func parse(header head: Data) -> Layout? {
        let bytes = [UInt8](head)
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= bytes.count else { return nil }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        func u32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        guard bytes.count > 8, bytes[0] == 0x49, bytes[1] == 0x49, u16(2) == 42,
              let ifd = u32(4), let entries = u16(ifd)
        else { return nil }

        var offset = 0, length = 0, orientation = 1, subIFD = 0
        for i in 0..<entries {
            let entry = ifd + 2 + i * 12
            guard let tag = u16(entry) else { return nil }
            switch tag {
            case 0x0112: orientation = u16(entry + 8) ?? 0
            case 0x014A: subIFD = u32(entry + 8) ?? 0
            case 0x0201: offset = u32(entry + 8) ?? 0
            case 0x0202: length = u32(entry + 8) ?? 0
            default: break
            }
        }
        guard offset > 0, length > 0, [1, 3, 6, 8].contains(orientation) else { return nil }

        var rawSize: CGSize?
        if subIFD > 0, let count = u16(subIFD) {
            var width = 0, height = 0
            for i in 0..<count {
                let entry = subIFD + 2 + i * 12
                guard let tag = u16(entry) else { break }
                if tag == 0x0100 { width = fieldValue(u16(entry + 2), at: entry + 8, u16, u32) }
                if tag == 0x0101 { height = fieldValue(u16(entry + 2), at: entry + 8, u16, u32) }
            }
            if width > 0, height > 0 { rawSize = CGSize(width: width, height: height) }
        }
        return Layout(offset: offset, length: length, orientation: orientation, rawSize: rawSize)
    }

    /// TIFF type 3 is 16 bits and type 4 is 32 bits.
    private static func fieldValue(_ type: Int?, at: Int, _ u16: (Int) -> Int?, _ u32: (Int) -> Int?) -> Int {
        (type == 3 ? u16(at) : u32(at)) ?? 0
    }

    /// Draws `image` upright into a new surface.
    static func materialize(_ image: CGImage, orientation: Int) -> IOSurfaceBox? {
        let (w, h) = (image.width, image.height)
        let swapped = orientation == 6 || orientation == 8
        let (outW, outH) = swapped ? (h, w) : (w, h)
        guard let surface = PixelFormat.makeSurface(width: outW, height: outH) else { return nil }
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let context = CGContext(
            data: surface.baseAddress, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: surface.bytesPerRow,
            space: PixelFormat.displayP3, bitmapInfo: PixelFormat.bitmapInfo
        ) else { return nil }
        context.interpolationQuality = .none
        switch orientation {
        case 3: context.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: CGFloat(w), ty: CGFloat(h)))
        case 6: context.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(w)))
        case 8: context.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(h), ty: 0))
        default: break
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return IOSurfaceBox(surface: surface)
    }
}
