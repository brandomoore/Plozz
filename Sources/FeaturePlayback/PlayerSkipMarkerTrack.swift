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

    static func pattern(_ pattern: PlayerSkipMarkerPattern, in size: CGSize, slotHeight: CGFloat) -> Path {
        var path = Path()
        let centerY = size.height / 2
        switch pattern {
        case .diagonal, .mediumHatch, .fineHatch, .mesh:
            let spacing: CGFloat = pattern == .diagonal ? 16 : pattern == .mediumHatch ? 12 : 8
            for x in stride(from: CGFloat.zero, through: size.width + size.height, by: spacing) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x - size.height, y: size.height))
                if pattern == .mesh {
                    path.move(to: CGPoint(x: x - size.height, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                }
            }
            return path.strokedPath(StrokeStyle(lineWidth: pattern == .diagonal ? 2 : 1.5))
        case .denseDots:
            let rows = Int(ceil(slotHeight / 8))
            for row in -rows...rows {
                let stagger: CGFloat = row.isMultiple(of: 2) ? 0 : 3
                for x in stride(from: CGFloat(-6) + stagger, through: size.width, by: 6) {
                    // Pixel-centered small dots keep a solid core instead of a blurred speck.
                    path.addEllipse(in: CGRect(x: x + 0.5, y: centerY + CGFloat(row) * 4 - 0.5, width: 2, height: 2))
                }
            }
        }
        return path
    }
}

enum PlayerSkipMarkerPattern: String, CaseIterable, Sendable {
    case diagonal
    case denseDots
    case mediumHatch
    case fineHatch
    case mesh

    static let `default`: Self = .fineHatch
}

enum PlayerSkipMarkerTreatment: Equatable, Sendable {
    case cutout
    case halfCutout
    case hatchedCutout
    case halfHatchedCutout
    case segmented

    static let `default`: Self = .halfHatchedCutout

    var heightFraction: CGFloat {
        switch self {
        case .halfCutout, .halfHatchedCutout: 0.5
        case .cutout, .hatchedCutout: 0.75
        case .segmented: 1
        }
    }

    var hasHatch: Bool { self == .hatchedCutout || self == .halfHatchedCutout }
}

/// A shared alpha mask for skip annotations across all three progress fills.
struct PlayerSkipMarkerTrack: View, Equatable {
    let segments: [MediaSegment]
    let duration: TimeInterval
    let height: CGFloat
    var treatment: PlayerSkipMarkerTreatment = .default
    var pattern: PlayerSkipMarkerPattern = .default

    static let cutoutHeightFraction = PlayerSkipMarkerTreatment.default.heightFraction
    static let interiorFillOpacity = 0.06
    static let patternFillOpacity = 1.0

    var body: some View {
        let ranges = SkipMarkerTrackLayout.ranges(segments: segments, duration: duration)
        Canvas { context, size in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
            if treatment == .segmented {
                var mask = Path()
                for section in SkipMarkerTrackLayout.segmentedSections(ranges: ranges, size: size) {
                    let radius = min(section.width, section.height) / 2
                    mask.addRoundedRect(in: section, cornerSize: CGSize(width: radius, height: radius))
                }
                context.fill(mask, with: .color(.white))
                return
            }
            let cutouts = SkipMarkerTrackLayout.cutouts(
                ranges: ranges, size: size, heightFraction: treatment.heightFraction
            )
            var mask = Path(CGRect(origin: .zero, size: size))
            mask.addPath(cutouts)
            context.fill(mask, with: .color(.white), style: FillStyle(eoFill: true))
            if treatment.hasHatch, !ranges.isEmpty {
                context.clip(to: cutouts)
                context.fill(cutouts, with: .color(.white.opacity(Self.interiorFillOpacity)))
                // Opaque mask strokes retain the original material, not white paint.
                context.fill(
                    SkipMarkerTrackLayout.pattern(pattern, in: size, slotHeight: size.height * treatment.heightFraction),
                    with: .color(.white.opacity(Self.patternFillOpacity))
                )
            }
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#endif
