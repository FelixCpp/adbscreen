import AppKit

extension NSView {
    /// Captures the view's current on-screen content as an image. Used for
    /// the per-tile screenshot button.
    func snapshotImage() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0, let rep = bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
