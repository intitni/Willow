import Foundation
import ImageIO

package struct ReaderImage: Hashable, Sendable {
    private let width: Int
    private let height: Int?

    package init(viewport: CGSize, displayScale: CGFloat, zoom: CGFloat, vertical: Bool) {
        width = Int((viewport.width * displayScale * zoom).rounded(.up))
        height = vertical ? nil : Int((viewport.height * displayScale * zoom).rounded(.up))
    }

    @concurrent
    package func decode(_ data: Data) async -> (bitmap: CGImage, originalSize: CGSize)? {
        guard !Task.isCancelled, width > 0, height.map({ $0 > 0 }) ?? true,
              let source = Self.source(data), CGImageSourceGetCount(source) == 1,
              let size = Self.orientedSize(of: source) else { return nil }
        let widthScale = CGFloat(width) / size.width
        let heightScale = height.map { CGFloat($0) / size.height } ?? widthScale
        let scale = min(widthScale, heightScale)
        // Use the original when it already fits; there's nothing to downsample.
        guard scale < 1 else { return nil }
        let longEdge = Int((max(size.width, size.height) * scale).rounded(.up))
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, longEdge),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { return nil }
        return (bitmap, size)
    }

    package static func orientedSize(of data: Data) -> CGSize? {
        source(data).flatMap { orientedSize(of: $0) }
    }

    private static func source(_ data: Data) -> CGImageSource? {
        CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    private static func orientedSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }
}
