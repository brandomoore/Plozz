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

enum PlayerSkipMarkerTreatment: Equatable, Sendable {
    case cutout
    case halfCutout
    case hatchedCutout
    case halfHatchedCutout

    var heightFraction: CGFloat {
        switch self {
        case .halfCutout, .halfHatchedCutout: 0.5
        case .cutout, .hatchedCutout: 0.75
        }
    }

    var hasHatch: Bool { self == .hatchedCutout || self == .halfHatchedCutout }
}

/// An alpha mask that cuts a centered slot through all three progress fills.
struct PlayerSkipMarkerTrack: View, Equatable {
    let segments: [MediaSegment]
    let duration: TimeInterval
    let height: CGFloat
    var treatment: PlayerSkipMarkerTreatment = .cutout

    static let cutoutHeightFraction = PlayerSkipMarkerTreatment.cutout.heightFraction
    static let interiorFillOpacity = 0.06
    static let hatchFillOpacity = 0.5

    var body: some View {
        let ranges = SkipMarkerTrackLayout.ranges(segments: segments, duration: duration)
        Canvas { context, size in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
            var cutouts = Path()
            let cutoutHeight = size.height * treatment.heightFraction
            let inset = (size.height - cutoutHeight) / 2
            for range in ranges {
                // Preserve the track's end caps when a marker touches 0 or duration.
                let start = max(inset, size.width * CGFloat(range.lowerBound))
                let end = min(size.width - inset, size.width * CGFloat(range.upperBound))
                guard end > start else { continue }
                cutouts.addRoundedRect(
                    in: CGRect(x: start, y: inset, width: end - start, height: cutoutHeight),
                    cornerSize: CGSize(width: cutoutHeight / 2, height: cutoutHeight / 2)
                )
            }
            var mask = Path(CGRect(origin: .zero, size: size))
            mask.addPath(cutouts)
            context.fill(mask, with: .color(.white), style: FillStyle(eoFill: true))
            if treatment.hasHatch, !ranges.isEmpty {
                context.clip(to: cutouts)
                context.fill(cutouts, with: .color(.white.opacity(Self.interiorFillOpacity)))
                var stripes = Path()
                for x in stride(from: CGFloat.zero, through: size.width + size.height, by: 16) {
                    stripes.move(to: CGPoint(x: x, y: 0))
                    stripes.addLine(to: CGPoint(x: x - size.height, y: size.height))
                }
                context.stroke(stripes, with: .color(.white.opacity(Self.hatchFillOpacity)), lineWidth: 2)
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
