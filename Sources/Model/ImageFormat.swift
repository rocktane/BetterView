import UniformTypeIdentifiers

enum ImageFormat {
    // Keep the identifiers in sync with CFBundleDocumentTypes in Info.plist.
    private static let raster: [(extensions: [String], uti: String)] = [
        (["jpg", "jpeg"], "public.jpeg"),
        (["png"], "public.png"),
        (["bmp"], "com.microsoft.bmp"),
        (["tif", "tiff"], "public.tiff"),
        (["jp2"], "public.jpeg-2000"),
        (["heic"], "public.heic"),
        (["heif"], "public.heif"),
        (["webp"], "org.webmproject.webp"),
        (["avif"], "public.avif"),
        (["jxl"], "public.jpeg-xl"),
    ]

    static let rasterExtensions = Set(raster.flatMap(\.extensions))
    static let extensions = RawFormat.extensions.union(rasterExtensions)
    static let contentTypes = (RawFormat.all.map(\.uti) + raster.map(\.uti)).compactMap { UTType($0) }
}
