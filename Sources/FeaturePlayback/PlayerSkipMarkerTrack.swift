#if canImport(SwiftUI)
import CoreModels
import CoreNetworking
import CoreUI
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

    static func cutouts(ranges: [Range<Double>], size: CGSize, heightFraction: CGFloat) -> Path {
        var path = Path()
        let cutoutHeight = size.height * heightFraction
        let inset = (size.height - cutoutHeight) / 2
        for range in ranges {
            // Preserve the track's end caps when a marker touches 0 or duration.
            let start = max(inset, size.width * CGFloat(range.lowerBound))
            let end = min(size.width - inset, size.width * CGFloat(range.upperBound))
            guard end > start else { continue }
            path.addRoundedRect(
                in: CGRect(x: start, y: inset, width: end - start, height: cutoutHeight),
                cornerSize: CGSize(width: cutoutHeight / 2, height: cutoutHeight / 2)
            )
        }
        return path
    }

    static func hatch(in size: CGSize) -> Path {
        var path = Path()
        for x in stride(from: CGFloat.zero, through: size.width + size.height, by: 16) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x - size.height, y: size.height))
        }
        return path
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
            let cutouts = SkipMarkerTrackLayout.cutouts(
                ranges: ranges, size: size, heightFraction: treatment.heightFraction
            )
            var mask = Path(CGRect(origin: .zero, size: size))
            mask.addPath(cutouts)
            context.fill(mask, with: .color(.white), style: FillStyle(eoFill: true))
            if treatment.hasHatch, !ranges.isEmpty {
                context.clip(to: cutouts)
                context.fill(cutouts, with: .color(.white.opacity(Self.interiorFillOpacity)))
                context.stroke(SkipMarkerTrackLayout.hatch(in: size),
                               with: .color(.white.opacity(Self.hatchFillOpacity)), lineWidth: 2)
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Native glass can be nearly clear ahead of playback; retain a little stroke
/// contrast there without brightening the whole slot or changing the flat track.
struct PlayerSkipMarkerUnplayedHighlight: View, Equatable {
    let segments: [MediaSegment]
    let duration: TimeInterval
    let height: CGFloat
    let treatment: PlayerSkipMarkerTreatment
    let progressFraction: Double

    static let opacity = 0.18
    @Environment(\.plozzReducePanelGlass) private var reducePanelGlass

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.segments == rhs.segments && lhs.duration == rhs.duration
            && lhs.height == rhs.height && lhs.treatment == rhs.treatment
            && lhs.progressFraction == rhs.progressFraction
    }

    var body: some View {
        if #available(iOS 26.0, tvOS 26.0, *), !reducePanelGlass, treatment.hasHatch {
            let ranges = SkipMarkerTrackLayout.ranges(segments: segments, duration: duration)
            Canvas { context, size in
                guard !ranges.isEmpty, progressFraction.isFinite,
                      size.width.isFinite, size.height.isFinite,
                      size.width > 0, size.height > 0 else { return }
                let start = size.width * CGFloat(min(1, max(0, progressFraction)))
                guard start < size.width else { return }
                context.clip(to: SkipMarkerTrackLayout.cutouts(
                    ranges: ranges, size: size, heightFraction: treatment.heightFraction
                ))
                context.clip(to: Path(CGRect(x: start, y: 0, width: size.width - start, height: size.height)))
                context.stroke(SkipMarkerTrackLayout.hatch(in: size),
                               with: .color(.white.opacity(Self.opacity)), lineWidth: 2)
            }
            .frame(height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
#endif
