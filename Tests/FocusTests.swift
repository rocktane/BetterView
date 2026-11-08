import XCTest
import CoreGraphics
@testable import BetterView

/// Small synthetic TIFF files shaped like the A7C's: IFD0 → EXIF IFD → Sony MakerNote.
final class FocusRecordTests: XCTestCase {
    private struct Field {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        let value: UInt32
    }

    private struct TIFF {
        var data = Data()
        mutating func u16(_ v: UInt16) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8)]) }
        mutating func u32(_ v: UInt32) { (0..<4).forEach { data.append(UInt8((v >> (8 * UInt32($0))) & 0xFF)) } }
        mutating func pad(to offset: Int) { data.append(Data(count: max(0, offset - data.count))) }
        mutating func ifd(_ fields: [Field], at offset: Int) {
            pad(to: offset)
            u16(UInt16(fields.count))
            for field in fields {
                u16(field.tag); u16(field.type); u32(field.count); u32(field.value)
            }
            u32(0)
        }
    }

    /// Offsets: IFD0 at 8, EXIF IFD at 100, MakerNote at 200, FocusLocation values at 400.
    private func file(
        location: [UInt16] = [6000, 4000, 2840, 1583],
        orientation: UInt16 = 6,
        focusMode: UInt8? = 2,
        makerNoteHeader: String? = nil,
        locationType: UInt16 = 3
    ) -> Data {
        var tiff = TIFF()
        tiff.data = Data([0x49, 0x49, 42, 0])
        tiff.u32(8)
        tiff.ifd([
            Field(tag: 0x0112, type: 3, count: 1, value: UInt32(orientation)),
            Field(tag: 0x8769, type: 4, count: 1, value: 100),
        ], at: 8)
        tiff.ifd([
            Field(tag: 0x829A, type: 5, count: 1, value: 0),
            Field(tag: 0x927C, type: 7, count: 300, value: 200),
        ], at: 100)
        tiff.pad(to: 200)
        var noteIFD = 200
        if let makerNoteHeader {
            tiff.data.append(contentsOf: Array(makerNoteHeader.utf8))
            noteIFD = 212
        }
        var fields = [
            Field(tag: 0x2010, type: 7, count: 8, value: 0),
            Field(tag: 0x2027, type: locationType, count: 4, value: 400),
        ]
        if let focusMode { fields.insert(Field(tag: 0x201B, type: 1, count: 1, value: UInt32(focusMode)), at: 1) }
        tiff.ifd(fields, at: noteIFD)
        tiff.pad(to: 400)
        location.forEach { tiff.u16($0) }
        tiff.pad(to: 512)
        return tiff.data
    }

    func testReadsTheA7CLayout() {
        XCTAssertEqual(FocusRecord.parse(header: file()),
                       FocusRecord(width: 6000, height: 4000, x: 2840, y: 1583, orientation: 6, focusMode: 2))
    }

    func testOlderSonyHeaderKeepsFileOffsets() {
        XCTAssertEqual(FocusRecord.parse(header: file(makerNoteHeader: "SONY DSC \0\0\0"))?.x, 2840)
        XCTAssertEqual(FocusRecord.parse(header: file(makerNoteHeader: "SONY CAM \0\0\0"))?.y, 1583)
    }

    func testUncheckedMakerNoteLayoutsAreRefused() {
        XCTAssertNil(FocusRecord.parse(header: file(makerNoteHeader: "SONY PIC\0\0\0\0")))
        XCTAssertNil(FocusRecord.parse(header: file(makerNoteHeader: "PREMI\0\0\0\0\0\0\0")))
    }

    func testWrongTypeIsRefused() {
        XCTAssertNil(FocusRecord.parse(header: file(locationType: 4)))
    }

    func testValueBeyondTheBytesReadIsAbsent() {
        // The 64 KiB already read must hold it: no further read is ever made.
        XCTAssertNil(FocusRecord.parse(header: file().prefix(404)))
    }

    func testTruncatedOrCorruptHeadersNeverCrash() {
        let whole = file(makerNoteHeader: "SONY DSC \0\0\0")
        for size in 0..<whole.count { _ = FocusRecord.parse(header: whole.prefix(size)) }
        for at in stride(from: 0, to: whole.count, by: 3) {
            var corrupt = whole
            corrupt[at] = 0xFF
            _ = FocusRecord.parse(header: corrupt)
        }
        XCTAssertNil(FocusRecord.parse(header: Data([0x4D, 0x4D, 0, 42, 0, 0, 0, 8])), "big endian")
    }

    func testInterpretation() {
        let record = FocusRecord.parse(header: file())!
        XCTAssertEqual(record.focus, .point(FocusPoint(sensorWidth: 6000, sensorHeight: 4000, x: 2840, y: 1583, orientation: 6)!))
        XCTAssertEqual(FocusRecord.parse(header: file(focusMode: 0))?.focus, .manual)
        XCTAssertEqual(FocusRecord.parse(header: file(focusMode: nil))?.focus.isPoint, true, "no mode: keep the position")
        XCTAssertEqual(FocusRecord.parse(header: file(location: [6000, 4000, 6001, 10]))?.focus, CameraFocus.absent)
        XCTAssertEqual(FocusRecord.parse(header: file(location: [0, 0, 0, 0]))?.focus, CameraFocus.absent)
        XCTAssertEqual(FocusRecord.parse(header: file(orientation: 5))?.focus, CameraFocus.absent, "mirrored")
    }

    func testReadFromFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BVAF-\(UUID().uuidString).arw")
        defer { try? FileManager.default.removeItem(at: url) }
        try file().write(to: url)
        let header = ARWPreview.read(url, withPreview: false)
        XCTAssertNil(header?.preview)
        XCTAssertEqual(header?.focus.isPoint, true)
        XCTAssertNil(ARWPreview.read(url.deletingPathExtension().appendingPathExtension("jpg")), "not an ARW")
    }
}

final class FocusPointTests: XCTestCase {
    /// Values from real A7C files, checked by eye on the rendered image.
    func testOrientations() {
        // Landscape: A7C03465.
        let upright = FocusPoint(sensorWidth: 6000, sensorHeight: 4000, x: 3421, y: 950, orientation: 1)!
        XCTAssertEqual([upright.width, upright.height, upright.x, upright.y], [6000, 4000, 3421, 950])
        // Turned 90° clockwise for display, the sensor's left edge is now on top: A7C02352.
        let clockwise = FocusPoint(sensorWidth: 6000, sensorHeight: 4000, x: 2840, y: 1583, orientation: 6)!
        XCTAssertEqual([clockwise.width, clockwise.height, clockwise.x, clockwise.y], [4000, 6000, 2417, 2840])
        // 270° clockwise, the sensor's right edge is now on top: A7C03233.
        let counter = FocusPoint(sensorWidth: 6000, sensorHeight: 4000, x: 5250, y: 2325, orientation: 8)!
        XCTAssertEqual([counter.width, counter.height, counter.x, counter.y], [4000, 6000, 2325, 750])
        // Upside down: A7C03139.
        let flipped = FocusPoint(sensorWidth: 6000, sensorHeight: 4000, x: 2878, y: 2641, orientation: 3)!
        XCTAssertEqual([flipped.x, flipped.y], [3122, 1359])

        XCTAssertEqual(clockwise.normalized.x, 2417.0 / 4000, accuracy: 1e-9)
        XCTAssertEqual(clockwise.normalized.y, 2840.0 / 6000, accuracy: 1e-9)
        XCTAssertNil(FocusPoint(sensorWidth: 6000, sensorHeight: 4000, x: 1, y: 1, orientation: 2))
    }

    func testCentre() {
        XCTAssertTrue(FocusPoint(sensorWidth: 6000, sensorHeight: 4000, x: 3000, y: 2000, orientation: 6)!.isCentre)
        XCTAssertFalse(FocusPoint(sensorWidth: 6000, sensorHeight: 4000, x: 3000, y: 2658, orientation: 1)!.isCentre)
    }
}

private extension CameraFocus {
    var isPoint: Bool {
        if case .point = self { return true }
        return false
    }
}
