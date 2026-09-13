import AppKit
import ImageIO

enum ImageThumbnail {
    // Two pixels per point for the 84-point list preview on Retina displays.
    static let maximumPixelSize = 168

    static func make(data: Data, maximumPixelSize: Int = maximumPixelSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return make(source: source, maximumPixelSize: maximumPixelSize)
    }

    static func make(url: URL, maximumPixelSize: Int = maximumPixelSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return make(source: source, maximumPixelSize: maximumPixelSize)
    }

    private static func make(source: CGImageSource, maximumPixelSize: Int) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    // Inline and hover previews need screen-sized pixels. Keep tall screenshots
    // readable while bounding each decoded preview to about 32 MB at four bytes/pixel.
    static func previewPixelSize(width: Int, height: Int) -> Int {
        let width = Double(max(1, width)), height = Double(max(1, height))
        let scale = min(1, 1400 / width, sqrt(8_000_000 / (width * height)))
        return max(1, Int(floor(max(width, height) * scale)))
    }
}
