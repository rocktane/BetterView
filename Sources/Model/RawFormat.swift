/// The RAW formats BetterView opens. Keep in sync with CFBundleDocumentTypes in Info.plist.
struct RawFormat: Identifiable, Sendable {
    let fileExtension: String
    let uti: String
    let brand: String
    var id: String { uti }

    static let all: [RawFormat] = [
        .init(fileExtension: "arw", uti: "com.sony.arw-raw-image", brand: "Sony"),
        .init(fileExtension: "cr2", uti: "com.canon.cr2-raw-image", brand: "Canon"),
        .init(fileExtension: "cr3", uti: "com.canon.cr3-raw-image", brand: "Canon"),
        .init(fileExtension: "nef", uti: "com.nikon.raw-image", brand: "Nikon"),
        .init(fileExtension: "nrw", uti: "com.nikon.nrw-raw-image", brand: "Nikon"),
        .init(fileExtension: "raf", uti: "com.fuji.raw-image", brand: "Fujifilm"),
        .init(fileExtension: "dng", uti: "com.adobe.raw-image", brand: "Adobe"),
        .init(fileExtension: "orf", uti: "com.olympus.raw-image", brand: "Olympus"),
        .init(fileExtension: "rw2", uti: "com.panasonic.rw2-raw-image", brand: "Panasonic"),
        .init(fileExtension: "pef", uti: "com.pentax.raw-image", brand: "Pentax"),
        .init(fileExtension: "srw", uti: "com.samsung.raw-image", brand: "Samsung"),
    ]

    static let extensions: Set<String> = Set(all.map(\.fileExtension))
}
