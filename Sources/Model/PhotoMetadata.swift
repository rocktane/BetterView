import Foundation
import ImageIO

/// The shooting information shown over the photo.
struct PhotoMetadata: Equatable, Sendable {
    var date: Date?
    var iso: Int?
    var exposure: Double?
    var fNumber: Double?
    var focalLength: Double?

    /// In the camera's wall-clock time, since EXIF carries no time zone.
    var dateText: String {
        date?.formatted(Date.FormatStyle(date: .long, time: .shortened, locale: Locale(identifier: "fr_FR"), timeZone: .gmt)) ?? ""
    }

    var settingsText: String {
        var parts: [String] = []
        if let iso { parts.append("ISO \(iso)") }
        if let exposure, exposure > 0 {
            parts.append(exposure >= 1 ? String(format: "%.1f s", exposure) : "1/\(Int((1 / exposure).rounded())) s")
        }
        if let fNumber { parts.append(String(format: "f/%.1f", fNumber)) }
        if let focalLength { parts.append(String(format: "%.0f mm", focalLength)) }
        return parts.joined(separator: "  ·  ")
    }

    /// EXIF's "2026:09:19 11:21:54", as if it were GMT.
    static func parseDate(_ text: String) -> Date? {
        let fields = text.split(whereSeparator: { $0 == ":" || $0 == " " }).compactMap { Int($0) }
        guard fields.count >= 6, fields[0] > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: fields[0], month: fields[1], day: fields[2], hour: fields[3], minute: fields[4], second: fields[5]))
    }

    /// Blocking: never call from the main thread. A file without information gets an empty value.
    static func read(_ photo: PhotoKey) -> PhotoMetadata {
        readARW(photo.url) ?? readImageIO(photo.url) ?? PhotoMetadata()
    }

    private static let headerSize = 64 * 1024

    /// Sony files, without loading ImageIO's RAW plugin: see ARWPreview for what that costs.
    static func readARW(_ url: URL) -> PhotoMetadata? {
        guard url.pathExtension.lowercased() == "arw", let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: headerSize) else { return nil }
        return parse(header: header)
    }

    static func readImageIO(_ url: URL) -> PhotoMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        else { return nil }
        return PhotoMetadata(
            date: (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap(parseDate),
            iso: (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
            exposure: exif[kCGImagePropertyExifExposureTime] as? Double,
            fNumber: exif[kCGImagePropertyExifFNumber] as? Double,
            focalLength: exif[kCGImagePropertyExifFocalLength] as? Double
        )
    }

    /// Reads the EXIF block of a little-endian TIFF. Every read is bounds-checked; without
    /// at least a date and an ISO the caller falls back to ImageIO.
    static func parse(header: Data) -> PhotoMetadata? {
        let bytes = [UInt8](header)
        func u16(_ at: Int) -> Int? {
            guard at >= 0, at + 2 <= bytes.count else { return nil }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        func u32(_ at: Int) -> Int? {
            guard at >= 0, at + 4 <= bytes.count else { return nil }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func rational(entry: Int) -> Double? {
            guard let offset = u32(entry + 8), let numerator = u32(offset), let denominator = u32(offset + 4), denominator != 0 else { return nil }
            return Double(numerator) / Double(denominator)
        }
        guard bytes.count > 8, bytes[0] == 0x49, bytes[1] == 0x49, u16(2) == 42,
              let ifd = u32(4), let entries = u16(ifd)
        else { return nil }

        var exifOffset: Int?
        for i in 0..<entries {
            let entry = ifd + 2 + i * 12
            guard let tag = u16(entry) else { return nil }
            if tag == 0x8769 { exifOffset = u32(entry + 8) }
        }
        guard let exifOffset, let count = u16(exifOffset) else { return nil }

        var result = PhotoMetadata()
        for i in 0..<count {
            let entry = exifOffset + 2 + i * 12
            guard let tag = u16(entry) else { break }
            switch tag {
            case 0x829A: result.exposure = rational(entry: entry)
            case 0x829D: result.fNumber = rational(entry: entry)
            case 0x920A: result.focalLength = rational(entry: entry)
            case 0x8827: result.iso = u16(entry + 8)
            case 0x9003:
                if let offset = u32(entry + 8), offset >= 0, offset + 19 <= bytes.count {
                    result.date = parseDate(String(decoding: bytes[offset..<offset + 19], as: UTF8.self))
                }
            default: break
            }
        }
        return result.date != nil && result.iso != nil ? result : nil
    }
}

/// Reads shooting information off the main thread, one file at a time, latest request first.
/// Nothing here waits on the display: the overlay fills in when the answer arrives.
@MainActor
final class MetadataStore {
    private static let capacity = 5000

    private var known: [PhotoKey: PhotoMetadata] = [:]
    private var wanted: [PhotoKey] = []
    private var running = false
    private let queue = DispatchQueue(label: "betterview.metadata", qos: .userInitiated)
    var onLoaded: (PhotoKey) -> Void = { _ in }

    func metadata(for photo: PhotoKey) -> PhotoMetadata? { known[photo] }

    /// Replaces what is waiting, so holding an arrow key never builds a backlog.
    func request(_ photos: [PhotoKey]) {
        wanted = photos.filter { known[$0] == nil }
        pump()
    }

    private func pump() {
        guard !running, !wanted.isEmpty else { return }
        let photo = wanted.removeFirst()
        running = true
        queue.async { [weak self] in
            let metadata = PhotoMetadata.read(photo)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.running = false
                    if self.known.count >= Self.capacity { self.known.removeAll() }
                    self.known[photo] = metadata
                    self.onLoaded(photo)
                    self.pump()
                }
            }
        }
    }
}
