#if canImport(SwiftUI)
import CoreModels
import SwiftUI

public struct ContinueWatchingPresentation: Equatable, Sendable {
    public var artworkStyle: ContinueWatchingArtworkStyle
    public var isShowcase: Bool

    public init(visibility: HomeLibraryVisibility = .default, isShowcase: Bool = false) {
        artworkStyle = visibility.continueWatchingLayout == .portrait ? .portraitPosters
            : (visibility.continueWatchingShowsSeriesArtwork ? .logoAndArtwork : .thumbnail)
        self.isShowcase = isShowcase
    }

    public func showsCaptions(_ settings: CardCaptionSettings) -> Bool {
        artworkStyle.showsCaptions(settings: settings, isShowcase: isShowcase)
    }
}

private struct ContinueWatchingPresentationKey: EnvironmentKey {
    static let defaultValue = ContinueWatchingPresentation()
}

private struct ContinueWatchingPlaybackDetailsKey: EnvironmentKey {
    static let defaultValue = ContinueWatchingPlaybackDetails.default
}

public extension EnvironmentValues {
    var plozzContinueWatchingPresentation: ContinueWatchingPresentation {
        get { self[ContinueWatchingPresentationKey.self] }
        set { self[ContinueWatchingPresentationKey.self] = newValue }
    }

    var plozzContinueWatchingPlaybackDetails: ContinueWatchingPlaybackDetails {
        get { self[ContinueWatchingPlaybackDetailsKey.self] }
        set { self[ContinueWatchingPlaybackDetailsKey.self] = newValue }
    }
}

public extension ContinueWatchingPlaybackDetails {
    var cardAspectRatio: CGFloat {
        self == .detailed ? ContinueWatchingCardShape.portraitAspectRatio : 2.0 / 3.0
    }

    var displayName: LocalizedStringResource {
        switch self {
        case .detailed: "Detailed"
        case .progressOnly: "Progress only"
        }
    }
    var detail: LocalizedStringResource {
        switch self {
        case .detailed: "Play icon, progress, and playback information."
        case .progressOnly: "A progress bar without playback text."
        }
    }
}

public extension ContinueWatchingAction {
    var displayName: LocalizedStringResource {
        switch self {
        case .play: "Play"
        case .openDetails: "Open detail page"
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .play: "Selecting a movie or episode on Home starts playback."
        case .openDetails: "Selecting a movie or episode on Home opens its detail page."
        }
    }
}
#endif
