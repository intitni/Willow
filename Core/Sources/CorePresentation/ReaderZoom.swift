import Foundation

package struct ReaderZoom: Equatable {
    package private(set) var scale: CGFloat = 1
    package private(set) var offset = CGSize.zero

    package init() {}

    package func moving(from start: CGPoint, to end: CGPoint, magnification: CGFloat = 1, in size: CGSize) -> Self {
        let nextScale = min(4, max(1, scale * magnification))
        let ratio = nextScale / scale
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Move the image point under the previous touch center to the new one.
        let nextOffset = CGSize(
            width: end.x - center.x - (start.x - center.x - offset.width) * ratio,
            height: end.y - center.y - (start.y - center.y - offset.height) * ratio
        )
        return Self(scale: nextScale, offset: nextOffset).clamped(in: size)
    }

    package func clamped(in size: CGSize) -> Self {
        let limitX = size.width * (scale - 1) / 2
        let limitY = size.height * (scale - 1) / 2
        return Self(scale: scale, offset: CGSize(
            width: min(limitX, max(-limitX, offset.width)),
            height: min(limitY, max(-limitY, offset.height))
        ))
    }

    private init(scale: CGFloat, offset: CGSize) {
        self.scale = scale
        self.offset = offset
    }
}
