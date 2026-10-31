import Foundation

public enum SettingsSearchPage: String, CaseIterable, Sendable {
    case playback, subtitles, subtitleStyle, theme, cards, artwork, circadian
    case allScreens, navigation, home, detail, liveTV, language

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
        case .detail: ["Screens & Navigation", "Movie & show details"]
        case .liveTV: ["Live TV"]
        case .language: ["Language"]
        }
    }

    public var symbol: String {
        switch self {
        case .playback: "play.rectangle"
        case .subtitles, .subtitleStyle: "captions.bubble"
        case .theme, .cards, .artwork, .circadian: "paintpalette"
        case .allScreens, .navigation, .home, .detail: "rectangle.3.group"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .language: "globe"
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

    public init(
        _ id: String, page: SettingsSearchPage, title: LocalizedStringResource,
        keywords: LocalizedStringResource, platform: Platform? = nil
    ) {
        self.id = id
        self.page = page
        self.title = title
        self.keywords = keywords
        self.platform = platform
    }

    public func isAvailable(on platform: Platform) -> Bool {
        self.platform == nil || self.platform == platform
            || (self.platform == .mobile && platform != .television)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public func destinationPage(on platform: Platform) -> SettingsSearchPage {
        id == "subtitle-remember" && platform != .television ? .playback : page
    }
}

/// A local, bounded index. Queries and results never leave the device or enter logs.
public struct SettingsSearchIndex {
    private struct Document {
        let entry: SettingsSearchEntry
        let title: String
        let words: [String]
        let aliases: String
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
            let path = entry.page.path.map(resolve).joined(separator: " ")
            return Document(
                entry: entry, title: title,
                words: Self.tokens(title + " " + aliases + " " + path, locale: locale),
                aliases: aliases
            )
        }
    }

    public func results(for query: String) -> [SettingsSearchEntry] {
        let normalized = Self.normalize(String(query.prefix(256)), locale: locale)
        let words = Self.tokens(normalized, locale: locale).filter {
            !Self.queryFillers.contains($0)
        }
        guard !words.isEmpty else { return [] }
        return documents.compactMap { document -> (SettingsSearchEntry, Int)? in
            let matches = words.map { word in
                document.words.map { Self.match(word, to: $0) }.max() ?? 0
            }
            guard matches.allSatisfy({ $0 > 0 }) else { return nil }
            var score = matches.reduce(0, +)
            if document.title == normalized { score += 1_000 }
            else if document.title.hasPrefix(normalized) { score += 800 }
            else if document.title.contains(normalized) { score += 600 }
            else if document.aliases.contains(normalized) { score += 400 }
            score += words.filter { document.title.contains($0) }.count * 20
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
    public static let entries: [SettingsSearchEntry] = [
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
              keywords: "surround height overhead speakers immersive sound"),
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
    ]

    public static func entry(id: String) -> SettingsSearchEntry? {
        entries.first { $0.id == id }
    }

    public static func entries(on platform: SettingsSearchEntry.Platform) -> [SettingsSearchEntry] {
        entries.filter { $0.isAvailable(on: platform) }
    }
}
