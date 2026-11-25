import CoreGraphics
import Foundation

enum RotationDirection: Int, Sendable {
    case left = -1, right = 1
}

/// Extra orientation applied to an already upright image.
enum PhotoRotation: Int, Codable, Sendable {
    case upright, right, upsideDown, left

    func turned(_ direction: RotationDirection) -> Self {
        Self(rawValue: (rawValue + direction.rawValue + 4) % 4)!
    }

    func size(_ original: CGSize) -> CGSize {
        rawValue % 2 == 0 ? original : CGSize(width: original.height, height: original.width)
    }

    /// Normalized image coordinates with y down, as used by the camera's AF point.
    func point(_ original: CGPoint) -> CGPoint {
        switch self {
        case .upright: original
        case .right: CGPoint(x: 1 - original.y, y: original.x)
        case .upsideDown: CGPoint(x: 1 - original.x, y: 1 - original.y)
        case .left: CGPoint(x: original.y, y: 1 - original.x)
        }
    }
}

/// Per-file orientation and bookmarks in BetterView, tied to the file revision.
struct PhotoRotations: Codable, Sendable {
    static var defaultURL: URL {
        DeletionJournal.defaultURL.deletingLastPathComponent().appendingPathComponent("rotations.json")
    }

    private struct Entry: Codable, Sendable {
        var photo: PhotoKey
        var rotation: PhotoRotation
        var marked: Bool?
    }

    private var entries: [String: Entry] = [:]

    subscript(photo: PhotoKey) -> PhotoRotation {
        guard let entry = entries[photo.path], entry.photo == photo else { return .upright }
        return entry.rotation
    }

    func isMarked(_ photo: PhotoKey) -> Bool {
        entries[photo.path]?.photo == photo && entries[photo.path]?.marked == true
    }

    static func read(from url: URL) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return Self()
        }
    }

    /// One atomic write for the whole burst. Call on a worker, and publish only after success.
    func saving(_ direction: RotationDirection, for photos: [PhotoKey], to url: URL) throws -> Self {
        try saving(photos, to: url) { photo in (self[photo].turned(direction), isMarked(photo)) }
    }

    func togglingMark(for photo: PhotoKey, to url: URL) throws -> Self {
        try saving([photo], to: url) { photo in (self[photo], !isMarked(photo)) }
    }

    private func saving(_ photos: [PhotoKey], to url: URL,
                        edit: (PhotoKey) -> (rotation: PhotoRotation, marked: Bool)) throws -> Self {
        guard photos.allSatisfy({ PhotoKey.read(path: $0.path) == $0 }) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "Au moins une des photos a été déplacée ou modifiée. Réessaie après l’actualisation du dossier."])
        }
        var updated = self
        for photo in photos {
            let (rotation, marked) = edit(photo)
            updated.entries[photo.path] = rotation == .upright && !marked
                ? nil : Entry(photo: photo, rotation: rotation, marked: marked ? true : nil)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        return updated
    }
}
