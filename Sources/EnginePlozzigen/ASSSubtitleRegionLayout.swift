import CoreGraphics
import CoreModels

/// Only clearly separated edge artwork is movable. Layer order is preserved
/// within each region; a center/crossing layer keeps the entire frame authored.
struct ASSSubtitleRegionLayout {
    struct Region {
        let indices: [Int]
        let bounds: CGRect
        let avoidance: SubtitleImage.ControlAvoidance
    }

    private var separated = false
    private var lowerEnvelope = CGRect.null
    private var upperEnvelope = CGRect.null

    mutating func regions(for rectangles: [CGRect], canvas: CGSize) -> [Region] {
        guard !rectangles.isEmpty else { self = .init(); return [] }
        let all = rectangles.reduce(CGRect.null) { $0.union($1) }
        let topLimit = canvas.height * (separated ? 0.48 : 0.4)
        let bottomLimit = canvas.height * (separated ? 0.52 : 0.6)
        let top = rectangles.indices.filter { rectangles[$0].maxY <= topLimit }
        let bottom = rectangles.indices.filter { rectangles[$0].minY >= bottomLimit }
        let topBounds = top.reduce(CGRect.null) { $0.union(rectangles[$1]) }
        let bottomBounds = bottom.reduce(CGRect.null) { $0.union(rectangles[$1]) }
        let clearGap = top.isEmpty || bottomBounds.minY - topBounds.maxY >= canvas.height * 0.12
        guard !bottom.isEmpty, top.count + bottom.count == rectangles.count, clearGap else {
            self = .init()
            return [.init(indices: Array(rectangles.indices), bounds: all, avoidance: .fixed)]
        }

        separated = true
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let padding = canvas.height * 0.02
        // Small animated glyph/blur changes stay inside the same clearance box.
        // A disjoint replacement or blank frame starts a fresh envelope.
        if !lowerEnvelope.isNull, !lowerEnvelope.intersects(bottomBounds) {
            lowerEnvelope = .null
            upperEnvelope = .null
        }
        if !lowerEnvelope.contains(bottomBounds) {
            lowerEnvelope = lowerEnvelope.union(bottomBounds.insetBy(dx: 0, dy: -padding).intersection(canvasRect))
        }
        if !top.isEmpty, !upperEnvelope.contains(topBounds) {
            upperEnvelope = upperEnvelope.union(topBounds.insetBy(dx: 0, dy: -padding).intersection(canvasRect))
        }
        let minimumY = upperEnvelope.isNull ? 0 : (upperEnvelope.maxY + padding) / canvas.height
        let normalizedEnvelope = CGRect(
            x: lowerEnvelope.minX / canvas.width, y: lowerEnvelope.minY / canvas.height,
            width: lowerEnvelope.width / canvas.width, height: lowerEnvelope.height / canvas.height
        )
        var result: [Region] = []
        if !top.isEmpty { result.append(.init(indices: top, bounds: topBounds, avoidance: .fixed)) }
        result.append(.init(
            indices: bottom, bounds: bottomBounds,
            avoidance: .lowerRegion(envelope: normalizedEnvelope, minimumY: minimumY)
        ))
        return result
    }
}
