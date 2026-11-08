import CoreGraphics

/// The AF position the camera wrote in the file (Sony MakerNote 0x2027 FocusLocation). It
/// says where the camera aimed when it took the photo, not that the photo is sharp there.
struct FocusPoint: Equatable, Sendable {
    /// Upright frame the position is measured in, usually 6000×4000 or 4000×6000.
    let width: Int
    let height: Int
    /// Upright position in that frame, origin at the top left.
    let x: Int
    let y: Int

    /// Turns the camera's record, which is in sensor (landscape) coordinates, upright.
    /// Only orientations 1, 3, 6 and 8 occur on these cameras; mirrored ones give nil.
    init?(sensorWidth w: Int, sensorHeight h: Int, x: Int, y: Int, orientation: Int) {
        guard w > 0, h > 0, (0...w).contains(x), (0...h).contains(y) else { return nil }
        switch orientation {
        case 1: (width, height, self.x, self.y) = (w, h, x, y)
        case 3: (width, height, self.x, self.y) = (w, h, w - x, h - y)
        case 6: (width, height, self.x, self.y) = (h, w, h - y, x)
        case 8: (width, height, self.x, self.y) = (h, w, y, w - x)
        default: return nil
        }
    }

    /// Fraction of the upright image, origin at the top left. Proportions survive any
    /// difference in scale between the camera's frame and the rendered image.
    var normalized: CGPoint {
        CGPoint(x: Double(x) / Double(width), y: Double(y) / Double(height))
    }

    /// The exact centre is also where the camera falls back to without an AF position.
    var isCentre: Bool { 2 * x == width && 2 * y == height }
}

/// What a file says about its AF position.
enum CameraFocus: Equatable, Sendable {
    case point(FocusPoint)
    /// Manual focus: any recorded position would not be an AF position.
    case manual
    /// Not a Sony file, or no position in it.
    case absent
}
