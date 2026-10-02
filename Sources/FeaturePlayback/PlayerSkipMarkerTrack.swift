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

    static func segmentedSections(ranges: [Range<Double>], size: CGSize) -> [CGRect] {
        var boundaries: [CGFloat] = [0]
        for range in ranges {
            for fraction in [range.lowerBound, range.upperBound] where fraction > 0 && fraction < 1 {
                boundaries.append(size.width * CGFloat(fraction))
            }
        }
        boundaries.append(size.width)
        let halfGaps = boundaries.indices.map { index -> CGFloat in
            guard index > 0, index < boundaries.count - 1 else { return 0 }
            // Keep gaps centered on their time boundary without consuming tiny sections.
            return min(2, min(
                (boundaries[index] - boundaries[index - 1]) / 4,
                (boundaries[index + 1] - boundaries[index]) / 4
            ))
        }
        return boundaries.indices.dropLast().map { index in
            let start = boundaries[index] + halfGaps[index]
            let end = boundaries[index + 1] - halfGaps[index + 1]
            return CGRect(x: start, y: 0, width: end - start, height: size.height)
        }
    }
}

/// Splits all three progress fills into rounded sections at skip boundaries.
struct PlayerSkipMarkerTrack: View, Equatable {
    let segments: [MediaSegment]
    let duration: TimeInterval
    let height: CGFloat

    var body: some View {
        let ranges = SkipMarkerTrackLayout.ranges(segments: segments, duration: duration)
        Canvas { context, size in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
            var mask = Path()
            for section in SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size) {
                let radius = min(section.width, section.height) / 2
                mask.addRoundedRect(in: section, cornerSize: CGSize(width: radius, height: radius))
            }
            context.fill(mask, with: .color(.white))
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#endif
