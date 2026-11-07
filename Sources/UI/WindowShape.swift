import CoreGraphics

/// Window frames that take the exact shape of the photo, which is what leaves no bars around it.
enum WindowShape {
    /// A preview this close to the current shape keeps the frame: the header's size and the
    /// rendered size of one photo differ slightly, and that must not move the window.
    static let aspectTolerance: CGFloat = 0.01

    static func sameShape(_ a: CGFloat, _ b: CGFloat) -> Bool {
        abs(a / b - 1) < aspectTolerance
    }

    private static func fittedSize(aspect: CGFloat, in box: CGSize) -> CGSize {
        let width = min(box.width, box.height * aspect)
        return CGSize(width: width.rounded(), height: (width / aspect).rounded())
    }

    /// A window that keeps its height between landscape and portrait, so only its width
    /// changes, kept on screen and around the same centre.
    static func frame(aspect: CGFloat, height: CGFloat, center: CGPoint, visible: CGRect) -> CGRect {
        let size = fittedSize(aspect: aspect, in: CGSize(width: visible.width, height: min(height, visible.height)))
        let x = min(max(center.x - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(center.y - size.height / 2, visible.minY), visible.maxY - size.height)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}
