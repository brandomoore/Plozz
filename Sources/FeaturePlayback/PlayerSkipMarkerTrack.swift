#if canImport(SwiftUI)
import CoreModels
import CoreNetworking
import SwiftUI

enum SkipMarkerTrackLayout {
    static func ranges(segments: [MediaSegment], duration: TimeInterval) -> [Range<Double>] {
        guard duration.isFinite, duration > 0 else { return [] }
        var malformed = 0
        let ranges = segments.compactMap { segment -> Range<Double>? in
            guard segment.isSkippable else { return nil }
            guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start else {
                malformed += 1
                return nil
            }
            let start = max(0, segment.start)
            let end = min(duration, segment.end)
            guard start < end else { return nil }
            return (start / duration)..<(end / duration)
        }.sorted { $0.lowerBound < $1.lowerBound }
        if malformed > 0 {
            PlozzLog.app.debug("Ignored \(malformed) skip-marker range(s) with invalid timing")
        }
        var merged: [Range<Double>] = []
        for range in ranges {
            if let previous = merged.last, range.lowerBound <= previous.upperBound {
                merged[merged.count - 1] = previous.lowerBound..<max(previous.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    static func segmentedSections(
        ranges: [Range<Double>], size: CGSize, minimumSectionWidth: CGFloat = 0,
        restingHeight: CGFloat? = nil, omitShortRanges: Bool = false
    ) -> [CGRect] {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return [] }
        let maximumHalfGap: CGFloat = 2
        let minimumInterval = minimumSectionWidth + 2 * maximumHalfGap
        var boundaries: [CGFloat] = [0]
        for range in ranges {
            // Discard unreadable skip windows before measuring the remaining gaps.
            // Otherwise a tiny window can erase the start of a long credits section.
            if omitShortRanges, minimumSectionWidth > 0,
               size.width * CGFloat(range.upperBound) - size.width * CGFloat(range.lowerBound) < minimumInterval {
                continue
            }
            for fraction in [range.lowerBound, range.upperBound] where fraction > 0 && fraction < 1 {
                boundaries.append(size.width * CGFloat(fraction))
            }
        }
        boundaries.append(size.width)
        if minimumSectionWidth > 0 {
            // Inspect the remaining neighbors, including unmarked intervals. Removing
            // both cuts around a tiny piece avoids replacing it with a misleading
            // enlarged segment or a cut through its center.
            boundaries = boundaries.indices.compactMap { index in
                guard index > 0, index < boundaries.count - 1 else { return boundaries[index] }
                guard boundaries[index] - boundaries[index - 1] >= minimumInterval,
                      boundaries[index + 1] - boundaries[index] >= minimumInterval else { return nil }
                return boundaries[index]
            }
        }
        let halfGaps = boundaries.indices.map { index -> CGFloat in
            guard index > 0, index < boundaries.count - 1 else { return 0 }
            // Keep gaps centered on their time boundary without consuming tiny sections.
            return min(maximumHalfGap, min(
                (boundaries[index] - boundaries[index - 1]) / 4,
                (boundaries[index + 1] - boundaries[index]) / 4
            ))
        }
        let sections = boundaries.indices.dropLast().map { index in
            let start = boundaries[index] + halfGaps[index]
            let end = boundaries[index + 1] - halfGaps[index + 1]
            return CGRect(x: start, y: 0, width: end - start, height: size.height)
        }
        guard let restingHeight else { return sections }
        let maximumExtraGap = min(2, 1 + max(0, size.height - restingHeight) / 8)
        var spaced = sections
        for index in sections.indices.dropLast() {
            let left = sections[index]
            let right = sections[index + 1]
            let wider = max(left.width, right.width)
            let narrower = min(left.width, right.width)
            let corner = cornerSize(sectionWidth: wider, neighborWidth: narrower, height: size.height)
            // Add optical space only on the wider side; leave fully rounded joins alone.
            let extra = min(
                maximumExtraGap, size.height / 2 - corner.width,
                wider / 4, (wider - narrower) / 2
            )
            if left.width < right.width {
                spaced[index + 1].origin.x += extra
                spaced[index + 1].size.width -= extra
            } else if right.width < left.width {
                spaced[index].size.width -= extra
            }
        }
        return spaced
    }

    static func cornerSize(
        sectionWidth: CGFloat, neighborWidth: CGFloat, height: CGFloat, referenceHeight: CGFloat? = nil
    ) -> CGSize {
        let availableRadius = min(sectionWidth, neighborWidth) / 2 * 1.25
        let radius = min(height / 2, availableRadius)
        let reference = referenceHeight ?? height
        // Grow the vertical curve with focus instead of stretching a nearly square middle.
        let verticalRadius = min(reference / 2, availableRadius) * (height / reference)
        let extra = sectionWidth > neighborWidth
            ? min(1.5, max(0, height - reference) * 3 / 16, (sectionWidth - neighborWidth) / 2)
            : 0
        return CGSize(
            width: min(sectionWidth / 2, height / 2, radius + extra),
            height: min(height / 2, verticalRadius + extra)
        )
    }

    static func maskPath(
        ranges: [Range<Double>], size: CGSize, minimumSectionWidth: CGFloat = 0,
        restingHeight: CGFloat? = nil, omitShortRanges: Bool = false
    ) -> Path {
        let sections = segmentedSections(
            ranges: ranges, size: size, minimumSectionWidth: minimumSectionWidth,
            restingHeight: restingHeight, omitShortRanges: omitShortRanges
        )
        var mask = Path()
        for index in sections.indices {
            let section = sections[index]
            let outer = cornerSize(
                sectionWidth: section.width, neighborWidth: section.width,
                height: section.height, referenceHeight: restingHeight
            )
            let leading = index == 0 ? outer : cutCornerSize(
                section: section, neighbor: sections[index - 1]
            )
            let trailing = index == sections.count - 1 ? outer : cutCornerSize(
                section: section, neighbor: sections[index + 1]
            )
            if leading == trailing {
                mask.addRoundedRect(in: section, cornerSize: leading)
            } else {
                mask.addPath(sectionPath(section, leading: leading, trailing: trailing))
            }
        }
        return mask
    }

    private static func cutCornerSize(section: CGRect, neighbor: CGRect) -> CGSize {
        let radius = min(3, section.height / 2, section.width / 2, neighbor.width / 2)
        return CGSize(width: radius, height: radius)
    }

    private static func sectionPath(_ rect: CGRect, leading: CGSize, trailing: CGSize) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + leading.width, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - trailing.width, y: rect.minY))
        path.addArc(
            center: .zero, radius: 1, startAngle: .degrees(-90), endAngle: .zero, clockwise: false,
            transform: CGAffineTransform(
                a: trailing.width, b: 0, c: 0, d: trailing.height,
                tx: rect.maxX - trailing.width, ty: rect.minY + trailing.height
            )
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - trailing.height))
        path.addArc(
            center: .zero, radius: 1, startAngle: .zero, endAngle: .degrees(90), clockwise: false,
            transform: CGAffineTransform(
                a: trailing.width, b: 0, c: 0, d: trailing.height,
                tx: rect.maxX - trailing.width, ty: rect.maxY - trailing.height
            )
        )
        path.addLine(to: CGPoint(x: rect.minX + leading.width, y: rect.maxY))
        path.addArc(
            center: .zero, radius: 1, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false,
            transform: CGAffineTransform(
                a: leading.width, b: 0, c: 0, d: leading.height,
                tx: rect.minX + leading.width, ty: rect.maxY - leading.height
            )
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + leading.height))
        path.addArc(
            center: .zero, radius: 1, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false,
            transform: CGAffineTransform(
                a: leading.width, b: 0, c: 0, d: leading.height,
                tx: rect.minX + leading.width, ty: rect.minY + leading.height
            )
        )
        path.closeSubpath()
        return path
    }
}

/// Splits all three progress fills at legible skip boundaries without changing timing.
struct PlayerSkipMarkerTrack: View, Equatable {
    let segments: [MediaSegment]
    let duration: TimeInterval
    let height: CGFloat
    var minimumSectionWidth: CGFloat = 0
    var restingHeight: CGFloat? = nil

    var body: some View {
        let ranges = SkipMarkerTrackLayout.ranges(segments: segments, duration: duration)
        Canvas { context, size in
            let mask = SkipMarkerTrackLayout.maskPath(
                ranges: ranges, size: size, minimumSectionWidth: minimumSectionWidth,
                restingHeight: restingHeight, omitShortRanges: true
            )
            context.fill(mask, with: .color(.white))
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#endif
