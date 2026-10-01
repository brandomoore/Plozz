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

/// An alpha mask that cuts a centered slot through all three progress fills.
struct PlayerSkipMarkerTrack: View, Equatable {
    let segments: [MediaSegment]
    let duration: TimeInterval
    let height: CGFloat

    static let cutoutHeightFraction: CGFloat = 0.75

    var body: some View {
        let ranges = SkipMarkerTrackLayout.ranges(segments: segments, duration: duration)
        Canvas { context, size in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
            var mask = Path(CGRect(origin: .zero, size: size))
            let cutoutHeight = size.height * Self.cutoutHeightFraction
            let inset = (size.height - cutoutHeight) / 2
            for range in ranges {
                // Preserve the track's end caps when a marker touches 0 or duration.
                let start = max(inset, size.width * CGFloat(range.lowerBound))
                let end = min(size.width - inset, size.width * CGFloat(range.upperBound))
                guard end > start else { continue }
                mask.addRoundedRect(
                    in: CGRect(x: start, y: inset, width: end - start, height: cutoutHeight),
                    cornerSize: CGSize(width: cutoutHeight / 2, height: cutoutHeight / 2)
                )
            }
            context.fill(mask, with: .color(.white), style: FillStyle(eoFill: true))
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
