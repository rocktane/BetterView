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

    /// What one read of the first 64 KiB gives: the preview, when it can be cut out, and the
    /// AF position, which costs no further read.
    struct Header {
        let preview: ARWPreview?
        let focus: CameraFocus
    }

    /// nil when the file is not an ARW or cannot be opened. With `withPreview` false, only
    /// the first 64 KiB are read.
    static func read(_ url: URL, withPreview: Bool = true) -> Header? {
        guard url.pathExtension.lowercased() == "arw",
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headerSize) else { return nil }
        let focus = FocusRecord.parse(header: head)?.focus ?? .absent
        guard withPreview,
              let layout = parse(header: head),
              (try? handle.seek(toOffset: UInt64(layout.offset))) != nil,
              let jpeg = try? handle.read(upToCount: layout.length),
              jpeg.count == layout.length,
              jpeg.starts(with: [0xFF, 0xD8])
        else { return Header(preview: nil, focus: focus) }
        return Header(preview: ARWPreview(jpeg: jpeg, orientation: layout.orientation, rawSize: layout.rawSize), focus: focus)
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

/// Sony's record of the AF position, exactly as stored, before any interpretation.
///
/// Path: IFD0 → EXIF IFD (0x8769) → MakerNote (0x927C) → FocusLocation (0x2027, four 16-bit
/// values: width, height, x, y in sensor coordinates) and FocusMode (0x201B). On the A7C the
/// MakerNote has no header and its offsets count from the start of the file, like the rest
/// of the TIFF; older Sony bodies start it with "SONY DSC " or "SONY CAM " and 3 zero bytes,
/// same offsets. Both are clear text: the enciphered Sony blocks (0x2010, 0x9050, 0x94xx) are
/// not involved. Anything that does not fit in the bytes given returns nil: no extra read.
struct FocusRecord: Equatable {
    let width: Int
    let height: Int
    let x: Int
    let y: Int
    /// EXIF orientation from IFD0.
    let orientation: Int
    /// 0 manual, 2 AF-S, 3 AF-C, 4 AF-A, 6 DMF; nil when absent.
    let focusMode: Int?

    var focus: CameraFocus {
        if focusMode == 0 { return .manual }
        return FocusPoint(sensorWidth: width, sensorHeight: height, x: x, y: y, orientation: orientation)
            .map(CameraFocus.point) ?? .absent
    }

    private static let sonyHeaders = ["SONY DSC \0\0\0", "SONY CAM \0\0\0"].map { Array($0.utf8) }

    static func parse(header head: Data) -> FocusRecord? {
        let reader = TIFFReader(bytes: [UInt8](head))
        guard head.count > 8, reader.bytes[0] == 0x49, reader.bytes[1] == 0x49, reader.u16(2) == 42,
              let ifd0 = reader.u32(4), let root = reader.entries(at: ifd0)
        else { return nil }
        let orientation = root.first { $0.tag == 0x0112 }.flatMap(reader.scalar) ?? 1
        guard let exifOffset = root.first(where: { $0.tag == 0x8769 }).flatMap(reader.scalar),
              let exif = reader.entries(at: exifOffset),
              let note = exif.first(where: { $0.tag == 0x927C }),
              let start = reader.dataOffset(note), start + 12 <= reader.bytes.count
        else { return nil }

        let lead = Array(reader.bytes[start..<start + 12])
        let ifd: Int
        if sonyHeaders.contains(lead) {
            ifd = start + 12
        } else if lead.starts(with: Array("SONY".utf8)) || lead.starts(with: Array("PREMI".utf8)) {
            return nil // A layout whose offsets have not been checked.
        } else {
            ifd = start
        }
        guard let entries = reader.entries(at: ifd),
              let location = entries.first(where: { $0.tag == 0x2027 }),
              location.type == 3, location.count == 4,
              let at = reader.dataOffset(location),
              let width = reader.u16(at), let height = reader.u16(at + 2),
              let x = reader.u16(at + 4), let y = reader.u16(at + 6)
        else { return nil }
        let mode = entries.first { $0.tag == 0x201B }.flatMap(reader.scalar)
        return FocusRecord(width: width, height: height, x: x, y: y, orientation: orientation, focusMode: mode)
    }
}

/// Bounds-checked reads in a little-endian TIFF: a damaged file gives nil, never a crash.
struct TIFFReader {
    struct Entry {
        let tag: Int
        let type: Int
        let count: Int
        /// Where the entry starts.
        let at: Int
    }

    let bytes: [UInt8]

    func u8(_ at: Int) -> Int? {
        guard at >= 0, at < bytes.count else { return nil }
        return Int(bytes[at])
    }

    func u16(_ at: Int) -> Int? {
        guard at >= 0, at + 2 <= bytes.count else { return nil }
        return Int(bytes[at]) | Int(bytes[at + 1]) << 8
    }

    func u32(_ at: Int) -> Int? {
        guard at >= 0, at + 4 <= bytes.count else { return nil }
        return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    }

    /// The whole directory, or nil if any of it lies outside the bytes.
    func entries(at ifd: Int) -> [Entry]? {
        guard let count = u16(ifd), count > 0, count <= 1000, ifd + 2 + count * 12 <= bytes.count else { return nil }
        return (0..<count).map { i in
            let at = ifd + 2 + i * 12
            return Entry(tag: u16(at)!, type: u16(at + 2)!, count: u32(at + 4)!, at: at)
        }
    }

    private static func unitSize(_ type: Int) -> Int? {
        switch type {
        case 1, 2, 6, 7: 1
        case 3, 8: 2
        case 4, 9, 11: 4
        case 5, 10, 12: 8
        default: nil
        }
    }

    /// Where the entry's value starts: inside the entry when it fits in 4 bytes, otherwise
    /// at the offset it holds, counted from the start of the file. nil if it does not fit.
    func dataOffset(_ entry: Entry) -> Int? {
        guard let unit = Self.unitSize(entry.type) else { return nil }
        let length = unit * entry.count
        let start = length <= 4 ? entry.at + 8 : u32(entry.at + 8)
        guard let start, start >= 0, start + length <= bytes.count else { return nil }
        return start
    }

    /// The first value of a byte, 16-bit or 32-bit field.
    func scalar(_ entry: Entry) -> Int? {
        guard entry.count >= 1, let at = dataOffset(entry) else { return nil }
        switch entry.type {
        case 1, 7: return u8(at)
        case 3: return u16(at)
        case 4: return u32(at)
        default: return nil
        }
    }
}
