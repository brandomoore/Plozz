public struct PlozzAttributionLicense: Hashable, Identifiable, Sendable {
    public enum Family: Hashable, Sendable {
        case gpl
        case lgpl
        case mit
        case apache
        case bsd
        case cc0
        case isc
        case ofl
        case api
    }

    public let label: String  // l10n:content — third-party license identifier (e.g. "MIT", "LGPL-3.0"), never translated
    public let family: Family

    public init(_ label: String, family: Family) {  // l10n:content — third-party license identifier
        self.label = label
        self.family = family
    }

    public var id: String { label }
}

public struct PlozzAttribution: Identifiable, Sendable {
    /// The whole attributions page is deliberately English, headings included:
    /// it is trademark and licence language, where a well-meaning translation
    /// can change the legal meaning. Kept together so the page doesn't read as
    /// half-translated.
    public let title: String  // l10n:content — legal/attribution page, deliberately English
    public let detail: String
    public let licenses: [PlozzAttributionLicense]

    public init(
        title: String,  // l10n:content — legal/attribution copy: third-party project name + license text, deliberately verbatim
        detail: String,
        licenses: [PlozzAttributionLicense] = []
    ) {
        self.title = title
        self.detail = detail
        self.licenses = licenses
    }

    /// Identity is the heading only because the page is deliberately never
    /// translated. If that ever changes, this has to become a stable id first —
    /// identity derived from display text changes with the language.
    public var id: String { title }
}

public enum PlozzAttributions {
    public static let introduction =
        "Plozz is free and open source under the GPL-3.0 license with an App Store "
        + "exception. It is not affiliated with, endorsed, or certified by any of "
        + "the projects or services listed below."

    public static let entries: [PlozzAttribution] = [
        PlozzAttribution(
            title: "Media Servers",
            detail:
                "Jellyfin is a free software media system; Plozz is an unofficial "
                + "client and is not affiliated with the Jellyfin project. Plex is "
                + "a trademark of Plex, Inc.; Plozz is an unofficial client and is "
                + "not endorsed by Plex, Inc. Emby and Silo are independent media "
                + "server projects supported through their respective APIs. "
                + "Sources: https://jellyfin.org, https://www.plex.tv, "
                + "https://emby.media and https://github.com/Silo-Server."
        ),
        PlozzAttribution(
            title: "Brand Marks",
            detail:
                "Third-party names and logos identify the servers and services "
                + "Plozz connects to. They belong to their respective owners "
                + "and are not used as Plozz branding."
        ),
        PlozzAttribution(
            title: "AetherEngine",
            detail:
                "Playback is powered by AetherEngine by Vincent Herbst, under "
                + "LGPL-3.0 with an Apple Store exception. "
                + "Upstream: https://github.com/superuser404notfound/AetherEngine. "
                + "Source: https://github.com/brandomoore/AetherEngine/tree/c5eeb230b9cd78a64f57448aee5d553bd3368ad3",
            licenses: [.init("LGPL-3.0", family: .lgpl)]
        ),
        PlozzAttribution(
            title: "FFmpeg",
            detail:
                "FFmpeg n8.1.3 provides libavcodec, libavformat, libavutil, "
                + "libswresample, libswscale and libavfilter for media decoding "
                + "and the playback bridge. Packaged by FFmpegBuild 3.10.1. "
                + "Source and component notices: "
                + "https://github.com/superuser404notfound/FFmpegBuild/tree/3.10.1. "
                + "Upstream: https://ffmpeg.org.",
            licenses: [.init("LGPL-2.1+", family: .lgpl)]
        ),
        PlozzAttribution(
            title: "libdovi",
            detail:
                "Dolby Vision metadata parsing uses libdovi, packaged by LibDovi 2.1.0. "
                + "Source: https://github.com/superuser404notfound/LibDovi/tree/2.1.0.",
            licenses: [.init("MIT", family: .mit)]
        ),
        PlozzAttribution(
            title: "LibTrueHD",
            detail:
                "TrueHD decoding and optional spatial audio rendering use LibTrueHD 3.1.0. "
                + "By Quick104 and "
                + "Vincent Herbst, using truehdd and oamd by Rainbaby and contributors. "
                + "Source: https://github.com/superuser404notfound/LibTrueHD/tree/3.1.0. "
                + "Complete notices and license texts are bundled in LibTrueHDNotices.txt, "
                + "LibTrueHDLicense.txt and LibTrueHDApacheLicense.txt.",
            licenses: [
                .init("MIT", family: .mit),
                .init("Apache-2.0", family: .apache),
            ]
        ),
        PlozzAttribution(
            title: "libass & Text Rendering",
            detail:
                "Authored ASS/SSA rendering uses libass 0.17.5 (ISC), "
                + "with FreeType (FreeType License), HarfBuzz and libunibreak "
                + "(MIT), and FriBidi (LGPL-2.1-or-later). "
                + "Source: https://github.com/libass/libass/tree/0.17.5. "
                + "Font-library builds: https://github.com/mpvkit/libass-build/tree/0.17.5. "
                + "Complete notices are bundled in LibassNotices.txt.",
            licenses: [
                .init("ISC", family: .isc),
                .init("LGPL-2.1", family: .lgpl),
                .init("MIT", family: .mit),
            ]
        ),
        PlozzAttribution(
            title: "dav1d",
            detail:
                "AV1 video decoding uses dav1d 1.5.4 by VideoLAN and contributors. "
                + "Source and notices are included in FFmpegBuild: "
                + "https://github.com/superuser404notfound/FFmpegBuild/tree/3.10.1.",
            licenses: [.init("BSD-2-Clause", family: .bsd)]
        ),
        PlozzAttribution(
            title: "zimg",
            detail:
                "Image scaling and color conversion use zimg 3.0.6 under the WTFPL. "
                + "Source: https://github.com/sekrit-twc/zimg. "
                + "License: https://github.com/superuser404notfound/FFmpegBuild/blob/3.10.1/LICENSES/zimg.WTFPL.txt."
        ),
        PlozzAttribution(
            title: "libzvbi",
            detail:
                "Teletext decoding uses libzvbi 0.2.46, as packaged by FFmpegBuild. "
                + "The library is LGPL-2.0-or-later, distributed under LGPL-2.1; "
                + "ure.c uses the MIT license. "
                + "Source, build modifications and notices: "
                + "https://github.com/superuser404notfound/FFmpegBuild/tree/3.10.1/LICENSES.",
            licenses: [
                .init("LGPL-2.1", family: .lgpl),
                .init("MIT", family: .mit),
            ]
        ),
        PlozzAttribution(
            title: "SMBClient",
            detail:
                "SMB network shares use SMBClient by Kishikawa Katsumi, "
                + "with Plozz's SMB3 and connection-handling changes. "
                + "Upstream: https://github.com/kishikawakatsumi/SMBClient. "
                + "Source: https://github.com/thatcube/SMBClient/tree/5d5bceb6fa0833c98b0eecc676609c9476bd9423.",
            licenses: [.init("MIT", family: .mit)]
        ),
        PlozzAttribution(
            title: "Swift Networking & Cryptography",
            detail:
                "Swift packages by Apple and their contributors support SSH/SFTP "
                + "and cryptographic operations. "
                + "Swift NIO 2.102.0: https://github.com/apple/swift-nio/tree/2.102.0. "
                + "Swift NIO SSH 0.15.0: https://github.com/apple/swift-nio-ssh/tree/0.15.0. "
                + "Swift Crypto 4.5.2: https://github.com/apple/swift-crypto/tree/4.5.2. "
                + "Swift ASN.1 1.7.2: https://github.com/apple/swift-asn1/tree/1.7.2.",
            licenses: [.init("Apache-2.0", family: .apache)]
        ),
        PlozzAttribution(
            title: "Swift Collections, Atomics & System",
            detail:
                "Package dependencies include Swift Collections 1.6.0, Swift Atomics "
                + "1.3.1 and Swift System 1.8.1 by Apple and their contributors, "
                + "under Apache-2.0 with the Swift Runtime Library Exception. "
                + "Sources: https://github.com/apple/swift-collections/tree/1.6.0, "
                + "https://github.com/apple/swift-atomics/tree/1.3.1 and "
                + "https://github.com/apple/swift-system/tree/1.8.1.",
            licenses: [.init("Apache-2.0", family: .apache)]
        ),
        PlozzAttribution(
            title: "Sentry",
            detail:
                "Optional crash reporting and diagnostics use Sentry's Apple SDK "
                + "9.27.0. Copyright Sentry and contributors. "
                + "SDK source: https://github.com/getsentry/sentry-cocoa/tree/9.27.0. "
                + "Binary package: https://github.com/getsentry/sentry-apple-binaries/tree/9.27.0.",
            licenses: [.init("MIT", family: .mit)]
        ),
        PlozzAttribution(
            title: "TMDB",
            detail:
                "This product uses the TMDB API but is not endorsed or certified by "
                + "TMDB. Artwork, metadata, and Discovery data are provided "
                + "by TMDB (https://www.themoviedb.org).",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "TheTVDB",
            detail:
                "Metadata, artwork, and Discovery data are provided by TheTVDB. "
                + "Please consider adding missing information or subscribing at "
                + "https://thetvdb.com. Plozz uses the "
                + "TheTVDB API but is not endorsed or certified by TheTVDB.",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "OMDb & AniList",
            detail:
                "Additional ratings are sourced from the OMDb API (omdbapi.com) and "
                + "AniList (https://anilist.co). AniList also provides anime metadata "
                + "and Discovery data. Neither endorses or is affiliated "
                + "with Plozz.",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "TVmaze",
            detail:
                "TV schedules, show metadata, and Discovery data are provided "
                + "by TVmaze (https://www.tvmaze.com). TVmaze API data is licensed under "
                + "Creative Commons Attribution-ShareAlike 4.0 International "
                + "(CC BY-SA 4.0): https://creativecommons.org/licenses/by-sa/4.0/. "
                + "Plozz filters and combines this data for discovery. TVmaze does not "
                + "endorse and is not affiliated with Plozz.",
            licenses: [.init("CC BY-SA 4.0", family: .api)]
        ),
        PlozzAttribution(
            title: "Watch Tracking",
            detail:
                "Watch-history sync integrations — Trakt (trakt.tv), Simkl (simkl.com), "
                + "AniList (anilist.co), MyAnimeList (myanimelist.net), and WeTrakr "
                + "(wetrakr.com) — use their "
                + "respective public APIs. None endorses or is affiliated with Plozz.",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "Last.fm",
            detail:
                "Optional music listening-history sync uses the Last.fm API "
                + "(https://www.last.fm). Last.fm is not affiliated with Plozz.",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "Seerr",
            detail:
                "Media discovery and requests can connect to a user's Seerr server. "
                + "Source: https://github.com/seerr-team/seerr.",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "Kitsu",
            detail:
                "Anime artwork is sourced from Kitsu (https://kitsu.io). "
                + "Kitsu is not affiliated with Plozz.",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "Wikidata",
            detail:
                "Entity data and artwork lookups use Wikidata "
                + "(https://www.wikidata.org) under CC0. Images linked from "
                + "Wikidata retain their own licenses and copyright.",
            licenses: [.init("CC0", family: .cc0)]
        ),
        PlozzAttribution(
            title: "Wikipedia & Wikimedia Commons",
            detail:
                "Text and biography lookups use Wikipedia (https://www.wikipedia.org), "
                + "whose text is available under CC BY-SA; see each page's terms. "
                + "Artwork from Wikipedia and Wikimedia Commons "
                + "(https://commons.wikimedia.org) retains its per-file license "
                + "and copyright.",
            licenses: [.init("CC BY-SA", family: .api)]
        ),
        PlozzAttribution(
            title: "MusicBrainz, Cover Art Archive & Deezer",
            detail:
                "Music metadata and artwork lookups use MusicBrainz "
                + "(https://musicbrainz.org), the Cover Art Archive "
                + "(https://coverartarchive.org), and Deezer (https://www.deezer.com). "
                + "Artwork retains its original copyright and applicable terms.",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "LRCLIB",
            detail:
                "Fallback plain and synchronized lyrics use LRCLIB "
                + "(https://lrclib.net). Lyrics retain their original copyright.",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "Community Skip Markers",
            detail:
                "Optional intro, recap and credits markers use IntroDB "
                + "(https://introdb.app) and TheIntroDB (https://theintrodb.org). "
                + "These are independent community services.",
            licenses: [.init("API", family: .api)]
        ),
        PlozzAttribution(
            title: "Fonts",
            detail:
                "The default subtitle typeface is Atkinson Hyperlegible, © 2020 "
                + "Braille Institute of America, Inc., chosen for its legibility from "
                + "a distance. UI accent type uses Bungee by David Jonathan Ross. "
                + "Media badges use Outfit by The Outfit Project Authors "
                + "(https://github.com/Outfitio/Outfit-Fonts). "
                + "Other bundled subtitle fonts are Lexend by The Lexend Project "
                + "Authors, Roboto by The Roboto Project Authors, Fredoka by "
                + "The Fredoka Project Authors, and OpenDyslexic by Abbie Gonzalez. "
                + "These fonts are used under the SIL Open Font License 1.1.",
            licenses: [.init("OFL-1.1", family: .ofl)]
        ),
    ]
}
