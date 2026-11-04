#if canImport(SwiftUI)
import SwiftUI

/// Lays views out in equal-width cells that keep a fixed share of the container
/// until there is no room for it, then wrap and fill whatever is left.
///
/// The ratings row wants both halves of that. One rating stretched across the
/// full width of the Ratings column read as a mistake, a lone tile pretending to
/// be a table; sizing every tile to a quarter makes one rating look like one of
/// four, which is what it is. But a fixed quarter is wrong the moment the column
/// is narrow, because the tiles would shrink below legibility rather than use the
/// space, so the share is a preference and not a rule: below `minimumCellWidth`
/// the layout drops to as many columns as actually fit and divides the width
/// evenly between them.
///
/// A `LazyVGrid` cannot express this. Adaptive columns stretch to fill the row,
/// which is the behaviour being fixed, and a fixed column count cannot fall back
/// when the container is too narrow for it.
public struct ProportionalWrapLayout: Layout {
    /// How many cells make up a full row at full width. Every cell is 1/this of
    /// the container, so a partial row occupies a proportional share of it.
    public var preferredColumns: Int
    /// Below this, the preferred share is abandoned in favour of fewer columns.
    public var minimumCellWidth: CGFloat
    public var spacing: CGFloat
    public var rowSpacing: CGFloat?
    /// Let a trailing information/action tile complete the final row.
    public var lastSubviewFillsRemainingColumns: Bool
    public var fillsProposedHeight: Bool
    /// A floor on the layout's own height, so it can be made to match a sibling
    /// column without depending on the container stretching it. Rows divide any
    /// surplus between them, so the tiles grow rather than leaving a gap.
    ///
    /// This is deliberately an input rather than a `.frame(maxHeight: .infinity)`
    /// on the outside: a `Grid` only stretches a cell it has decided is flexible,
    /// which is exactly the behaviour that could not be made to hold on tvOS.
    /// Reporting the target as the layout's *natural* height removes the question.
    public var minimumHeight: CGFloat

    public init(
        preferredColumns: Int,
        minimumCellWidth: CGFloat,
        spacing: CGFloat,
        minimumHeight: CGFloat = 0,
        rowSpacing: CGFloat? = nil,
        lastSubviewFillsRemainingColumns: Bool = false,
        fillsProposedHeight: Bool = false
    ) {
        self.preferredColumns = max(1, preferredColumns)
        self.minimumCellWidth = max(1, minimumCellWidth)
        self.spacing = max(0, spacing)
        self.minimumHeight = max(0, minimumHeight)
        self.rowSpacing = rowSpacing.map { max(0, $0) }
        self.lastSubviewFillsRemainingColumns = lastSubviewFillsRemainingColumns
        self.fillsProposedHeight = fillsProposedHeight
    }

    /// Columns that fit, and the width each one gets.
    private func metrics(forWidth width: CGFloat) -> (columns: Int, cellWidth: CGFloat) {
        guard width > 0 else { return (1, minimumCellWidth) }
        let preferredWidth = (width - spacing * CGFloat(preferredColumns - 1))
            / CGFloat(preferredColumns)
        if preferredWidth >= minimumCellWidth {
            return (preferredColumns, preferredWidth)
        }
        // Too narrow for the preferred share: fit what we can and divide evenly,
        // so the row fills the container instead of leaving a ragged gap.
        let fitting = max(1, Int((width + spacing) / (minimumCellWidth + spacing)))
        let columns = min(preferredColumns, fitting)
        let cellWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return (columns, cellWidth)
    }

    public func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? minimumCellWidth * CGFloat(preferredColumns)
        let (columns, cellWidth) = metrics(forWidth: width)
        let heights = rowHeights(subviews, columns: columns, cellWidth: cellWidth)
        let natural = heights.reduce(0, +) + (rowSpacing ?? spacing) * CGFloat(max(0, heights.count - 1))
        // Natural-size probes stay intrinsic; only opt-in layouts fill an
        // explicitly allocated height, without geometry-preference feedback.
        let allocatedHeight = fillsProposedHeight ? proposal.height ?? 0 : 0
        return CGSize(width: width, height: max(natural, minimumHeight, allocatedHeight))
    }

    public func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        guard !subviews.isEmpty else { return }
        let (columns, cellWidth) = metrics(forWidth: bounds.width)
        let heights = rowHeights(subviews, columns: columns, cellWidth: cellWidth)
        let gap = rowSpacing ?? spacing
        let natural = heights.reduce(0, +) + gap * CGFloat(max(0, heights.count - 1))
        let surplus = max(0, bounds.height - natural) / CGFloat(heights.count)
        var rowY = bounds.minY
        for (index, subview) in subviews.enumerated() {
            let column = index % columns
            let row = index / columns
            if column == 0, row > 0 { rowY += heights[row - 1] + surplus + gap }
            let rowHeight = heights[row] + surplus
            let width = itemWidth(at: index, count: subviews.count, columns: columns, cellWidth: cellWidth)
            let origin = CGPoint(
                x: bounds.minX + CGFloat(column) * (cellWidth + spacing),
                y: rowY
            )
            subview.place(
                at: origin,
                proposal: ProposedViewSize(width: width, height: rowHeight)
            )
        }
    }

    private func rowHeights(_ subviews: Subviews, columns: Int, cellWidth: CGFloat) -> [CGFloat] {
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + columns - 1) / columns)
        for (index, subview) in subviews.enumerated() {
            let width = itemWidth(at: index, count: subviews.count, columns: columns, cellWidth: cellWidth)
            let height = subview.sizeThatFits(.init(width: width, height: nil)).height
            heights[index / columns] = max(heights[index / columns], height)
        }
        return heights
    }

    private func itemWidth(at index: Int, count: Int, columns: Int, cellWidth: CGFloat) -> CGFloat {
        let span = lastSubviewFillsRemainingColumns && index == count - 1 ? columns - index % columns : 1
        return CGFloat(span) * cellWidth + CGFloat(span - 1) * spacing
    }
}
#endif
