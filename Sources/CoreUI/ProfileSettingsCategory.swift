import CoreModels
import Foundation

/// The same profile-owned categories, in the same order, on every platform.
public enum ProfileSettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case playback
    case subtitles
    case liveTV
    case libraries
    case appearance
    case screensNavigation
    case trackers
    case language

    public var id: Self { self }

    public var title: LocalizedStringResource {
        switch self {
        case .playback: "Playback"
        case .subtitles: "Subtitles"
        case .liveTV: "Live TV"
        case .libraries: SettingsCopy.libraries
        case .appearance: "Appearance"
        case .screensNavigation: "Screens & Navigation"
        case .trackers: "Trackers"
        case .language: "Language"
        }
    }

    public var symbol: String {
        switch self {
        case .playback: "play.rectangle"
        case .subtitles: "captions.bubble"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .libraries: "rectangle.stack"
        case .appearance: "paintpalette"
        case .screensNavigation: "rectangle.3.group"
        case .trackers: "link"
        case .language: "globe"
        }
    }

    public var summary: LocalizedStringResource? {
        switch self {
        case .appearance:
            "Theme, cards, artwork, and display size"
        case .screensNavigation:
            "Navigation and screen preferences"
        case .trackers:
            if RuntimeFeatureFlags.buildDefault.isEnabled(.wetrakr) {
                "Trakt, Simkl, WeTrakr, AniList, MyAnimeList, Last.fm"
            } else {
                "Trakt, Simkl, AniList, MyAnimeList, Last.fm"
            }
        default:
            nil
        }
    }
}
