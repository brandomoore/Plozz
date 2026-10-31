import Foundation

/// Per-profile playback preferences (pure data model, mirrors `SpoilerSettings`
/// / `CaptionSettings`).
///
/// Covers skip-intro behaviour, remote skip intervals, and cross-server watch
/// sync. Modelled as data so defaults can move with real feedback and
/// finer-grained toggles can be added later without a rewrite.
public struct PlaybackSettings: Codable, Equatable, Sendable {
    public struct SkipMarkerRule: Codable, Equatable, Sendable {
        public var mode: SkipIntrosMode
        public var automaticDelaySeconds: Int {
            didSet { automaticDelaySeconds = PlaybackSettings.boundedSkipDelay(automaticDelaySeconds) }
        }

        public init(mode: SkipIntrosMode, automaticDelaySeconds: Int) {
            self.mode = mode
            self.automaticDelaySeconds = PlaybackSettings.boundedSkipDelay(automaticDelaySeconds)
        }

        private enum CodingKeys: String, CodingKey { case mode, automaticDelaySeconds }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                mode: try container.decode(SkipIntrosMode.self, forKey: .mode),
                automaticDelaySeconds: try container.decode(Int.self, forKey: .automaticDelaySeconds)
            )
        }
    }

    /// How skip markers are handled: one mode for intros, credits, recaps,
    /// previews and commercials alike, unless ``skipModeOverrides`` sets a kind
    /// separately. On (a Skip button) by default, and a no-op on items without
    /// markers. Named for the intros it once covered alone.
    public var skipIntros: SkipIntrosMode

    /// The kinds the viewer set separately from ``skipIntros``. Empty unless they
    /// asked for different settings per kind.
    public var skipModeOverrides: [MediaSegment.Kind: SkipIntrosMode]

    public var skipMarkersEnabled: Bool
    public var skipContentCategories: Set<ContentCategory>
    public var skipAutomaticDelaySeconds: Int {
        didSet { skipAutomaticDelaySeconds = Self.boundedSkipDelay(skipAutomaticDelaySeconds) }
    }
    public var skipAutomaticDelayOverrides: [MediaSegment.Kind: Int] {
        didSet { skipAutomaticDelayOverrides = skipAutomaticDelayOverrides.mapValues(Self.boundedSkipDelay) }
    }
    /// Content-specific choices fall back to the existing per-kind/base rules until edited.
    public var skipMarkerRules: [ContentCategory: [MediaSegment.Kind: SkipMarkerRule]]

    /// Whether to look up community markers (IntroDB, then TheIntroDB) for items
    /// whose server has no intro or credits marker. Sends the title's IMDb or TMDB
    /// id to those databases. The server's own markers always win.
    public var useCommunityMarkers: Bool

    /// How many seconds a remote left-press or mobile backward gesture skips.
    public var skipBackwardInterval: SkipInterval

    /// How many seconds a remote right-press or mobile forward gesture skips.
    public var skipForwardInterval: SkipInterval

    /// How many seconds *earlier* than the saved resume point a partially-watched
    /// title starts when you return to it ("resume rewind"). A gentle nudge to
    /// re-establish context. `.five` by default; `.off` restores exact resume.
    public var resumeRewindInterval: ResumeRewindInterval

    public var askBeforeResuming: Bool

    public func shouldAskBeforeResuming(at position: TimeInterval?, fromBeginning: Bool = false) -> Bool {
        askBeforeResuming && !fromBeginning && (position ?? 0) > 1
    }

    /// iOS only. Keep video audio playing on lock/app background without PiP.
    /// Opt-in so existing profiles retain pause-on-lock behavior.
    public var backgroundAudio: Bool
    /// iPhone/iPad vertical swipes: brightness on the left, system volume on the right.
    public var volumeBrightnessGestures: Bool
    /// iPhone full-screen player preference. iPad follows system rotation.
    public var orientation: PlaybackOrientation
    public var streaming: StreamingQualitySettings
    /// Legacy profile selection, decoded only for migration to device settings.
    public var externalPlayer: ExternalPlayerSettings

    /// Nil until the profile answers the first multi-version playback prompt
    /// or explicitly chooses a mode in Settings.
    public var versionSelectionMode: PlaybackVersionSelectionMode?

    /// Reuse explicit version choices across episodes, independently of whether the picker is shown.
    public var rememberVersionPerSeries: Bool

    /// Whether finishing/resuming/marking a title converges your watch state on
    /// **every** server that holds it (the default), or only the server you
    /// actually watched on. ON (default) preserves today's cross-server fan-out;
    /// OFF scopes writes to the origin server and suppresses all cross-server
    /// probing/expansion. Independent of Trakt, which is an account-level
    /// integration and keeps scrobbling either way.
    public var syncWatchAcrossServers: Bool

    /// Whether a horizontal scrub gesture works **while playing** (the default),
    /// or only after you pause. ON (default) keeps today's faster "seek without
    /// pausing" feel — swipe to scrub mid-playback and it auto-resumes on
    /// landing. OFF makes a swipe during playback a no-op for the timeline (it
    /// neither seeks nor pauses): you must pause the video yourself first (remote
    /// Play/Pause, or a center-press on the scrub timeline), then scrub while
    /// paused; it stays paused on landing until you explicitly resume. This makes
    /// accidental seeks impossible while playing.
    public var seekWithoutPausing: Bool

    /// Whether finishing an episode automatically starts the next one.
    ///
    /// ON by default — that is what the player has always done, and it is what
    /// most people want from a series. OFF stops **every** automatic advance: the
    /// player simply closes at the end of an episode, returning you to whatever
    /// you launched it from (Home, a series page, search — the player is a
    /// full-screen cover over that screen, not a destination of its own). The Up
    /// Next card's Play Next button, and the next-episode control in the info
    /// panel, still work, because those are you asking rather than the player
    /// deciding.
    ///
    /// Independent of ``showUpNextCard`` on purpose. The two were tangled before:
    /// the card was the only visible thing about advancing, so turning it off read
    /// as "stop advancing" — but the natural-end path never consulted it and the
    /// next episode started anyway (#22). One switch now answers "does it
    /// advance", the other "does it tell me first", and either can be set without
    /// disturbing the other.
    public var autoPlayNextEpisode: Bool

    /// Whether a natural end advances to the next entry in the active video
    /// playlist. Independent of episode autoplay; playlist order takes priority
    /// when the viewer launched playback from a playlist.
    public var autoPlayNextPlaylistItem: Bool

    /// Whether the "Up Next" card is offered during an episode's closing credits
    /// when a next episode is queued. ON (default) shows a spoiler-safe card with
    /// the next episode's thumbnail so you can advance with one press (and it
    /// supersedes the Skip Credits button, since skipping to a black final frame
    /// is pointless when intent is "play next"). OFF never shows the card; credits
    /// fall back to the normal Skip Credits / natural-end auto-advance behaviour.
    /// Only ever applies to episodes with a next episode — movies are unaffected.
    public var showUpNextCard: Bool

    /// How many seconds before the end the Up Next card appears for content with
    /// **no** closing-credits marker — local/SMB files (and anything the server
    /// never analysed for segments). Server-marker content (Jellyfin/Plex) still
    /// triggers on its real credits segment and ignores this. There's no reliable
    /// way to detect where credits start in a bare file, so this mirrors how Kodi's
    /// Up Next and Infuse behave: a fixed, user-tunable lead time. Default 30s.
    public var upNextLeadSeconds: Int

    /// The profile's default audio-language preference: original spoken language
    /// (e.g. Japanese for anime), the viewer's device language (dub-friendly), or
    /// an explicit language. `.original` by default — the maintainer's primary
    /// user watches mostly anime and wants subbed originals. Per-content-type
    /// overrides ("original for anime, device for everything else") live in
    /// `AudioPolicy`; this is the base they fall back to.
    ///
    /// Replaces the legacy `preferOriginalLanguageAudio` boolean (`true` →
    /// `.original`, `false` → `.device`), migrated in the decoder below.
    public var audioLanguagePreference: AudioLanguagePreference

    /// Spatial conversion for supported tvOS/iOS on-demand sessions. Keep the original
    /// key so saved Off choices and transferred profile preferences survive.
    public var trueHDAtmosEnabled: Bool

    /// Experimental Profile 7 FEL reconstruction. Off by default; applies to new
    /// on-demand sessions, retaining eligible spatial audio on OS 26 and later.
    public var dolbyVisionFELEnabled: Bool

    /// Remember the chosen **audio language** per series: switching audio on any
    /// episode makes that language stick for every other episode of that series
    /// (per profile). Stored by language, re-resolved to a concrete track per
    /// episode. ON by default (mirrors Plex/Jellyfin).
    public var rememberAudioTrackPerSeries: Bool

    /// Remember the chosen **subtitle language (or Off)** per series, the subtitle
    /// counterpart to `rememberAudioTrackPerSeries`. ON by default.
    public var rememberSubtitleTrackPerSeries: Bool

    /// Fade to black around the HDMI handshake the TV performs when the **dynamic
    /// range** changes (SDR ⇄ HDR10 / HLG / Dolby Vision) — i.e. what tvOS calls
    /// *Match Dynamic Range*. ON by default: entering and leaving an HDR/DV title
    /// hides the panel's mode switch behind black instead of flashing. Turn OFF
    /// if you don't use Match Dynamic Range and prefer the snappiest transitions.
    public var fadeOnDynamicRangeChange: Bool

    /// Fade to black when leaving playback of content whose dynamic range *isn't*
    /// changing, to absorb the handshake blip the TV produces when tvOS's *Match
    /// Frame Rate* drops the display back from the movie's rate (23.976/24/25 Hz)
    /// to the UI's. There's no API that reports whether Match Frame Rate is on,
    /// so this is ON by default (it's the setup that flashes) and OFF is the
    /// escape hatch for anyone who has frame-rate matching disabled and would
    /// rather return to Home instantly.
    public var fadeOnFrameRateChange: Bool

    public init(
        skipIntros: SkipIntrosMode = .on,
        skipModeOverrides: [MediaSegment.Kind: SkipIntrosMode] = [:],
        skipMarkersEnabled: Bool? = nil,
        skipContentCategories: Set<ContentCategory> = Set(ContentCategory.allCases),
        skipAutomaticDelaySeconds: Int? = nil,
        skipAutomaticDelayOverrides: [MediaSegment.Kind: Int]? = nil,
        skipMarkerRules: [ContentCategory: [MediaSegment.Kind: SkipMarkerRule]] = [:],
        useCommunityMarkers: Bool = true,
        skipBackwardInterval: SkipInterval = .ten,
        skipForwardInterval: SkipInterval = .ten,
        resumeRewindInterval: ResumeRewindInterval = .five,
        askBeforeResuming: Bool = false,
        syncWatchAcrossServers: Bool = true,
        seekWithoutPausing: Bool = true,
        autoPlayNextEpisode: Bool = true,
        autoPlayNextPlaylistItem: Bool = true,
        showUpNextCard: Bool = true,
        upNextLeadSeconds: Int = 30,
        audioLanguagePreference: AudioLanguagePreference = .original,
        trueHDAtmosEnabled: Bool = true,
        dolbyVisionFELEnabled: Bool = false,
        rememberAudioTrackPerSeries: Bool = true,
        rememberSubtitleTrackPerSeries: Bool = true,
        fadeOnDynamicRangeChange: Bool = true,
        fadeOnFrameRateChange: Bool = true,
        backgroundAudio: Bool = false,
        volumeBrightnessGestures: Bool = true,
        orientation: PlaybackOrientation = .landscape,
        streaming: StreamingQualitySettings = .default,
        versionSelectionMode: PlaybackVersionSelectionMode? = nil,
        rememberVersionPerSeries: Bool = true,
        externalPlayer: ExternalPlayerSettings = .init()
    ) {
        self.skipIntros = skipIntros
        self.skipModeOverrides = skipModeOverrides
        self.skipMarkersEnabled = skipMarkersEnabled
            ?? (SkipMarkerModes(base: skipIntros, overrides: skipModeOverrides).fetchesMarkers
                || skipMarkerRules.values.contains { $0.values.contains { $0.mode != .off } })
        self.skipContentCategories = skipContentCategories
        self.skipAutomaticDelaySeconds = Self.boundedSkipDelay(
            skipAutomaticDelaySeconds ?? (skipIntros == .autoInstant ? 0 : 5)
        )
        self.skipAutomaticDelayOverrides = (skipAutomaticDelayOverrides
            ?? skipModeOverrides.mapValues { $0 == .autoInstant ? 0 : (skipAutomaticDelaySeconds ?? 5) })
            .mapValues(Self.boundedSkipDelay)
        self.skipMarkerRules = skipMarkerRules
        self.useCommunityMarkers = useCommunityMarkers
        self.skipBackwardInterval = skipBackwardInterval
        self.skipForwardInterval = skipForwardInterval
        self.resumeRewindInterval = resumeRewindInterval
        self.askBeforeResuming = askBeforeResuming
        self.syncWatchAcrossServers = syncWatchAcrossServers
        self.seekWithoutPausing = seekWithoutPausing
        self.autoPlayNextEpisode = autoPlayNextEpisode
        self.autoPlayNextPlaylistItem = autoPlayNextPlaylistItem
        self.showUpNextCard = showUpNextCard
        self.upNextLeadSeconds = upNextLeadSeconds
        self.audioLanguagePreference = audioLanguagePreference
        self.trueHDAtmosEnabled = trueHDAtmosEnabled
        self.dolbyVisionFELEnabled = dolbyVisionFELEnabled
        self.rememberAudioTrackPerSeries = rememberAudioTrackPerSeries
        self.rememberSubtitleTrackPerSeries = rememberSubtitleTrackPerSeries
        self.fadeOnDynamicRangeChange = fadeOnDynamicRangeChange
        self.fadeOnFrameRateChange = fadeOnFrameRateChange
        self.backgroundAudio = backgroundAudio
        self.volumeBrightnessGestures = volumeBrightnessGestures
        self.orientation = orientation
        self.streaming = streaming
        self.versionSelectionMode = versionSelectionMode
        self.rememberVersionPerSeries = rememberVersionPerSeries
        self.externalPlayer = externalPlayer
    }

    public static let `default` = PlaybackSettings()

    /// The skip mode for each marker kind, as the player consumes them.
    public var skipMarkerModes: SkipMarkerModes {
        guard skipMarkersEnabled else { return .allOff }
        return SkipMarkerModes(
            base: skipIntros, overrides: skipModeOverrides,
            automaticDelay: TimeInterval(skipAutomaticDelaySeconds),
            automaticDelayOverrides: skipAutomaticDelayOverrides.mapValues(TimeInterval.init)
        )
    }

    public func skipMarkerModes(for category: ContentCategory) -> SkipMarkerModes {
        guard skipMarkersEnabled, skipContentCategories.contains(category) else { return .allOff }
        var modes = skipMarkerModes
        for (kind, rule) in skipMarkerRules[category] ?? [:] {
            modes.overrides[kind] = rule.mode
            modes.automaticDelayOverrides[kind] = TimeInterval(rule.automaticDelaySeconds)
        }
        return modes
    }

    public mutating func setSkipMarkersEnabled(_ enabled: Bool) {
        skipMarkersEnabled = enabled
        if enabled, skipIntros == .off, skipModeOverrides.isEmpty, skipMarkerRules.isEmpty { skipIntros = .on }
    }

    public func configuredSkipMode(for kind: MediaSegment.Kind? = nil) -> SkipIntrosMode {
        kind.flatMap { skipModeOverrides[$0] } ?? skipIntros
    }

    public func configuredSkipDelay(for kind: MediaSegment.Kind? = nil) -> Int {
        if configuredSkipMode(for: kind) == .autoInstant { return 0 }
        return kind.flatMap { skipAutomaticDelayOverrides[$0] } ?? skipAutomaticDelaySeconds
    }

    public mutating func setConfiguredSkipMode(_ mode: SkipIntrosMode, for kind: MediaSegment.Kind? = nil) {
        if let kind { skipModeOverrides[kind] = mode }
        else { skipIntros = mode }
    }

    public mutating func setSkipAutomaticDelay(_ seconds: Int, for kind: MediaSegment.Kind? = nil) {
        let seconds = Self.boundedSkipDelay(seconds)
        let isAutomatic = configuredSkipMode(for: kind).isAutomatic
        if let kind { skipAutomaticDelayOverrides[kind] = seconds }
        else { skipAutomaticDelaySeconds = seconds }
        if isAutomatic {
            setConfiguredSkipMode(seconds == 0 ? .autoInstant : .autoDelay, for: kind)
        }
    }

    public func configuredSkipMode(for kind: MediaSegment.Kind, category: ContentCategory) -> SkipIntrosMode {
        skipMarkerRules[category]?[kind]?.mode ?? configuredSkipMode(for: kind)
    }

    public func configuredSkipDelay(for kind: MediaSegment.Kind, category: ContentCategory) -> Int {
        guard configuredSkipMode(for: kind, category: category) != .autoInstant else { return 0 }
        return skipMarkerRules[category]?[kind]?.automaticDelaySeconds ?? configuredSkipDelay(for: kind)
    }

    public func usesDefaultSkipRule(for kind: MediaSegment.Kind, category: ContentCategory) -> Bool {
        skipMarkerRules[category]?[kind] == nil
            && skipModeOverrides[kind] == nil
            && skipAutomaticDelayOverrides[kind] == nil
    }

    public mutating func useDefaultSkipRule(for kind: MediaSegment.Kind, category: ContentCategory) {
        // A legacy per-kind exception covers every category. Preserve its siblings
        // as content rules before removing it for just this category.
        if skipModeOverrides[kind] != nil || skipAutomaticDelayOverrides[kind] != nil {
            for other in ContentCategory.allCases where other != category && skipMarkerRules[other]?[kind] == nil {
                skipMarkerRules[other, default: [:]][kind] = SkipMarkerRule(
                    mode: configuredSkipMode(for: kind),
                    automaticDelaySeconds: configuredSkipDelay(for: kind)
                )
            }
            skipModeOverrides.removeValue(forKey: kind)
            skipAutomaticDelayOverrides.removeValue(forKey: kind)
        }
        skipMarkerRules[category]?.removeValue(forKey: kind)
        if skipMarkerRules[category]?.isEmpty == true {
            skipMarkerRules.removeValue(forKey: category)
        }
    }

    public mutating func setConfiguredSkipMode(
        _ mode: SkipIntrosMode, for kind: MediaSegment.Kind, category: ContentCategory
    ) {
        skipMarkerRules[category, default: [:]][kind] = SkipMarkerRule(
            mode: mode, automaticDelaySeconds: configuredSkipDelay(for: kind, category: category)
        )
    }

    public mutating func setSkipAutomaticDelay(
        _ seconds: Int, for kind: MediaSegment.Kind, category: ContentCategory
    ) {
        let seconds = Self.boundedSkipDelay(seconds)
        let mode = configuredSkipMode(for: kind, category: category)
        skipMarkerRules[category, default: [:]][kind] = SkipMarkerRule(
            mode: mode.isAutomatic ? (seconds == 0 ? .autoInstant : .autoDelay) : mode,
            automaticDelaySeconds: seconds
        )
    }

    public mutating func setSkipMarkersSeparately(_ enabled: Bool) {
        if enabled {
            skipModeOverrides = Dictionary(uniqueKeysWithValues: MediaSegment.Kind.skippable.map {
                ($0, skipIntros)
            })
            skipAutomaticDelayOverrides = Dictionary(uniqueKeysWithValues: MediaSegment.Kind.skippable.map {
                ($0, configuredSkipDelay())
            })
        } else {
            skipModeOverrides = [:]
            skipAutomaticDelayOverrides = [:]
            if skipIntros == .off { skipMarkersEnabled = false }
        }
    }

    public static let skipAutomaticDelayOptions = Array(0...30)

    private static func boundedSkipDelay(_ value: Int) -> Int {
        min(30, max(0, value))
    }

    /// Selectable values (seconds) for ``upNextLeadSeconds`` in Settings. A small,
    /// curated set — err late (never interrupt real content) with room to go
    /// earlier for shows with long credits. `default`'s 30s must be a member.
    public static let upNextLeadSecondsOptions: [Int] = [15, 20, 30, 45, 60]
}

// MARK: - Codable (tolerant of older / future persisted payloads)

public extension PlaybackSettings {
    private enum CodingKeys: String, CodingKey {
        case skipIntros
        case skipModeOverrides
        case skipMarkersEnabled
        case skipContentCategories
        case skipAutomaticDelaySeconds
        case skipAutomaticDelayOverrides
        case skipMarkerRules
        case useCommunityMarkers
        case skipBackwardInterval
        case skipForwardInterval
        case resumeRewindInterval
        case askBeforeResuming
        case backgroundAudio
        case volumeBrightnessGestures
        case orientation
        case streaming
        case externalPlayer
        case versionSelectionMode
        case rememberVersionPerSeries
        case syncWatchAcrossServers
        case seekWithoutPausing
        case autoPlayNextEpisode
        case autoPlayNextPlaylistItem
        case showUpNextCard
        case upNextLeadSeconds
        case audioLanguagePreference
        case trueHDAtmosEnabled
        case dolbyVisionFELEnabled
        /// Legacy boolean predecessor of `audioLanguagePreference`, still read for
        /// migration (`true` → `.original`, `false` → `.device`).
        case preferOriginalLanguageAudio
        case rememberAudioTrackPerSeries
        case rememberSubtitleTrackPerSeries
        case fadeOnDynamicRangeChange
        case fadeOnFrameRateChange
    }

    /// Decodes leniently so a payload written before a field existed (or in the
    /// older boolean shape) still loads instead of resetting to defaults. The
    /// legacy `{"skipIntros": true/false}` boolean maps to `.on` / `.off`, and a
    /// stored mode is kept as is: only a profile with none gets the `.on` default.
    /// `syncWatchAcrossServers` defaults to `true` when absent so installs that
    /// predate the toggle keep today's cross-server sync behaviour.
    /// `seekWithoutPausing` likewise defaults to `true` so existing installs keep
    /// today's scrub-while-playing behaviour.
    /// `showUpNextCard` defaults to `true` so existing installs get the Up Next
    /// card during episode credits.
    /// `skipBackwardInterval` / `skipForwardInterval` default to `.ten` when
    /// absent so existing installs keep the original 10-second skip behaviour.
    /// `resumeRewindInterval` defaults to `.five` when absent — the maintainer
    /// wants the resume-rewind nudge on for upgrading installs too, not just fresh
    /// ones (`.off` is available for anyone who prefers exact resume).
    /// Spatial audio defaults on when absent, while an existing Off choice survives.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PlaybackSettings.default
        if let mode = try? container.decodeIfPresent(SkipIntrosMode.self, forKey: .skipIntros) {
            self.skipIntros = mode ?? defaults.skipIntros
        } else if let legacy = try? container.decodeIfPresent(Bool.self, forKey: .skipIntros) {
            self.skipIntros = (legacy ?? false) ? .on : .off
        } else {
            self.skipIntros = defaults.skipIntros
        }
        // Keyed by kind name; a kind this build doesn't know is dropped.
        let storedOverrides =
            (try? container.decodeIfPresent([String: SkipIntrosMode].self, forKey: .skipModeOverrides))
            .flatMap { $0 } ?? [:]
        self.skipModeOverrides = Dictionary(uniqueKeysWithValues: storedOverrides.compactMap { key, mode in
            MediaSegment.Kind(rawValue: key).flatMap { $0.isSkippable ? ($0, mode) : nil }
        })
        if let categories = try container.decodeIfPresent([String].self, forKey: .skipContentCategories) {
            self.skipContentCategories = Set(categories.compactMap(ContentCategory.init(rawValue:)))
        } else {
            self.skipContentCategories = defaults.skipContentCategories
        }
        self.skipAutomaticDelaySeconds = Self.boundedSkipDelay(
            try container.decodeIfPresent(Int.self, forKey: .skipAutomaticDelaySeconds)
                ?? (skipIntros == .autoInstant ? 0 : 5)
        )
        if let delays = try container.decodeIfPresent([String: Int].self, forKey: .skipAutomaticDelayOverrides) {
            self.skipAutomaticDelayOverrides = Dictionary(uniqueKeysWithValues: delays.compactMap { key, delay in
                MediaSegment.Kind(rawValue: key).flatMap {
                    $0.isSkippable ? ($0, Self.boundedSkipDelay(delay)) : nil
                }
            })
        } else {
            self.skipAutomaticDelayOverrides = skipModeOverrides.mapValues { $0 == .autoInstant ? 0 : 5 }
        }
        let storedRules = try container.decodeIfPresent(
            [String: [String: SkipMarkerRule]].self, forKey: .skipMarkerRules
        ) ?? [:]
        self.skipMarkerRules = Dictionary(uniqueKeysWithValues: storedRules.compactMap { category, rules in
            guard let category = ContentCategory(rawValue: category) else { return nil }
            let knownRules = Dictionary(uniqueKeysWithValues: rules.compactMap { kind, rule in
                MediaSegment.Kind(rawValue: kind).flatMap { $0.isSkippable ? ($0, rule) : nil }
            })
            return (category, knownRules)
        })
        self.skipMarkersEnabled = try container.decodeIfPresent(Bool.self, forKey: .skipMarkersEnabled)
            ?? (SkipMarkerModes(base: skipIntros, overrides: skipModeOverrides).fetchesMarkers
                || skipMarkerRules.values.contains { $0.values.contains { $0.mode != .off } })
        self.useCommunityMarkers =
            (try? container.decodeIfPresent(Bool.self, forKey: .useCommunityMarkers))
            .flatMap { $0 } ?? defaults.useCommunityMarkers
        self.skipBackwardInterval =
            (try? container.decodeIfPresent(SkipInterval.self, forKey: .skipBackwardInterval))
            .flatMap { $0 } ?? defaults.skipBackwardInterval
        self.skipForwardInterval =
            (try? container.decodeIfPresent(SkipInterval.self, forKey: .skipForwardInterval))
            .flatMap { $0 } ?? defaults.skipForwardInterval
        self.resumeRewindInterval =
            (try? container.decodeIfPresent(ResumeRewindInterval.self, forKey: .resumeRewindInterval))
            .flatMap { $0 } ?? defaults.resumeRewindInterval
        self.backgroundAudio = try container.decodeIfPresent(Bool.self, forKey: .backgroundAudio) ?? false
        self.askBeforeResuming = try container.decodeIfPresent(Bool.self, forKey: .askBeforeResuming)
            ?? defaults.askBeforeResuming
        self.volumeBrightnessGestures =
            try container.decodeIfPresent(Bool.self, forKey: .volumeBrightnessGestures)
            ?? defaults.volumeBrightnessGestures
        self.orientation = (try? container.decode(PlaybackOrientation.self, forKey: .orientation))
            ?? defaults.orientation
        self.streaming = (try? container.decode(StreamingQualitySettings.self, forKey: .streaming)) ?? .default
        self.externalPlayer = (try? container.decodeIfPresent(ExternalPlayerSettings.self, forKey: .externalPlayer)) ?? .init()
        self.versionSelectionMode = try? container.decode(PlaybackVersionSelectionMode.self, forKey: .versionSelectionMode)
        self.rememberVersionPerSeries =
            (try? container.decodeIfPresent(Bool.self, forKey: .rememberVersionPerSeries))
            ?? defaults.rememberVersionPerSeries
        self.syncWatchAcrossServers =
            (try? container.decodeIfPresent(Bool.self, forKey: .syncWatchAcrossServers))
            .flatMap { $0 } ?? defaults.syncWatchAcrossServers
        self.seekWithoutPausing =
            (try? container.decodeIfPresent(Bool.self, forKey: .seekWithoutPausing))
            .flatMap { $0 } ?? defaults.seekWithoutPausing
        // Defaults ON for upgrading installs, which is the behaviour they already
        // had — this setting only ever takes something away.
        self.autoPlayNextEpisode =
            (try? container.decodeIfPresent(Bool.self, forKey: .autoPlayNextEpisode))
            .flatMap { $0 } ?? defaults.autoPlayNextEpisode
        self.autoPlayNextPlaylistItem =
            (try? container.decodeIfPresent(Bool.self, forKey: .autoPlayNextPlaylistItem))
            .flatMap { $0 } ?? defaults.autoPlayNextPlaylistItem
        self.showUpNextCard =
            (try? container.decodeIfPresent(Bool.self, forKey: .showUpNextCard))
            .flatMap { $0 } ?? defaults.showUpNextCard
        self.upNextLeadSeconds =
            (try? container.decodeIfPresent(Int.self, forKey: .upNextLeadSeconds))
            .flatMap { $0 } ?? defaults.upNextLeadSeconds
        // Prefer the new preference; fall back to the legacy boolean (true →
        // original, false → device) so installs that predate the dropdown keep
        // their prefer-original choice; default to `.original` when neither is set.
        if let preference = try? container.decodeIfPresent(AudioLanguagePreference.self, forKey: .audioLanguagePreference) {
            self.audioLanguagePreference = preference
        } else if let legacy = try? container.decodeIfPresent(Bool.self, forKey: .preferOriginalLanguageAudio) {
            self.audioLanguagePreference = legacy ? .original : .device
        } else {
            self.audioLanguagePreference = defaults.audioLanguagePreference
        }
        self.trueHDAtmosEnabled =
            (try? container.decodeIfPresent(Bool.self, forKey: .trueHDAtmosEnabled))
            .flatMap { $0 } ?? defaults.trueHDAtmosEnabled
        self.dolbyVisionFELEnabled =
            (try? container.decodeIfPresent(Bool.self, forKey: .dolbyVisionFELEnabled))
            .flatMap { $0 } ?? defaults.dolbyVisionFELEnabled
        self.rememberAudioTrackPerSeries =
            (try? container.decodeIfPresent(Bool.self, forKey: .rememberAudioTrackPerSeries))
            .flatMap { $0 } ?? defaults.rememberAudioTrackPerSeries
        self.rememberSubtitleTrackPerSeries =
            (try? container.decodeIfPresent(Bool.self, forKey: .rememberSubtitleTrackPerSeries))
            .flatMap { $0 } ?? defaults.rememberSubtitleTrackPerSeries
        // Both fades default to `true` when absent so installs that predate the
        // toggles keep (dynamic range) / gain (frame rate) the smooth transition.
        self.fadeOnDynamicRangeChange =
            (try? container.decodeIfPresent(Bool.self, forKey: .fadeOnDynamicRangeChange))
            .flatMap { $0 } ?? defaults.fadeOnDynamicRangeChange
        self.fadeOnFrameRateChange =
            (try? container.decodeIfPresent(Bool.self, forKey: .fadeOnFrameRateChange))
            .flatMap { $0 } ?? defaults.fadeOnFrameRateChange
    }

    /// Explicit encoder so the legacy-only `preferOriginalLanguageAudio` coding
    /// key (kept for decode-time migration) doesn't break Encodable synthesis and
    /// is never written back — only the current `audioLanguagePreference` is
    /// persisted.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(skipIntros, forKey: .skipIntros)
        try container.encode(
            Dictionary(uniqueKeysWithValues: skipModeOverrides.map { ($0.key.rawValue, $0.value) }),
            forKey: .skipModeOverrides
        )
        try container.encode(skipMarkersEnabled, forKey: .skipMarkersEnabled)
        try container.encode(skipContentCategories.map(\.rawValue).sorted(), forKey: .skipContentCategories)
        try container.encode(skipAutomaticDelaySeconds, forKey: .skipAutomaticDelaySeconds)
        try container.encode(
            Dictionary(uniqueKeysWithValues: skipAutomaticDelayOverrides.map { ($0.key.rawValue, $0.value) }),
            forKey: .skipAutomaticDelayOverrides
        )
        try container.encode(
            Dictionary(uniqueKeysWithValues: skipMarkerRules.map { category, rules in
                (category.rawValue, Dictionary(uniqueKeysWithValues: rules.map { ($0.key.rawValue, $0.value) }))
            }),
            forKey: .skipMarkerRules
        )
        try container.encode(useCommunityMarkers, forKey: .useCommunityMarkers)
        try container.encode(skipBackwardInterval, forKey: .skipBackwardInterval)
        try container.encode(skipForwardInterval, forKey: .skipForwardInterval)
        try container.encode(resumeRewindInterval, forKey: .resumeRewindInterval)
        try container.encode(askBeforeResuming, forKey: .askBeforeResuming)
        try container.encode(backgroundAudio, forKey: .backgroundAudio)
        try container.encode(volumeBrightnessGestures, forKey: .volumeBrightnessGestures)
        try container.encode(orientation, forKey: .orientation)
        try container.encode(streaming, forKey: .streaming)
        try container.encodeIfPresent(versionSelectionMode, forKey: .versionSelectionMode)
        try container.encode(rememberVersionPerSeries, forKey: .rememberVersionPerSeries)
        try container.encode(syncWatchAcrossServers, forKey: .syncWatchAcrossServers)
        try container.encode(seekWithoutPausing, forKey: .seekWithoutPausing)
        try container.encode(autoPlayNextEpisode, forKey: .autoPlayNextEpisode)
        try container.encode(autoPlayNextPlaylistItem, forKey: .autoPlayNextPlaylistItem)
        try container.encode(showUpNextCard, forKey: .showUpNextCard)
        try container.encode(upNextLeadSeconds, forKey: .upNextLeadSeconds)
        try container.encode(audioLanguagePreference, forKey: .audioLanguagePreference)
        try container.encode(trueHDAtmosEnabled, forKey: .trueHDAtmosEnabled)
        try container.encode(dolbyVisionFELEnabled, forKey: .dolbyVisionFELEnabled)
        try container.encode(rememberAudioTrackPerSeries, forKey: .rememberAudioTrackPerSeries)
        try container.encode(rememberSubtitleTrackPerSeries, forKey: .rememberSubtitleTrackPerSeries)
        try container.encode(fadeOnDynamicRangeChange, forKey: .fadeOnDynamicRangeChange)
        try container.encode(fadeOnFrameRateChange, forKey: .fadeOnFrameRateChange)
    }
}
