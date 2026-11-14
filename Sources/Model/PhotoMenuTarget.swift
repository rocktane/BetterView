import Foundation

/// What a context menu acts on, and how its items name it. As in the Finder: a right-click
/// on a selected photo acts on the whole selection, on any other photo on that photo alone.
struct PhotoMenuTarget: Equatable, Sendable {
    /// The photos the main items act on, in folder order.
    let photos: [PhotoKey]
    /// The selection, when it is not already the target: offered as its own item.
    let otherSelection: [PhotoKey]
    /// The whole folder, when it is more than the target: offered as its own item.
    let folder: [PhotoKey]
    let isSelection: Bool

    init(clicked: PhotoKey, selection: [PhotoKey], folder: [PhotoKey]) {
        isSelection = selection.count > 1 && selection.contains(clicked)
        photos = isSelection ? selection : [clicked]
        otherSelection = isSelection || selection.isEmpty || selection == [clicked] ? [] : selection
        self.folder = folder.count > photos.count ? folder : []
    }

    /// « la photo », « les 3 photos sélectionnées » : what an item does it to.
    static func phrase(count: Int, selected: Bool = false) -> String {
        if count == 1 { return selected ? "la photo sélectionnée" : "la photo" }
        return "les \(count) photos" + (selected ? " sélectionnées" : "")
    }

    /// The title of an « open in » item: short for the photo clicked, explicit otherwise.
    static func openTitle(app: String, count: Int, selected: Bool = false, folder: Bool = false) -> String {
        if folder { return "Ouvrir les \(count) photos du dossier dans \(app)…" }
        if count == 1 && !selected { return "Ouvrir dans \(app)…" }
        return "Ouvrir \(phrase(count: count, selected: selected)) dans \(app)…"
    }
}
