import Foundation

/// Reading layout depends on the full canvas, never on toolbar visibility.
package struct ReaderLayout {
    package let viewport: CGSize
    private let horizontalReading: Bool
    private let spreadsEnabled: Bool
    private let regularWidth: Bool
    private let pairsFromSecondPage: Bool

    package init(viewport: CGSize, horizontalReading: Bool, spreadsEnabled: Bool,
                 regularWidth: Bool, pairsFromSecondPage: Bool = false) {
        self.viewport = viewport
        self.horizontalReading = horizontalReading
        self.spreadsEnabled = spreadsEnabled
        self.regularWidth = regularWidth
        self.pairsFromSecondPage = pairsFromSecondPage
    }

    package var usesSpread: Bool {
        horizontalReading && spreadsEnabled && regularWidth && viewport.width > viewport.height
    }

    private var groupSize: Int { usesSpread ? 2 : 1 }
    package var usesSpreadOffset: Bool { usesSpread && pairsFromSecondPage }

    package func starts(pageCount: Int, reversed: Bool) -> [Int] {
        let firstPair = usesSpreadOffset ? 1 : 0
        var starts = Array(stride(from: firstPair, to: pageCount, by: groupSize))
        if usesSpreadOffset && pageCount > 0 { starts.insert(0, at: 0) }
        return reversed ? Array(starts.reversed()) : starts
    }

    package func slots(start: Int, reversed: Bool) -> [Int] {
        if usesSpreadOffset && start == 0 { return [0] }
        let slots = Array(start..<(start + groupSize))
        return reversed ? Array(slots.reversed()) : slots
    }

    package func anchor(for page: Int) -> Int {
        let firstPair = usesSpreadOffset && page > 0 ? 1 : 0
        return page - (page - firstPair) % groupSize
    }

    package func prefetchIndices(from page: Int, pageCount: Int) -> Range<Int> {
        let start = min(anchor(for: page), pageCount)
        return start..<min(start + groupSize + 3, pageCount)
    }

    package static func isNarrowImage(_ image: CGSize, in slot: CGSize) -> Bool {
        guard image.width > 0, image.height > 0, slot.width > 0, slot.height > 0 else { return false }
        let widthAtSlotHeight = slot.height * (image.width / image.height)
        return widthAtSlotHeight <= slot.width / 4
    }
}
