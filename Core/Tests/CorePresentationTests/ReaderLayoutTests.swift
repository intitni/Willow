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
        #expect(layout.pagination(pageCount: 3, widePages: [1]).starts(reversed: false) == [0, 1, 2])
        #expect(layout.pagination(pageCount: 3).anchor(for: 2) == 2)
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
        #expect(spread.pagination(pageCount: 0).starts(reversed: false).isEmpty)
        let pagination = spread.pagination(pageCount: 5)
        #expect(pagination.starts(reversed: false) == [0, 2, 4])
        #expect(pagination.starts(reversed: true) == [4, 2, 0])
        #expect(pagination.slots(start: 4, reversed: false) == [4, 5])
        #expect(pagination.slots(start: 4, reversed: true) == [5, 4])
        #expect(pagination.anchor(for: 3) == 2)
    }

    @Test
    func `Shifted spreads display the first page on its own`() {
        #expect(shifted.pagination(pageCount: 0).starts(reversed: false).isEmpty)
        #expect(shifted.pagination(pageCount: 1).starts(reversed: true) == [0])
        #expect(shifted.pagination(pageCount: 5).starts(reversed: false) == [0, 1, 3])
        let pagination = shifted.pagination(pageCount: 6)
        #expect(pagination.starts(reversed: true) == [5, 3, 1, 0])
        #expect(pagination.slots(start: 0, reversed: false) == [0])
        #expect(pagination.slots(start: 0, reversed: true) == [0])
        #expect(pagination.slots(start: 1, reversed: false) == [1, 2])
        #expect(pagination.slots(start: 1, reversed: true) == [2, 1])
        #expect(pagination.slots(start: 5, reversed: true) == [6, 5])
    }

    @Test
    func `Shifted anchors and prefetch use the original page indices`() {
        let pagination = shifted.pagination(pageCount: 6)
        #expect((0..<6).map { pagination.anchor(for: $0) } == [0, 1, 1, 3, 3, 5])
        #expect(pagination.prefetchIndices(from: 2) == 1..<6)
        #expect(pagination.prefetchIndices(from: 5) == 5..<6)
    }

    @Test
    func `Wide pages split only their original spreads`() {
        let pagination = spread.pagination(pageCount: 11, widePages: [1, 4, 7, 8, 10])
        #expect(pagination.starts(reversed: false) == [0, 1, 2, 4, 5, 6, 7, 8, 9, 10])
        #expect(pagination.starts(reversed: true) == [10, 9, 8, 7, 6, 5, 4, 2, 1, 0])
        #expect(pagination.slots(start: 0, reversed: false) == [0])
        #expect(pagination.slots(start: 2, reversed: true) == [3, 2])
        for page in [1, 4, 5, 6, 7, 8, 9, 10] {
            #expect(pagination.slots(start: page, reversed: true) == [page])
        }
        #expect((0..<11).map { pagination.anchor(for: $0) } == [0, 1, 2, 2, 4, 5, 6, 7, 8, 9, 10])
        #expect(pagination.prefetchIndices(from: 3) == 2..<7)
        #expect(pagination.prefetchIndices(from: 4) == 4..<8)
        #expect(pagination.prefetchIndices(from: 10) == 10..<11)
    }

    @Test(arguments: [false, true])
    func `Learning about an earlier wide page leaves the resumed spread intact`(offset: Bool) {
        let layout = offset ? shifted : spread
        let earlierWidePage = offset ? 1 : 0
        let resumePage = offset ? 8 : 7
        let resumed = layout.pagination(pageCount: 12)
        let afterDiscovery = layout.pagination(pageCount: 12, widePages: [earlierWidePage])
        let anchor = resumed.anchor(for: resumePage)
        #expect(afterDiscovery.anchor(for: resumePage) == anchor)
        #expect(afterDiscovery.slots(start: anchor, reversed: false) == [resumePage - 1, resumePage])
    }

    @Test
    func `Wide pages also split spreads when pairing starts on page two`() {
        let pagination = shifted.pagination(pageCount: 5, widePages: [0, 2])
        #expect(pagination.starts(reversed: false) == [0, 1, 2, 3])
        #expect(pagination.slots(start: 0, reversed: false) == [0])
        #expect(pagination.slots(start: 1, reversed: false) == [1])
        #expect(pagination.slots(start: 2, reversed: false) == [2])
        #expect(pagination.slots(start: 3, reversed: false) == [3, 4])
        #expect(pagination.anchor(for: 2) == 2)
        #expect(pagination.anchor(for: 4) == 3)
    }

    @Test(arguments: [
        (size: CGSize(width: 701, height: 700), isWide: true),
        (size: CGSize(width: 700, height: 700), isWide: false),
        (size: CGSize(width: 699, height: 700), isWide: false),
    ])
    func `Only images wider than they are tall are wide`(example: (size: CGSize, isWide: Bool)) {
        #expect(ReaderLayout.isWideImage(example.size) == example.isWide)
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
