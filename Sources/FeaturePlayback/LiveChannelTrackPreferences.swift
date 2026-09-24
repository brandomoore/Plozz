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
    public var subtitleStyle: SubtitleStyle
    /// Mirrors `SubtitleBehavior.usesNativeSubtitles`: subtitles AVPlayer draws
    /// itself follow the system caption style instead of `subtitleStyle`.
    public var usesNativeSubtitles: Bool

    public init(
        audioLanguage: String? = nil,
        subtitleMode: SubtitleMode = .off,
        subtitleLanguage: String? = nil,
        subtitleStyle: SubtitleStyle = .default,
        usesNativeSubtitles: Bool = false
    ) {
        self.audioLanguage = audioLanguage
        self.subtitleMode = subtitleMode
        self.subtitleLanguage = subtitleLanguage
        self.subtitleStyle = subtitleStyle
        self.usesNativeSubtitles = usesNativeSubtitles
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
        self.init(
            audioLanguage: AudioLanguagePolicy.preferredAudioLanguages(
                remembered: nil,
                preference: playback.audioLanguagePreference,
                originalLanguage: nil,
                deviceLanguage: LanguageMatch.deviceLanguageCode
            ).first,
            subtitleMode: subtitles.subtitleMode,
            subtitleLanguage: subtitles.preferredSubtitleLanguage ?? LanguageMatch.deviceLanguageCode,
            subtitleStyle: SubtitleStyleStore(namespace: namespace).load().base,
            usesNativeSubtitles: subtitles.usesNativeSubtitles
        )
    }
}
#endif
