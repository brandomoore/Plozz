import Foundation

/// The guide's view of what a channel is airing, reduced to what the player draws.
///
/// Lives here rather than in the guide module so the player can show programme
/// details without depending on the guide, and the guide can hand them over
/// without depending on the player.
public struct LiveChannelProgramInfo: Equatable, Sendable {
    public let title: String // l10n:content — guide-supplied programme title
    public let subtitle: String? // l10n:content — guide-supplied episode line
    public let description: String? // l10n:content — guide-supplied synopsis
    public let start: Date
    public let end: Date
    public let artworkURL: URL?

    public init(
        title: String, subtitle: String? = nil, description: String? = nil,
        start: Date, end: Date, artworkURL: URL? = nil
    ) {
        self.title = title
        self.subtitle = subtitle.flatMap { $0.isEmpty ? nil : $0 }
        self.description = description.flatMap { $0.isEmpty ? nil : $0 }
        self.start = start
        self.end = end
        self.artworkURL = artworkURL
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// How far through the programme `date` falls, clamped to 0...1.
    public func progress(at date: Date) -> Double {
        guard duration > 0 else { return date < start ? 0 : 1 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }

    /// "Subtitle – description", skipping whichever half is missing.
    public var summary: String? { // l10n:content — joins guide-supplied text
        switch (subtitle, description) {
        case let (subtitle?, description?): "\(subtitle) – \(description)"
        case let (subtitle?, nil): subtitle
        case let (nil, description?): description
        case (nil, nil): nil
        }
    }
}

/// One channel as the player lists it: the On Now row and the guide.
public struct LiveChannelOnNowItem: Identifiable, Equatable, Sendable {
    public let channelID: String
    public let channelName: String // l10n:content — provider-supplied channel name
    public let number: Int?
    public let logoURL: URL?
    /// Set for Plozz library channels, whose logo is generated rather than fetched.
    public let plozzChannelID: String?
    public let program: LiveChannelProgramInfo?

    public var id: String { channelID }

    public init(
        channelID: String, channelName: String, number: Int? = nil, logoURL: URL?,
        plozzChannelID: String? = nil, program: LiveChannelProgramInfo?
    ) {
        self.channelID = channelID
        self.channelName = channelName
        self.number = number
        self.logoURL = logoURL
        self.plozzChannelID = plozzChannelID
        self.program = program
    }
}

/// The remote's dedicated Guide button.
///
/// tvOS does not deliver it as a press. It continues a TVServices user activity
/// with the app in front — declared in the tvOS Info.plist's
/// `NSUserActivityTypes`, or the system sends it to the default guide app
/// instead. Kept here, beside the other types both the shell and the player
/// use, so neither has to import TVServices.
public enum LiveTVGuideButton {
    /// `TVUserActivityTypeBrowsingChannelGuide`, whose value is its own name.
    public static let activityType = "TVUserActivityTypeBrowsingChannelGuide"
    /// Posted by the shell after bringing Live TV forward; the expanded player
    /// answers by toggling its on-screen guide.
    public static let pressed = Notification.Name("plozzLiveTVGuideButtonPressed")
}

/// What the player hands the guide grid it hosts in its Guide card.
public struct LiveChannelGuideEmbedding {
    /// Menu inside the grid: hand focus back to the pill row.
    public let back: @MainActor () -> Void
    /// A channel was chosen and tuned: close the card.
    public let didTune: @MainActor () -> Void
    /// Opened by the remote's Guide button rather than by walking onto the
    /// pill, so the grid takes focus on the playing channel straight away.
    public let focusesPlayingChannel: Bool

    public init(
        back: @escaping @MainActor () -> Void,
        didTune: @escaping @MainActor () -> Void,
        focusesPlayingChannel: Bool
    ) {
        self.back = back
        self.didTune = didTune
        self.focusesPlayingChannel = focusesPlayingChannel
    }
}
