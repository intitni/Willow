import SwiftUI

/// Measures each tag at its natural width and starts a new row when needed.
struct WrappingTagLayout: Layout {
    var spacing: CGFloat = 8

    private struct Placement {
        let origin: CGPoint
        let size: CGSize
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (CGSize, [Placement]) {
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            placements.append(Placement(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: usedWidth, height: y + rowHeight), placements)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: max(0, proposal.width ?? .infinity)).0
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = arrange(subviews, width: bounds.width).1
        for (subview, placement) in zip(subviews, placements) {
            subview.place(at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                          anchor: .topLeading, proposal: ProposedViewSize(placement.size))
        }
    }
}
