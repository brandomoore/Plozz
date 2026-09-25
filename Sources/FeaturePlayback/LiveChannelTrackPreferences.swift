#if canImport(AVFoundation)
import CoreModels
import Foundation
import Observation

/// Shared by retained panes, not by channel IDs or provider-specific stream IDs.
@MainActor
@Observable
public final class LiveChannelTrackPreferences {
    public var audioLanguage: String?
    public var subtitleMode: SubtitleMode
    public var subtitleLanguage: String?
    /// Live TV's own look, edited from the live player's Style screen. It starts
    /// as the profile's VOD style and, once edited, is kept apart from it, so a
    /// channel can look different from a film.
    public private(set) var subtitleStyle: SubtitleStyle
    /// Where an edited live style is kept, or nil for panes that don't persist.
    private let liveStyleKey: String?
    /// Mirrors `SubtitleBehavior.usesNativeSubtitles`: subtitles AVPlayer draws
    /// itself follow the system caption style instead of `subtitleStyle`.
    public var usesNativeSubtitles: Bool

    public init(
        audioLanguage: String? = nil,
        subtitleMode: SubtitleMode = .off,
        subtitleLanguage: String? = nil,
        subtitleStyle: SubtitleStyle = .default,
        usesNativeSubtitles: Bool = false,
        liveStyleKey: String? = nil
    ) {
        self.audioLanguage = audioLanguage
        self.subtitleMode = subtitleMode
        self.subtitleLanguage = subtitleLanguage
        self.subtitleStyle = subtitleStyle
        self.usesNativeSubtitles = usesNativeSubtitles
        self.liveStyleKey = liveStyleKey
    }

    /// The UserDefaults base key an edited live style persists under.
    public static let liveStyleStorageKey = "com.plozz.liveSubtitleStyle"

    public func setSubtitleStyle(_ style: SubtitleStyle) {
        subtitleStyle = style
        guard let liveStyleKey, let data = try? JSONEncoder().encode(style) else { return }
        UserDefaults.standard.set(data, forKey: liveStyleKey)
    }

    /// The look for subtitles the engine's AVPlayer draws (the remote-HLS route):
    /// Plozz's style, or no overrides so the system caption style applies.
    public var engineSubtitleStyle: SubtitleStyle {
        var style = subtitleStyle
        if usesNativeSubtitles { style.followsSystemStyle = true }
        return style
    }

    public convenience init(namespace: String?) {
        let playback = PlaybackSettingsStore(namespace: namespace).load()
        let subtitles = SubtitleBehaviorStore(namespace: namespace).load()
        let liveStyleKey = SettingsKey.scoped(Self.liveStyleStorageKey, namespace: namespace)
        let liveStyle = UserDefaults.standard.data(forKey: liveStyleKey)
            .flatMap { try? JSONDecoder().decode(SubtitleStyle.self, from: $0) }
        self.init(
            audioLanguage: AudioLanguagePolicy.preferredAudioLanguages(
                remembered: nil,
                preference: playback.audioLanguagePreference,
                originalLanguage: nil,
                deviceLanguage: LanguageMatch.deviceLanguageCode
            ).first,
            subtitleMode: subtitles.subtitleMode,
            subtitleLanguage: subtitles.preferredSubtitleLanguage ?? LanguageMatch.deviceLanguageCode,
            subtitleStyle: liveStyle ?? SubtitleStyleStore(namespace: namespace).load().base,
            usesNativeSubtitles: subtitles.usesNativeSubtitles,
            liveStyleKey: liveStyleKey
        )
    }
}
#endif
