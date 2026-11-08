import XCTest
@testable import BetterView

final class ShortcutMapTests: XCTestCase {
    func testDefaultsAnswerToTheDocumentedKeys() {
        let map = ShortcutMap.defaults
        XCTAssertEqual(map.action(for: .code(51)), .delete)
        XCTAssertEqual(map.action(for: .character("x")), .delete)
        XCTAssertEqual(map.action(for: .code(124)), .next)
        XCTAssertEqual(map.action(for: .character("z")), .toggleZoom)
        XCTAssertEqual(map.action(for: .character("z", modifiers: .command)), .undo)
        XCTAssertNil(map.action(for: .character("x", modifiers: .shift)))
    }

    func testEveryActionHasAKeyByDefault() {
        for action in ShortcutAction.allCases {
            XCTAssertFalse(ShortcutMap.defaults.keys(for: action).isEmpty, action.rawValue)
        }
    }

    func testAssigningAUsedKeyMovesIt() {
        var map = ShortcutMap.defaults
        let previous = map.assign(.character("x"), to: .next)
        XCTAssertEqual(previous, .delete)
        XCTAssertEqual(map.action(for: .character("x")), .next)
        XCTAssertFalse(map.keys(for: .delete).contains(.character("x")))
        XCTAssertTrue(map.keys(for: .delete).contains(.code(51)), "its other keys stay")
    }

    func testAssigningTheSameKeyTwiceChangesNothing() {
        var map = ShortcutMap.defaults
        XCTAssertNil(map.assign(.character("x"), to: .delete))
        XCTAssertEqual(map, .defaults)
    }

    func testReservedKeysAreRefused() {
        var map = ShortcutMap.defaults
        let quit = KeyBinding.character("q", modifiers: .command)
        XCTAssertTrue(quit.isReserved)
        map.assign(quit, to: .delete)
        XCTAssertNil(map.action(for: quit))
    }

    func testRemovedKeyStopsAnswering() {
        var map = ShortcutMap.defaults
        map.remove(.character("x"))
        XCTAssertNil(map.action(for: .character("x")))
    }

    func testChoicesSurviveARoundTrip() {
        var map = ShortcutMap.defaults
        map.remove(.code(51))
        map.assign(.character("d"), to: .delete)
        map.assign(.code(53, modifiers: .shift), to: .toggleInfo)
        XCTAssertEqual(ShortcutMap.decoded(from: map.encoded()), map)
    }

    func testARemovedDefaultKeyDoesNotComeBack() {
        var map = ShortcutMap.defaults
        map.remove(.code(51))
        XCTAssertNil(ShortcutMap.decoded(from: map.encoded()).action(for: .code(51)))
    }

    func testDamagedStorageFallsBackToDefaults() {
        XCTAssertEqual(ShortcutMap.decoded(from: Data("not json".utf8)), .defaults)
        XCTAssertEqual(ShortcutMap.decoded(from: nil), .defaults)
    }

    func testAnActionUnknownToTheStorageGetsItsDefaults() throws {
        let stored = try JSONEncoder().encode(["delete": [KeyBinding.character("d")]])
        let map = ShortcutMap.decoded(from: stored)
        XCTAssertEqual(map.keys(for: .delete), [.character("d")])
        XCTAssertEqual(map.action(for: .code(124)), .next)
    }

    func testPlainKeyIsNeverTheDeleteMenuKey() {
        var map = ShortcutMap.defaults
        XCTAssertEqual(map.menuBinding(for: .delete), .code(51, modifiers: .command))
        map.remove(.code(51, modifiers: .command))
        XCTAssertNil(map.menuBinding(for: .delete), "a plain key in the menu would also fire from the settings window")
    }

    func testLabelsAndMenuKeys() {
        XCTAssertEqual(KeyBinding.code(51, modifiers: .command).label, "⌘⌫")
        XCTAssertEqual(KeyBinding.character("x").label, "X")
        XCTAssertEqual(KeyBinding.code(49).label, "Espace")
        XCTAssertEqual(KeyBinding.code(51).menuEquivalent?.key, "\u{8}")
        XCTAssertEqual(KeyBinding.character("z", modifiers: .command).menuEquivalent?.key, "z")
    }
}

final class WindowShapeTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    func testWindowKeepsItsHeightAcrossOrientations() {
        let center = CGPoint(x: 700, y: 500)
        let landscape = WindowShape.frame(aspect: 1.5, height: 600, center: center, visible: screen)
        let portrait = WindowShape.frame(aspect: 2.0 / 3.0, height: 600, center: center, visible: screen)
        XCTAssertEqual(landscape.size, CGSize(width: 900, height: 600))
        XCTAssertEqual(portrait.size, CGSize(width: 400, height: 600))
        XCTAssertEqual(portrait.midX, 700, accuracy: 1)
    }

    func testWindowStaysOnScreen() {
        let visible = CGRect(x: 0, y: 40, width: 1512, height: 900)
        let tooTall = WindowShape.frame(aspect: 2.0 / 3.0, height: 5000, center: CGPoint(x: 700, y: 500), visible: visible)
        XCTAssertEqual(tooTall.height, 900)
        XCTAssertTrue(visible.contains(tooTall))

        let tooWide = WindowShape.frame(aspect: 3, height: 800, center: CGPoint(x: 700, y: 500), visible: visible)
        XCTAssertEqual(tooWide.width, 1512)
        XCTAssertEqual(tooWide.height, 504)

        let offEdge = WindowShape.frame(aspect: 1.5, height: 400, center: CGPoint(x: 1500, y: 930), visible: visible)
        XCTAssertTrue(visible.contains(offEdge))
    }

    func testSmallDifferencesDoNotCountAsANewShape() {
        // An A7C header says 6024 x 4024 and the render 6000 x 4000.
        XCTAssertTrue(WindowShape.sameShape(6024.0 / 4024.0, 1.5))
        XCTAssertFalse(WindowShape.sameShape(1.5, 2.0 / 3.0))
        XCTAssertFalse(WindowShape.sameShape(1.5, 16.0 / 9.0))
    }
}

final class PhotoMetadataTests: XCTestCase {
    /// A little-endian TIFF: IFD0 points to an EXIF block whose long values sit behind it.
    private func header(iso: UInt16? = 800, date: String? = "2026:09:19 11:21:54") -> Data {
        var data = Data([0x49, 0x49, 42, 0])
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func field(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) {
            append16(tag); append16(type); append32(count); append32(value)
        }
        append32(8)
        append16(1)
        field(0x8769, 4, 1, 26)
        append32(0)
        let fields = 4 + (iso == nil ? 0 : 1) + (date == nil ? 0 : 1)
        let values = 26 + 2 + fields * 12
        append16(UInt16(fields))
        field(0x829A, 5, 1, UInt32(values))
        field(0x829D, 5, 1, UInt32(values + 8))
        field(0x920A, 5, 1, UInt32(values + 16))
        if let iso { field(0x8827, 3, 1, UInt32(iso)) }
        if date != nil { field(0x9003, 2, 20, UInt32(values + 24)) }
        field(0x0001, 3, 1, 0)
        for (numerator, denominator) in [(1, 250), (28, 10), (35, 1)] as [(UInt32, UInt32)] {
            append32(numerator); append32(denominator)
        }
        if let date { data.append(contentsOf: Array(date.utf8) + [0]) }
        return data
    }

    func testReadsTheShootingInformation() throws {
        let metadata = try XCTUnwrap(PhotoMetadata.parse(header: header()))
        XCTAssertEqual(metadata.iso, 800)
        XCTAssertEqual(metadata.exposure ?? 0, 0.004, accuracy: 0.00001)
        XCTAssertEqual(metadata.fNumber ?? 0, 2.8, accuracy: 0.00001)
        XCTAssertEqual(metadata.focalLength ?? 0, 35, accuracy: 0.00001)
        XCTAssertEqual(metadata.date, PhotoMetadata.parseDate("2026:09:19 11:21:54"))
    }

    func testDateAndSettingsAreSeparateLines() throws {
        let metadata = try XCTUnwrap(PhotoMetadata.parse(header: header()))
        XCTAssertTrue(metadata.dateText.contains("19 septembre 2026"), metadata.dateText)
        XCTAssertTrue(metadata.dateText.contains("11:21"), "the camera clock, whatever the time zone: \(metadata.dateText)")
        XCTAssertFalse(metadata.dateText.contains("ISO"))
        XCTAssertEqual(metadata.settingsText, "ISO 800  ·  1/250 s  ·  f/2.8  ·  35 mm")
    }

    func testMissingDateOrISOAsksForTheFallback() {
        XCTAssertNil(PhotoMetadata.parse(header: header(iso: nil)))
        XCTAssertNil(PhotoMetadata.parse(header: header(date: nil)))
    }

    func testDamagedHeadersEndInNil() {
        let good = header()
        for length in stride(from: 0, to: good.count - 20, by: 3) {
            XCTAssertNil(PhotoMetadata.parse(header: good.prefix(length)), "truncated at \(length)")
        }
        XCTAssertNil(PhotoMetadata.parse(header: Data(repeating: 0xFF, count: 200)))
    }

    func testImpossibleDatesAreRejected() {
        XCTAssertNil(PhotoMetadata.parseDate("0000:00:00 00:00:00"))
        XCTAssertNil(PhotoMetadata.parseDate("n'importe quoi"))
    }

    func testEmptyInformationGivesAnEmptyLine() {
        XCTAssertEqual(PhotoMetadata().settingsText, "")
        XCTAssertEqual(PhotoMetadata().dateText, "")
    }
}
