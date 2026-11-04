import CoreModels
import SwiftUI

public struct SeasonEpisodeRowContent<Artwork: View, Status: View, Accessory: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let number: Int?
    private let title: String? // l10n:content - provider-supplied episode title
    private let reservesStatusSpace: Bool
    private let artwork: Artwork
    private let status: Status
    private let accessory: Accessory

    public init(
        number: Int?,
        title: String?, // l10n:content — episode title, nil when spoiler-protected
        reservesStatusSpace: Bool = false,
        @ViewBuilder artwork: () -> Artwork,
        @ViewBuilder status: () -> Status,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.number = number
        self.title = title
        self.reservesStatusSpace = reservesStatusSpace
        self.artwork = artwork()
        self.status = status()
        self.accessory = accessory()
    }

    public var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            artwork
            VStack(alignment: .leading, spacing: 3) {
                if let title, !title.isEmpty {
                    if let number {
                        Text("Episode \(number)")
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    Text(verbatim: title)
                        .foregroundStyle(Color.primary)
                } else if let number {
                    Text("Episode \(number)")
                        .foregroundStyle(Color.primary)
                } else {
                    Text("Episode")
                        .foregroundStyle(Color.primary)
                }
                ZStack(alignment: .topLeading) {
                    if reservesStatusSpace {
                        Text(verbatim: " ")
                            .hidden()
                            .accessibilityHidden(true)
                    }
                    status
                }
                .lineLimit(reservesStatusSpace && !dynamicTypeSize.isAccessibilitySize ? 1 : nil)
                .font(.caption)
                .foregroundStyle(Color.secondary)
            }
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct SeasonEpisodeRowArtwork<Content: View>: View {
    private let content: Content
    private let showsMediaEdge: Bool

    public init(showsMediaEdge: Bool = true, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.showsMediaEdge = showsMediaEdge
    }

    public var body: some View {
        content
            .frame(width: 80, height: 45)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .plozzMediaEdge(cornerRadius: 6, isEnabled: showsMediaEdge)
            .accessibilityHidden(true)
    }
}

public struct SeasonEpisodeAvailabilityLabel: View {
    @ScaledMetric(relativeTo: .caption) private var iconWidth: CGFloat = 14
    private let availability: SeasonEpisodeAvailability
    private let airDate: Date?
    private let calendarDayStoredInUTC: Bool
    private let title: LocalizedStringResource?

    public init(
        availability: SeasonEpisodeAvailability,
        airDate: Date? = nil,
        calendarDayStoredInUTC: Bool = true,
        title: LocalizedStringResource? = nil
    ) {
        self.availability = availability
        self.airDate = airDate
        self.calendarDayStoredInUTC = calendarDayStoredInUTC
        self.title = title
    }

    public var body: some View {
        if availability != .inLibrary || title != nil {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: availability.systemImage)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                if let title {
                    Text(title)
                } else if availability == .unaired, let airDate {
                    Text(
                        "Releases \(airDate, format: Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendarDayStoredInUTC ? .gmt : .current))"
                    )
                } else {
                    Text(availability.title)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }
}
