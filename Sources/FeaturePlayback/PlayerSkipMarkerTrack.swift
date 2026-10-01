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
}

/// A static tonal cut over all three progress fills, beneath the playhead.
struct PlayerSkipMarkerTrack: View, Equatable {
    let segments: [MediaSegment]
    let duration: TimeInterval
    let height: CGFloat

    static let spacing: CGFloat = 16
    static let lineWidth: CGFloat = 2
    static let opacity = 0.24

    var body: some View {
        let ranges = SkipMarkerTrackLayout.ranges(segments: segments, duration: duration)
        Canvas { context, size in
            guard !ranges.isEmpty, size.width.isFinite, size.width > 0, size.height > 0 else { return }
            var mask = Path()
            for range in ranges {
                mask.addRect(CGRect(
                    x: size.width * CGFloat(range.lowerBound), y: 0,
                    width: size.width * CGFloat(range.upperBound - range.lowerBound), height: size.height
                ))
            }
            context.clip(to: mask)
            var stripes = Path()
            // Anchor phase to the track, not each segment or the live playhead.
            for x in stride(from: CGFloat.zero, through: size.width + size.height, by: Self.spacing) {
                stripes.move(to: CGPoint(x: x, y: 0))
                stripes.addLine(to: CGPoint(x: x - size.height, y: size.height))
            }
            context.stroke(stripes, with: .color(.black.opacity(Self.opacity)), lineWidth: Self.lineWidth)
        }
        .frame(height: height)
        .clipShape(Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
