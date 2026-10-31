import Foundation

public enum SettingsSearchQualityNetwork: String, CaseIterable, Sendable {
    case local, remote, cellular

    public var title: LocalizedStringResource {
        switch self {
        case .local: "Local network"
        case .remote: "Remote Wi-Fi / Ethernet"
        case .cellular: "Cellular"
        }
    }

    public var keyPath: WritableKeyPath<StreamingQualitySettings, StreamingQuality> {
        switch self {
        case .local: \.local
        case .remote: \.remote
        case .cellular: \.cellular
        }
    }
}

public enum SettingsSearchSubtitlePage: String, CaseIterable, Sendable {
    case appearance, outline, background, formatting, dual

    public var title: LocalizedStringResource {
        switch self {
        case .appearance: "Appearance"
        case .outline: "Shadow & Outline"
        case .background: "Background"
        case .formatting: "Subtitle file formatting"
        case .dual: "Dual Subtitles"
        }
    }
}

public enum SettingsSearchPage: String, CaseIterable, Sendable {
    case playback, subtitles, subtitleStyle, theme, cards, artwork, circadian
    case allScreens, navigation, home, hero, detail, liveTV, language
    case heroContent, heroRatings, heroTrailers, heroDiscovery, heroLibraries, heroCollections
    case homeRows, homeFiltering, homeLabels, continueWatching, libraries, cardLabels
    case externalPlayer, skipMarkers, liveSubtitleStyle, musicPlayer, topShelf
    case downloads, profiles, sync, metadata, diagnostics, trackers, liveTVSources
    case playbackAdvanced, streamingAdvanced, metadataDiagnostics, detailRatingSources
    case liveTVGuide, liveTVVisibility, profileAppearance, profileSettings, accountLibraries, seerr
    case releaseNotes

    public var path: [LocalizedStringResource] {
        switch self {
        case .playback: ["Playback"]
        case .subtitles: ["Subtitles"]
        case .subtitleStyle: ["Subtitles", "Customize subtitle style"]
        case .theme: ["Appearance", "Theme"]
        case .cards: ["Appearance", "Cards"]
        case .artwork: ["Appearance", "Artwork"]
        case .circadian: ["Appearance", "Circadian Mode"]
        case .allScreens: ["Screens & Navigation", "All screens"]
        case .navigation: ["Screens & Navigation", "App navigation"]
        case .home: ["Screens & Navigation", "Home"]
        case .hero: ["Screens & Navigation", "Home", "Hero"]
        case .heroContent: ["Screens & Navigation", "Home", "Hero", "Hero content sources"]
        case .heroRatings: ["Screens & Navigation", "Home", "Hero", "Ratings"]
        case .heroTrailers: ["Screens & Navigation", "Home", "Hero", "Trailers"]
        case .heroDiscovery: ["Screens & Navigation", "Home", "Hero", "Discovery providers"]
        case .heroLibraries: ["Screens & Navigation", "Home", "Hero", "Random libraries"]
        case .heroCollections: ["Screens & Navigation", "Home", "Hero", "Collections"]
        case .homeRows: ["Screens & Navigation", "Home", "Rows"]
        case .homeFiltering: ["Screens & Navigation", "Home", "Filtering"]
        case .homeLabels: ["Screens & Navigation", "Home", "Card labels"]
        case .continueWatching: ["Screens & Navigation", "Home", "Rows", "Continue Watching"]
        case .libraries: ["Screens & Navigation", "Libraries"]
        case .cardLabels: ["Appearance", "Cards", "Customize labels"]
        case .externalPlayer: ["Playback", "External player"]
        case .skipMarkers: ["Playback", "Intros, credits & more"]
        case .liveSubtitleStyle: ["Subtitles", "Live TV", "Customize subtitle style"]
        case .musicPlayer: ["Screens & Navigation", "Music player"]
        case .topShelf: ["Top Shelf"]
        case .downloads: ["Downloads"]
        case .profiles: ["Profiles"]
        case .sync: ["iCloud Sync"]
        case .metadata: ["Metadata Providers"]
        case .diagnostics: ["Help & Diagnostics"]
        case .trackers: ["Trackers"]
        case .liveTVSources: ["Live TV", "Sources"]
        case .playbackAdvanced: ["Playback", "Advanced"]
        case .streamingAdvanced: ["Playback", "Streaming quality", "Advanced"]
        case .metadataDiagnostics: ["Metadata Providers", "Diagnostics"]
        case .detailRatingSources: ["Screens & Navigation", "Movie & show details", "Rating sources & order"]
        case .liveTVGuide: ["Live TV", "Guide preferences"]
        case .liveTVVisibility: ["Live TV", "Channel visibility"]
        case .profileAppearance: ["Profiles", "Appearance"]
        case .profileSettings: ["Profiles", "Manage profile"]
        case .accountLibraries: ["Libraries"]
        case .seerr: ["Seerr"]
        case .detail: ["Screens & Navigation", "Movie & show details"]
        case .liveTV: ["Live TV"]
        case .language: ["Language"]
        case .releaseNotes: ["Release Notes"]
        }
    }

    public var symbol: String {
        switch self {
        case .playback, .externalPlayer, .skipMarkers, .playbackAdvanced, .streamingAdvanced: "play.rectangle"
        case .subtitles, .subtitleStyle, .liveSubtitleStyle: "captions.bubble"
        case .theme, .cards, .artwork, .circadian, .cardLabels: "paintpalette"
        case .allScreens, .navigation, .home, .hero, .detail, .heroContent, .heroRatings,
             .heroTrailers, .heroDiscovery, .heroLibraries, .heroCollections, .homeRows,
             .homeFiltering, .homeLabels, .continueWatching, .libraries, .musicPlayer, .topShelf, .detailRatingSources,
             .accountLibraries:
            "rectangle.3.group"
        case .liveTV, .liveTVSources, .liveTVGuide, .liveTVVisibility: "antenna.radiowaves.left.and.right"
        case .language: "globe"
        case .downloads: "arrow.down.circle"
        case .profiles, .profileAppearance, .profileSettings: "person.2"
        case .sync: "icloud"
        case .metadata, .metadataDiagnostics: "sparkles.rectangle.stack"
        case .diagnostics: "ladybug"
        case .trackers: "link"
        case .seerr: "sparkles.tv"
        case .releaseNotes: "doc.text"
        }
    }

    public var requiresAdultProfile: Bool {
        switch self {
        case .downloads, .profiles, .sync, .metadata, .metadataDiagnostics, .topShelf, .seerr: true
        default: false
        }
    }

    public var requiresParentalAuthorization: Bool {
        self == .accountLibraries || self == .profileSettings
    }

    public var platform: SettingsSearchEntry.Platform? {
        switch self {
        case .downloads, .streamingAdvanced, .detailRatingSources: .mobile
        case .topShelf, .musicPlayer: .television
        default: nil
        }
    }
}

public struct SettingsSearchEntry: Identifiable, Hashable, Sendable {
    public enum Platform: Hashable, Sendable { case television, phone, tablet, mobile }

    public let id: String
    public let page: SettingsSearchPage
    public let title: LocalizedStringResource
    public let keywords: LocalizedStringResource
    public let platform: Platform?
    public let minimumOSVersion: Int
    public let requiresAdultProfile: Bool
    public let anchorID: String
    public let subtitlePage: SettingsSearchSubtitlePage
    public let skipKind: MediaSegment.Kind?
    public let contentCategory: SubtitleContentCategory?
    public let qualityNetwork: SettingsSearchQualityNetwork?
    public let preferredQueries: [LocalizedStringResource]

    public init(
        _ id: String, page: SettingsSearchPage, title: LocalizedStringResource,
        keywords: LocalizedStringResource, platform: Platform? = nil, minimumOSVersion: Int = 0,
        requiresAdultProfile: Bool = false, anchorID: String? = nil,
        subtitlePage: SettingsSearchSubtitlePage = .appearance, skipKind: MediaSegment.Kind? = nil,
        contentCategory: SubtitleContentCategory? = nil, qualityNetwork: SettingsSearchQualityNetwork? = nil,
        preferredQueries: [LocalizedStringResource] = []
    ) {
        self.id = id
        self.page = page
        self.title = title
        self.keywords = keywords
        self.platform = platform ?? page.platform
        self.minimumOSVersion = minimumOSVersion
        self.requiresAdultProfile = requiresAdultProfile || page.requiresAdultProfile
        self.anchorID = anchorID ?? id
        self.subtitlePage = subtitlePage
        self.skipKind = skipKind
        self.contentCategory = contentCategory
        self.qualityNetwork = qualityNetwork
        self.preferredQueries = preferredQueries
    }

    public func isAvailable(
        on platform: Platform, osVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        isKids: Bool = false
    ) -> Bool {
        osVersion >= minimumOSVersion && !(isKids && requiresAdultProfile)
            && (self.platform == nil || self.platform == platform
                || (self.platform == .mobile && platform != .television))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public var path: [LocalizedStringResource] {
        destinationPath(on: platform ?? .television)
    }

    public func destinationPath(on platform: Platform) -> [LocalizedStringResource] {
        destinationPage(on: platform).path + (subtitlePage == .appearance ? [] : [subtitlePage.title])
            + (skipKind.map { [$0.settingsTitle] } ?? [])
            + (qualityNetwork.map { [$0.title] } ?? [])
    }

    public func destinationPage(on platform: Platform) -> SettingsSearchPage {
        if (id == "subtitle-remember" || id == "cross-server-watch-sync") && platform != .television {
            return .playback
        }
        return page
    }

    public var cardCaptionView: CardCaptionView? {
        guard anchorID.hasPrefix("card-label-view-") else { return nil }
        return CardCaptionView(rawValue: String(anchorID.dropFirst("card-label-view-".count)))
    }
}

/// A local, bounded index. Queries and results never leave the device or enter logs.
public struct SettingsSearchIndex {
    private struct Document {
        let entry: SettingsSearchEntry
        let title: String
        let words: [String]
        let aliases: String
        let preferredQueries: Set<String>
    }
    private let documents: [Document]
    private let locale: Locale

    public init(entries: [SettingsSearchEntry], locale: Locale) {
        self.locale = locale
        documents = entries.map { entry in
            func resolve(_ resource: LocalizedStringResource) -> String {
                var localized = resource
                localized.locale = locale
                return String(localized: localized)
            }
            let title = Self.normalize(resolve(entry.title), locale: locale)
            let aliases = Self.normalize(resolve(entry.keywords), locale: locale)
            let preferredQueries = entry.preferredQueries.map { Self.normalize(resolve($0), locale: locale) }
            let path = (
                entry.destinationPath(on: .phone) + entry.destinationPath(on: .television)
                    + (entry.contentCategory.map { [$0.displayName] } ?? [])
            ).map(resolve).joined(separator: " ")
            return Document(
                entry: entry, title: title,
                words: Self.tokens(
                    ([title, aliases, path] + preferredQueries).joined(separator: " "), locale: locale
                ),
                aliases: aliases,
                preferredQueries: Set(preferredQueries)
            )
        }
    }

    public func results(for query: String) -> [SettingsSearchEntry] {
        let normalized = Self.normalize(String(query.prefix(256)), locale: locale)
        let words = Self.tokens(normalized, locale: locale).filter {
            !Self.queryFillers.contains($0)
        }
        guard !words.isEmpty else { return [] }
        let meaningfulQuery = words.joined(separator: " ")
        return documents.compactMap { document -> (SettingsSearchEntry, Int)? in
            let matches = words.map { word in
                document.words.map { Self.match(word, to: $0) }.max() ?? 0
            }
            guard matches.allSatisfy({ $0 > 0 }) else { return nil }
            var score = matches.reduce(0, +)
            if document.preferredQueries.contains(meaningfulQuery) { score += 1_100 }
            else if document.title == meaningfulQuery { score += 1_000 }
            else if document.title.hasPrefix(meaningfulQuery) { score += 800 }
            else if document.title.contains(meaningfulQuery) { score += 600 }
            else if document.aliases.contains(meaningfulQuery) { score += 400 }
            let titleWords = Self.tokens(document.title, locale: locale)
            score += words.map { word in titleWords.map { Self.match(word, to: $0) }.max() ?? 0 }
                .reduce(0, +)
            if document.entry.page == .liveSubtitleStyle { score -= 1 }
            return (document.entry, score)
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 > rhs.1
        }
        .map(\.0)
    }

    private static let queryFillers: Set<String> = [
        "a", "an", "the", "i", "my", "me", "to", "for", "of", "is", "it",
        "how", "do", "does", "can", "could", "please", "want", "would", "like",
        "make", "setting", "settings"
    ]

    private static func normalize(_ text: String, locale: Locale) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func tokens(_ text: String, locale: Locale) -> [String] {
        normalize(text, locale: locale).split(separator: " ").map(String.init)
    }

    private static func match(_ query: String, to word: String) -> Int {
        if query == word { return 100 }
        if word.hasPrefix(query) { return 80 }
        guard query.count >= 4 else { return 0 }
        let limit = query.count >= 7 ? 2 : 1
        guard abs(query.count - word.count) <= limit else { return 0 }
        let source = Array(query), target = Array(word)
        var previous = Array(0...target.count)
        for (i, character) in source.enumerated() {
            var current = [i + 1]
            for (j, candidate) in target.enumerated() {
                current.append(min(
                    current[j] + 1, previous[j + 1] + 1,
                    previous[j] + (character == candidate ? 0 : 1)
                ))
            }
            if (current.min() ?? limit + 1) > limit { return 0 }
            previous = current
        }
        return (previous.last ?? limit + 1) <= limit ? 40 : 0
    }
}

public enum SettingsSearchCatalog {
    public static func circadianScheduleFallbacks(
        isEnabled: Bool, mode: NightShiftScheduleMode
    ) -> [String] {
        guard isEnabled else { return targets(on: .circadian) }
        return (mode == .solar ? [] : ["circadian-region"])
            + (mode == .manual ? [] : ["circadian-on", "circadian-off"])
            + (mode == .alwaysOn ? ["circadian-fade"] : [])
    }

    public static let entries: [SettingsSearchEntry] = baseEntries + baseEntries.filter {
        $0.page == .subtitleStyle && $0.subtitlePage != .dual
    }.map { entry in
        SettingsSearchEntry(
            "live-\(entry.id)", page: .liveSubtitleStyle, title: entry.title, keywords: entry.keywords,
            platform: entry.platform, minimumOSVersion: entry.minimumOSVersion,
            anchorID: entry.anchorID, subtitlePage: entry.subtitlePage
        )
    }

    public static var carouselHeroTargets: [String] {
        entries.filter {
            [.hero, .heroContent, .heroRatings, .heroTrailers, .heroDiscovery,
             .heroLibraries, .heroCollections].contains($0.page)
                && !$0.id.hasPrefix("showcase-") && $0.id != "home-layout"
        }.map(\.id)
    }

    public static func targets(on page: SettingsSearchPage) -> [String] {
        entries.filter { $0.page == page }.map(\.id)
    }

    private static let baseEntries: [SettingsSearchEntry] = [
        .init("ask-before-resuming", page: .playback, title: "Ask to resume or start over",
              keywords: "continue watching restart beginning prompt confirmation resume playback"),
        .init("resume-rewind", page: .playback, title: "Rewind on resume",
              keywords: "resume rewind go back a few seconds recap where I left off"),
        .init("skip-backward", page: .playback, title: "Skip backward",
              keywords: "rewind jump back seconds interval backward skip steps"),
        .init("skip-forward", page: .playback, title: "Skip forward",
              keywords: "fast forward jump ahead seconds interval forward skip steps"),
        .init("version-selection", page: .playback, title: "Version selection",
              keywords: "choose select version edition video file quality ask automatically multiple versions"),
        .init("remember-series-version", page: .playback, title: "Remember series version choices",
              keywords: "remember edition file choice episodes"),
        .init("autoplay-next-episode", page: .playback, title: "Autoplay next episode",
              keywords: "automatically start play next episode binge stop after each episode continuous playback"),
        .init("autoplay-next-playlist", page: .playback, title: "Autoplay next playlist item",
              keywords: "automatically start play next video playlist continuous playback"),
        .init("show-up-next-card", page: .playback, title: "Show Up Next card",
              keywords: "next episode popup countdown end credits"),
        .init("audio-language", page: .playback, title: "Preferred audio language",
              keywords: "spoken language original dubbed dubbing voices movies anime"),
        .init("remember-audio", page: .playback, title: "Remember audio language per series",
              keywords: "remember sound track language episodes"),
        .init("lossless-audio", page: .playback, title: "Prefer lossless audio",
              keywords: "sound surround compressed HDMI ARC receiver audio compatibility"),
        .init("spatial-audio", page: .playback, title: "Spatial audio",
              keywords: "surround height overhead speakers immersive sound", minimumOSVersion: 26),
        .init("read-ahead", page: .playback, title: "Video buffer",
              keywords: "buffering streaming cache ahead slow network stuttering loading memory"),
        .init("live-buffer", page: .playback, title: "Live TV buffer",
              keywords: "live channel buffering cache ahead slow network memory"),
        .init("skip-intros", page: .playback, title: "Skip intros, credits & more",
              keywords: "opening ending credits recap automatically skip intro markers"),
        .init("seek-without-pausing", page: .playback, title: "Seek without pausing",
              keywords: "scrub swipe accidentally jump timeline pause seeking"),
        .init("background-audio", page: .playback, title: "Background Audio",
              keywords: "keep sound playing locked screen other apps background playback", platform: .mobile),
        .init("player-orientation", page: .playback, title: "Player orientation",
              keywords: "rotate rotation landscape lock portrait screen orientation", platform: .phone),
        .init("volume-brightness", page: .playback, title: "Volume and brightness gestures",
              keywords: "swipe sound louder quieter dim bright screen gestures gesture control", platform: .mobile),
        .init("display-fades", page: .playback, title: "Fade on display changes",
              keywords: "black screen HDR dynamic range frame rate transition", platform: .television),
        .init("subtitle-default", page: .subtitles, title: "Show subtitles",
              keywords: "captions turn on off forced foreign dialogue movies anime"),
        .init("subtitle-language", page: .subtitles, title: "Subtitle language",
              keywords: "captions translation preferred language"),
        .init("subtitle-sdh", page: .subtitles, title: "SDH subtitles",
              keywords: "deaf hearing impaired closed captions sound descriptions accessibility"),
        .init("subtitle-remember", page: .subtitles, title: "Remember subtitles per series",
              keywords: "remember captions language track episodes"),
        .init("live-subtitle-style", page: .subtitles, title: "Use a separate style for Live TV",
              keywords: "live television channel captions appearance different"),
        .init("subtitle-size", page: .subtitleStyle, title: "Subtitle size",
              keywords: "make subtitles bigger larger smaller captions text size hard to read"),
        .init("subtitle-font", page: .subtitleStyle, title: "Subtitle font",
              keywords: "captions typeface lettering font family"),
        .init("subtitle-color", page: .subtitleStyle, title: "Subtitle color",
              keywords: "captions text colour yellow white"),
        .init("subtitle-position", page: .subtitleStyle, title: "Subtitle position",
              keywords: "captions move up down vertical placement position on screen bottom top"),
        .init("theme", page: .theme, title: "Theme",
              keywords: "dark light mode appearance background colors colours"),
        .init("gradient-backgrounds", page: .theme, title: "Gradient Backgrounds",
              keywords: "background colors colours flat gradient"),
        .init("liquid-glass", page: .theme, title: "Liquid Glass",
              keywords: "transparency transparent opaque glass readable reduce effects"),
        .init("card-labels", page: .cards, title: "Labels",
              keywords: "show hide card titles names captions under posters show poster titles"),
        .init("watch-indicators", page: .cards, title: "Watch indicators",
              keywords: "watched unwatched checkmark badge status finished"),
        .init("episode-count", page: .cards, title: "Show unwatched episode count",
              keywords: "remaining episodes number badge count"),
        .init("progress-bars", page: .cards, title: "Show progress bars",
              keywords: "watched playback progress bar line card poster"),
        .init("card-style", page: .cards, title: "Style",
              keywords: "cards posters corners rounded square shape appearance"),
        .init("display-size", page: .cards, title: "Display Size",
              keywords: "make cards posters bigger larger smaller grid columns spacing scale"),
        .init("card-focus", page: .cards, title: "Focus",
              keywords: "selected card highlight zoom lift outline remote", platform: .television),
        .init("circadian", page: .circadian, title: "Circadian Mode",
              keywords: "night shift warm screen blue light evening night mode"),
        .init("content-ratings", page: .allScreens, title: "Show content ratings",
              keywords: "age classification badges parental PG movie rating"),
        .init("spoilers", page: .allScreens, title: "Protect unwatched episodes",
              keywords: "hide spoilers blur thumbnails unwatched episodes plot"),
        .init("hide-ratings", page: .allScreens, title: "Hide ratings until watched",
              keywords: "spoiler review scores blur hide ratings"),
        .init("navigation-layout", page: .navigation, title: "App navigation",
              keywords: "navigation tabs sidebar top bar rail menu layout", platform: .television),
        .init("navigation-order", page: .navigation, title: "Hide or Reorder Navigation",
              keywords: "move rearrange tabs libraries navigation menu order hide"),
        .init("hero-enabled", page: .hero, title: "Show hero",
              keywords: "home hero carousel spotlight banner featured showcase enable disable turn on off hide",
              preferredQueries: ["hero", "home banner", "spotlight"]),
        .init("detail-background", page: .detail, title: "Background",
              keywords: "movie show details hero trailer theme music behind artwork"),
        .init("detail-size", page: .detail, title: "Logo & text size",
              keywords: "movie show details title logo synopsis description bigger larger smaller"),
        .init("detail-ratings", page: .detail, title: "Show review scores",
              keywords: "movie show ratings reviews scores stars show external ratings"),
        .init("detail-age", page: .detail, title: "Show Common Sense age",
              keywords: "movie show family guidance recommended age children appropriate"),
        .init("live-start", page: .liveTV, title: "Live TV opens to",
              keywords: "start live channel guide categories default screen"),
        .init("channel-order", page: .liveTV, title: "Channel order",
              keywords: "sort channels alphabetically name number order"),
        .init("guide-preferences", page: .liveTV, title: "Guide preferences",
              keywords: "channel preview keep watching browsing recently watched guide"),
        .init("channel-visibility", page: .liveTV, title: "Channel visibility",
              keywords: "hide channels favorites only guide listings filters"),
        .init("language", page: .language, title: "Language",
              keywords: "app interface translation language change menus")
    ] + homeEntries + additionalEntries + familyEntries

    private static let familyEntries: [SettingsSearchEntry] =
        SettingsSearchQualityNetwork.allCases.flatMap { network in
            [
                SettingsSearchEntry(
                    "quality-custom-height-\(network.rawValue)", page: .streamingAdvanced,
                    title: "Maximum resolution", keywords: "custom streaming quality resolution limit height",
                    anchorID: "quality-custom-height", qualityNetwork: network
                ),
                SettingsSearchEntry(
                    "quality-custom-bitrate-\(network.rawValue)", page: .streamingAdvanced,
                    title: "Total bitrate (Kbps)", keywords: "custom streaming quality bitrate bandwidth data limit",
                    anchorID: "quality-custom-bitrate", qualityNetwork: network
                )
            ]
        } + CardCaptionView.customizableCases.map { view in
            SettingsSearchEntry(
                "card-label-view-\(view.rawValue)",
                page: [.home, .homeLibraries, .continueWatching].contains(view) ? .homeLabels : .cardLabels,
                title: view.displayName, keywords: "card labels captions titles names text under posters show hide"
            )
        } + ArtworkArea.allCases.map { area in
            SettingsSearchEntry(
                "artwork-view-\(area.rawValue)", page: .artwork, title: area.displayName,
                keywords: "artwork posters background backdrop logo local server library online metadata providers",
                platform: [.topShelf, .music, .recommendedHero].contains(area)
                    ? .television : area == .downloads ? .mobile : nil
            )
        } + SubtitleContentCategory.allCases.filter { $0 != .other }.flatMap { category in
            [
                SettingsSearchEntry(
                    "audio-language-\(category.rawValue)", page: .playback, title: category.displayName,
                    keywords: "preferred audio language spoken voices dub dubbing original",
                    contentCategory: category
                ),
                SettingsSearchEntry(
                    "subtitle-default-\(category.rawValue)", page: .subtitles, title: category.displayName,
                    keywords: "subtitle captions show forced foreign language separate",
                    contentCategory: category
                ),
                SettingsSearchEntry(
                    "skip-content-\(category.rawValue)", page: .skipMarkers, title: category.displayName,
                    keywords: "enable skip intros credits markers movies shows anime",
                    contentCategory: category
                )
            ]
        } + MediaSegment.Kind.skippable.flatMap { kind in
            SubtitleContentCategory.allCases.filter { $0 != .other }.flatMap { category in
                [
                    SettingsSearchEntry(
                        "skip-rule-\(kind.rawValue)-\(category.rawValue)", page: .skipMarkers,
                        title: category.displayName, keywords: "skip behavior automatically instant manual disabled default",
                        skipKind: kind, contentCategory: category
                    ),
                    SettingsSearchEntry(
                        "skip-rule-\(kind.rawValue)-\(category.rawValue)-delay", page: .skipMarkers,
                        title: "Skip after", keywords: "skip delay seconds countdown wait duration",
                        skipKind: kind, contentCategory: category
                    )
                ]
            }
        }

    private static let homeEntries: [SettingsSearchEntry] = [
        .init("home-layout", page: .hero, title: "Home layout",
              keywords: "hero carousel fullscreen showcase spotlight banner featured", platform: .television),
        .init("hero-logo-size", page: .hero, title: "Logo size",
              keywords: "hero banner title logo bigger smaller"),
        .init("hero-text-size", page: .hero, title: "Text size",
              keywords: "hero synopsis description font bigger smaller"),
        .init("hero-items", page: .hero, title: "Items to show",
              keywords: "hero carousel banner number count limit"),
        .init("hero-auto-advance", page: .hero, title: "Advance automatically",
              keywords: "hero carousel banner rotate rotation timer slideshow"),
        .init("hero-advance-seconds", page: .hero, title: "Seconds per item",
              keywords: "hero carousel banner rotation timer delay interval speed duration"),
        .init("hero-ratings", page: .heroRatings, title: "Show ratings",
              keywords: "hero review scores stars ratings"),
        .init("hero-age", page: .heroRatings, title: "Show Common Sense age",
              keywords: "hero family guidance children recommended age"),
        .init("hero-rating-count", page: .heroRatings, title: "Maximum ratings shown",
              keywords: "hero review scores number limit"),
        .init("hero-trailers", page: .heroTrailers, title: "Play trailer behind the hero",
              keywords: "hero background video preview motion autoplay"),
        .init("hero-trailers-muted", page: .heroTrailers, title: "Start muted",
              keywords: "hero trailer sound audio silent background"),
        .init("hero-content", page: .hero, title: "Hero content sources",
              keywords: "hero banner carousel choose featured titles movies shows"),
        .init("hero-watchlist-rotation", page: .heroContent, title: "Prefer less recently shown Watchlist items",
              keywords: "hero watchlist fresh unseen rotation shuffle variety"),
        .init("hero-provider-labels", page: .heroDiscovery, title: "Show provider labels",
              keywords: "discovery recommendations provider name badges", requiresAdultProfile: true),
        .init("hero-all-libraries", page: .heroLibraries, title: "All libraries on Home",
              keywords: "hero random libraries select include movies shows"),
        .init("hero-choose-libraries", page: .heroContent, title: "Choose libraries",
              keywords: "hero random library sources choose include exclude"),
        .init("hero-choose-collections", page: .heroContent, title: "Choose collections",
              keywords: "hero collections playlists selected titles"),
        .init("showcase-logo-size", page: .hero, title: "Logo size",
              keywords: "showcase spotlight title logo bigger smaller", platform: .television),
        .init("showcase-text-size", page: .hero, title: "Text size",
              keywords: "showcase spotlight synopsis description font bigger smaller", platform: .television),
        .init("showcase-discovery-row", page: .hero, title: "Discovery row",
              keywords: "showcase discover recommendations suggestions", platform: .television,
              requiresAdultProfile: true),
        .init("home-rows", page: .home, title: "Rows",
              keywords: "home shelves hubs sections rearrange order hide show customization"),
        .init("home-labels", page: .home, title: "Card labels",
              keywords: "home cards captions titles names posters thumbnails"),
        .init("home-filtering", page: .home, title: "Filtering",
              keywords: "home hide watched completed finished"),
        .init("home-hide-watched-recently-added", page: .homeFiltering, title: "Recently Added",
              keywords: "hide watched recently added home rows"),
        .init("hero-hide-watched", page: .homeFiltering, title: "Hero & discovery",
              keywords: "hide watched completed finished hero discovery"),
        .init("home-row-preset", page: .homeRows, title: "Preset",
              keywords: "home rows shelves hubs sections reset standard customize"),
        .init("home-row-arrangement", page: .homeRows, title: "Home rows",
              keywords: "add remove reorder rearrange move hide show home shelves hubs sections collections"),
        .init("continue-artwork-layout", page: .continueWatching, title: "Artwork choices",
              keywords: "continue watching thumbnail poster landscape portrait series artwork logo"),
        .init("continue-playback-details", page: .continueWatching, title: "Playback details",
              keywords: "continue watching duration remaining time progress"),
        .init("continue-labels", page: .continueWatching, title: "Labels",
              keywords: "continue watching title captions episode name number"),
        .init("continue-next-up", page: .continueWatching, title: "Include Next Up",
              keywords: "merge combine continue watching next up next episode"),
        .init("continue-action", page: .continueWatching, title: "When selecting an item",
              keywords: "continue watching tap click center button play details resume")
    ] + HeroSourceKind.allCases.map { source in
        .init("hero-source-\(source.rawValue)", page: .heroContent, title: source.displayName,
              keywords: "hero banner carousel featured content source include exclude enable disable",
              requiresAdultProfile: source == .featured)
    } + HeroDiscoverySource.allCases.map { source in
        .init("hero-discovery-\(source.rawValue)", page: .heroDiscovery, title: "\(source.displayName)",
              keywords: "discovery suggestions recommendations provider enable disable",
              requiresAdultProfile: true)
    }

    public static func entry(id: String) -> SettingsSearchEntry? {
        entries.first { $0.id == id }
    }

    public static func entries(
        on platform: SettingsSearchEntry.Platform,
        osVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion, isKids: Bool = false
    ) -> [SettingsSearchEntry] {
        entries.filter { $0.isAvailable(on: platform, osVersion: osVersion, isKids: isKids) }
    }
}
