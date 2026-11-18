import CorePresentation
import Foundation
import Testing

@Suite
struct ReaderZoomTests {
    private let size = CGSize(width: 400, height: 600)

    @Test
    func `Zoom keeps the content under an off-center touch`() {
        let touch = CGPoint(x: 100, y: 150)
        let zoom = ReaderZoom().moving(from: touch, to: touch, magnification: 2, in: size)
        #expect(zoom.scale == 2)
        #expect(zoom.offset == CGSize(width: 100, height: 150))
    }

    @Test
    func `The same image point follows the fingers while scaling and panning`() {
        let first = CGPoint(x: 120, y: 220)
        let second = CGPoint(x: 155, y: 245)
        let third = CGPoint(x: 175, y: 265)
        let zoom = ReaderZoom().moving(from: first, to: second, magnification: 2, in: size)
        #expect(zoom.offset == CGSize(width: 115, height: 105))
        let moved = zoom.moving(from: second, to: third, magnification: 1.5, in: size)
        #expect(moved == ReaderZoom().moving(from: first, to: third, magnification: 3, in: size))
    }

    @Test
    func `Panning stays within the visible page and zooming out centers it`() {
        let center = CGPoint(x: 200, y: 300)
        let zoom = ReaderZoom().moving(from: center, to: center, magnification: 8, in: size)
            .moving(from: center, to: CGPoint(x: 1000, y: -1000), in: size)
        #expect(zoom.scale == 4)
        #expect(zoom.offset == CGSize(width: 600, height: -900))
        #expect(zoom.moving(from: .zero, to: .zero, magnification: 0.1, in: size) == ReaderZoom())
    }
}
