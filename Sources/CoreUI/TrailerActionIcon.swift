#if canImport(SwiftUI)
import CoreModels
import SwiftUI

public struct TrailerActionButtonLabel: View {
    public let trailer: MediaItem?

    public init(trailer: MediaItem?) {
        self.trailer = trailer
    }

    public var body: some View {
        Label {
            Text(trailer?.trailerActionTitle ?? LocalizedStringResource("Trailer"))
        } icon: {
            TrailerActionIcon(isExternal: trailer?.isYouTubeTrailer == true)
        }
        .labelStyle(.iconOnly)
    }
}

public struct TrailerActionIcon: View {
    public let isExternal: Bool
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 19

    public init(isExternal: Bool) {
        self.isExternal = isExternal
    }

    public var body: some View {
        Image(systemName: "film.fill")
            .font(.system(size: size, weight: .semibold))
            .overlay(alignment: .topTrailing) {
                if isExternal {
                    arrow(lineWidth: 7.5)
                        .foregroundStyle(.white)
                        .blendMode(.destinationOut)
                }
            }
            .compositingGroup()
            .overlay(alignment: .topTrailing) {
                if isExternal { arrow(lineWidth: 2) }
            }
            .accessibilityHidden(true)
    }

    private func arrow(lineWidth: CGFloat) -> some View {
        TrailerDepartureArrow()
            .stroke(style: StrokeStyle(
                lineWidth: lineWidth * size / 19,
                lineCap: .round,
                lineJoin: .round
            ))
            .frame(width: 12 * size / 19, height: 12 * size / 19)
            .scaleEffect(10.0 / 12.0, anchor: .bottomLeading)
            .offset(y: -1.5 * size / 19)
    }
}

private struct TrailerDepartureArrow: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = rect.width / 12
        return Path { path in
            path.move(to: CGPoint(x: unit, y: rect.maxY - unit))
            path.addLine(to: CGPoint(x: rect.maxX - unit, y: unit))
            path.addLine(to: CGPoint(x: 5 * unit, y: unit))
            path.move(to: CGPoint(x: rect.maxX - unit, y: unit))
            path.addLine(to: CGPoint(x: rect.maxX - unit, y: rect.maxY - 5 * unit))
        }
    }
}
#endif
