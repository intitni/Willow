import Foundation

/// Reading layout depends on the full canvas, never on toolbar visibility.
struct ReaderLayout {
    let viewport: CGSize
    let horizontalReading: Bool
    let spreadsEnabled: Bool
    let regularWidth: Bool

    var usesSpread: Bool {
        horizontalReading && spreadsEnabled && regularWidth && viewport.width > viewport.height
    }

    var groupSize: Int { usesSpread ? 2 : 1 }

    func starts(pageCount: Int, reversed: Bool) -> [Int] {
        let starts = Array(stride(from: 0, to: pageCount, by: groupSize))
        return reversed ? Array(starts.reversed()) : starts
    }

    func slots(start: Int, reversed: Bool) -> [Int] {
        let slots = Array(start..<(start + groupSize))
        return reversed ? Array(slots.reversed()) : slots
    }

    func anchor(for page: Int) -> Int { page - page % groupSize }

    func prefetchIndices(from page: Int, pageCount: Int) -> Range<Int> {
        let start = min(anchor(for: page), pageCount)
        return start..<min(start + groupSize + 3, pageCount)
    }
}
