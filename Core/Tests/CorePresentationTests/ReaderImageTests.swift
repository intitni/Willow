import CoreGraphics
import CorePresentation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite
struct ReaderImageTests {
    @Test
    func `Vertical pages use the screen width and increase resolution after zooming`() async throws {
        let data = try makePage()
        let viewport = CGSize(width: 150, height: 200)
        let normal = ReaderImage(viewport: viewport, displayScale: 2, zoom: 1, vertical: true)
        let zoomed = ReaderImage(viewport: viewport, displayScale: 2, zoom: 2, vertical: true)
        let page = try #require(await normal.decode(data))
        let detail = try #require(await zoomed.decode(data))
        #expect(page.bitmap.width == 300)
        #expect(page.bitmap.height == 450)
        #expect(detail.bitmap.width == 600)
        #expect(detail.bitmap.height == 900)
        #expect(page.originalSize == detail.originalSize)
    }

    @Test
    func `Horizontal pages fit the viewport using the rotated image dimensions`() async throws {
        let data = try makePage(orientation: 6)
        #expect(ReaderImage.orientedSize(of: data) == CGSize(width: 1200, height: 800))
        let rendering = ReaderImage(viewport: CGSize(width: 600, height: 200),
                                    displayScale: 1, zoom: 1, vertical: false)
        let page = try #require(await rendering.decode(data))
        #expect(page.bitmap.width == 300)
        #expect(page.bitmap.height == 200)
        #expect(page.originalSize == CGSize(width: 1200, height: 800))
    }

    @Test
    func `Rounding decoded pixels does not classify a readable spread page as narrow`() async throws {
        let data = try makePage(width: 323, height: 2000)
        let slot = CGSize(width: 452, height: 700)
        let rendering = ReaderImage(viewport: slot, displayScale: 2, zoom: 1, vertical: false)
        let page = try #require(await rendering.decode(data))
        let bitmapSize = CGSize(width: page.bitmap.width, height: page.bitmap.height)
        #expect(ReaderLayout.isNarrowImage(bitmapSize, in: slot))
        #expect(!ReaderLayout.isNarrowImage(page.originalSize, in: slot))
    }

    private func makePage(width: Int = 800, height: Int = 1200, orientation: Int = 1) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let page = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, page, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
