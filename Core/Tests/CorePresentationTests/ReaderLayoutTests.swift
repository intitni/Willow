import CorePresentation
import Foundation
import Testing

@Suite
struct ReaderLayoutTests {
    private let spread = ReaderLayout(
        viewport: CGSize(width: 1000, height: 700), horizontalReading: true,
        spreadsEnabled: true, regularWidth: true
    )
    private let shifted = ReaderLayout(
        viewport: CGSize(width: 1000, height: 700), horizontalReading: true,
        spreadsEnabled: true, regularWidth: true, pairsFromSecondPage: true
    )

    @Test(arguments: [
        CGSize(width: 393, height: 852), CGSize(width: 440, height: 956),
        CGSize(width: 700, height: 980), CGSize(width: 900, height: 1200),
        CGSize(width: 800, height: 800),
    ])
    func `Portrait and square viewports show single pages`(viewport: CGSize) {
        let layout = ReaderLayout(viewport: viewport, horizontalReading: true,
                                  spreadsEnabled: true, regularWidth: true, pairsFromSecondPage: true)
        #expect(!layout.usesSpread)
        #expect(!layout.usesSpreadOffset)
        #expect(layout.starts(pageCount: 3, reversed: false) == [0, 1, 2])
        #expect(layout.anchor(for: 2) == 2)
    }

    @Test(arguments: [
        (horizontal: false, enabled: true, regularWidth: true),
        (horizontal: true, enabled: false, regularWidth: true),
        (horizontal: true, enabled: true, regularWidth: false),
    ])
    func `All spread conditions are required`(
        settings: (horizontal: Bool, enabled: Bool, regularWidth: Bool)
    ) {
        let layout = ReaderLayout(viewport: CGSize(width: 650, height: 400), horizontalReading: settings.horizontal,
                                  spreadsEnabled: settings.enabled, regularWidth: settings.regularWidth)
        #expect(!layout.usesSpread)
    }

    @Test
    func `Default spreads start on the first page`() {
        #expect(spread.usesSpread)
        let narrowerSpread = ReaderLayout(viewport: CGSize(width: 650, height: 400), horizontalReading: true,
                                          spreadsEnabled: true, regularWidth: true)
        #expect(narrowerSpread.usesSpread)
        #expect(spread.starts(pageCount: 0, reversed: false).isEmpty)
        #expect(spread.starts(pageCount: 5, reversed: false) == [0, 2, 4])
        #expect(spread.starts(pageCount: 5, reversed: true) == [4, 2, 0])
        #expect(spread.slots(start: 4, reversed: false) == [4, 5])
        #expect(spread.slots(start: 4, reversed: true) == [5, 4])
        #expect(spread.anchor(for: 3) == 2)
    }

    @Test
    func `Shifted spreads display the first page on its own`() {
        #expect(shifted.starts(pageCount: 0, reversed: false).isEmpty)
        #expect(shifted.starts(pageCount: 1, reversed: true) == [0])
        #expect(shifted.starts(pageCount: 5, reversed: false) == [0, 1, 3])
        #expect(shifted.starts(pageCount: 6, reversed: true) == [5, 3, 1, 0])
        #expect(shifted.slots(start: 0, reversed: false) == [0])
        #expect(shifted.slots(start: 0, reversed: true) == [0])
        #expect(shifted.slots(start: 1, reversed: false) == [1, 2])
        #expect(shifted.slots(start: 1, reversed: true) == [2, 1])
        #expect(shifted.slots(start: 5, reversed: true) == [6, 5])
    }

    @Test
    func `Shifted anchors and prefetch use the original page indices`() {
        #expect((0..<6).map { shifted.anchor(for: $0) } == [0, 1, 1, 3, 3, 5])
        #expect(shifted.prefetchIndices(from: 2, pageCount: 6) == 1..<6)
        #expect(shifted.prefetchIndices(from: 5, pageCount: 6) == 5..<6)
    }

    @Test(arguments: [
        (image: CGSize(width: 100, height: 700), isNarrow: true),
        (image: CGSize(width: 250, height: 1400), isNarrow: true),
        (image: CGSize(width: 126, height: 700), isNarrow: false),
        (image: CGSize(width: 500, height: 700), isNarrow: false),
    ])
    func `Narrow images fit within one quarter of the slot width`(
        example: (image: CGSize, isNarrow: Bool)
    ) {
        let slot = CGSize(width: 500, height: 700)
        #expect(ReaderLayout.isNarrowImage(example.image, in: slot) == example.isNarrow)
    }
}
