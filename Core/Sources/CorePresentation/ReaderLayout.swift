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

    package var usesSpreadOffset: Bool { usesSpread && pairsFromSecondPage }

    package func pagination(pageCount: Int, widePages: Set<Int> = []) -> Pagination {
        var starts: [Int] = []
        var spreadStarts: Set<Int> = []
        var page = 0
        while page < pageCount {
            starts.append(page)
            guard usesSpread, !(usesSpreadOffset && page == 0) else {
                page += 1
                continue
            }
            // Splitting a spread must not shift the pairing of later pages.
            if widePages.contains(page) || widePages.contains(page + 1) {
                if page + 1 < pageCount { starts.append(page + 1) }
            } else {
                spreadStarts.insert(page)
            }
            page += 2
        }
        return Pagination(pageCount: pageCount, starts: starts, spreadStarts: spreadStarts)
    }

    package struct Pagination: Equatable {
        let pageCount: Int
        let starts: [Int]
        let spreadStarts: Set<Int>

        package func starts(reversed: Bool) -> [Int] {
            reversed ? Array(starts.reversed()) : starts
        }

        package func slots(start: Int, reversed: Bool) -> [Int] {
            guard spreadStarts.contains(start) else { return [start] }
            return reversed ? [start + 1, start] : [start, start + 1]
        }

        package func anchor(for page: Int) -> Int {
            if page > 0 && page < pageCount && spreadStarts.contains(page - 1) { return page - 1 }
            return page
        }

        package func prefetchIndices(from page: Int) -> Range<Int> {
            let start = min(anchor(for: page), pageCount)
            let slotCount = spreadStarts.contains(start) ? 2 : 1
            return start..<min(start + slotCount + 3, pageCount)
        }
    }

    package static func isWideImage(_ image: CGSize) -> Bool {
        image.width > image.height
    }

    package static func isNarrowImage(_ image: CGSize, in slot: CGSize) -> Bool {
        guard image.width > 0, image.height > 0, slot.width > 0, slot.height > 0 else { return false }
        let widthAtSlotHeight = slot.height * (image.width / image.height)
        return widthAtSlotHeight <= slot.width / 4
    }
}
