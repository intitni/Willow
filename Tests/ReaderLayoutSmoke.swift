import Foundation

@main
struct ReaderLayoutSmoke {
    static func main() {
        func layout(_ width: CGFloat, _ height: CGFloat, horizontal: Bool = true, enabled: Bool = true, regularWidth: Bool = true) -> ReaderLayout {
            ReaderLayout(viewport: CGSize(width: width, height: height), horizontalReading: horizontal, spreadsEnabled: enabled, regularWidth: regularWidth)
        }
        for size in [CGSize(width: 393, height: 852), CGSize(width: 440, height: 956),
                     CGSize(width: 700, height: 980), CGSize(width: 900, height: 1200), CGSize(width: 800, height: 800)] {
            precondition(!layout(size.width, size.height).usesSpread, "Portrait and square canvases must remain single page")
        }
        precondition(!layout(1000, 700, regularWidth: false).usesSpread)
        precondition(layout(650, 400, regularWidth: true).usesSpread)
        precondition(!layout(1000, 700, horizontal: false).usesSpread)
        precondition(!layout(1000, 700, enabled: false).usesSpread)
        let spread = layout(1000, 700)
        precondition(spread.usesSpread)
        precondition(spread.starts(pageCount: 5, reversed: false) == [0, 2, 4])
        precondition(spread.starts(pageCount: 5, reversed: true) == [4, 2, 0])
        precondition(spread.slots(start: 4, reversed: false) == [4, 5])
        precondition(spread.slots(start: 4, reversed: true) == [5, 4])
        precondition(spread.anchor(for: 3) == 2)
        precondition(layout(700, 1000).anchor(for: 3) == 3)
        precondition(spread.starts(pageCount: 0, reversed: false).isEmpty)
        print("PASS: portrait/square single page, regular-width horizontal spreads, RTL order, odd-page blank slot and resize anchors")
    }
}
