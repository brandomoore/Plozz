import CoreModels
import Foundation

/// Profile-owned categories in a shared order, with platform-specific capabilities.
public enum ProfileSettingsCategory: String, CaseIterable, Identifiable, Sendable {
    case playback
    case subtitles
    case liveTV
    case libraries
    #if os(iOS)
    case downloads
    #endif
    case appearance
    case screensNavigation
    case trackers
    case seerr
    case language

    public var id: Self { self }

    public var title: LocalizedStringResource {
        switch self {
        case .playback: "Playback"
        case .subtitles: "Subtitles"
        case .liveTV: "Live TV"
        case .libraries: SettingsCopy.libraries
        #if os(iOS)
        case .downloads: "Downloads"
        #endif
        case .appearance: "Appearance"
        case .screensNavigation: "Screens & Navigation"
        case .trackers: "Trackers"
        case .seerr: LocalizedStringResource(stringLiteral: "Seerr")
        case .language: "Language"
        }
    }

    public var symbol: String {
        switch self {
        case .playback: "play.rectangle"
        case .subtitles: "captions.bubble"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .libraries: "rectangle.stack"
        #if os(iOS)
        case .downloads: "arrow.down.circle"
        #endif
        case .appearance: "paintpalette"
        case .screensNavigation: "rectangle.3.group"
        case .trackers: "link"
        case .seerr: "sparkles.tv"
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
