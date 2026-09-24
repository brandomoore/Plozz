<p align="center">
  <img src="https://raw.githubusercontent.com/brandomoore/brando/main/logos/plozz.svg" alt="Plozz logo" width="128" />
</p>

<h1 align="center">Plozz</h1>

<p align="center">
  A free, open source media player for <b>Jellyfin</b>, <b>Plex</b>, <b>Emby</b>, and <b>Silo</b> —
  native on Apple TV, iPhone, and iPad.
  <br />
  It also plays straight from network shares, so a folder of files works too.
</p>

<p align="center">
  <a href="https://plozz.app"><b>plozz.app</b></a>
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/EKfReNMu"><img src="docs/assets/testflight-button.png" alt="Join the Plozz public beta on TestFlight" width="264" /></a>
</p>

<p align="center">
  <a href="https://github.com/brandomoore/Plozz/releases"><img src="https://img.shields.io/github/v/release/brandomoore/Plozz?include_prereleases&sort=date&display_name=release&label=TestFlight%20beta&color=orange&logo=apple" alt="Latest TestFlight beta" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPL--3.0-blue.svg" alt="License: GPL-3.0" /></a>
  <a href="https://www.apple.com/apple-tv-4k/"><img src="https://img.shields.io/badge/Platform-tvOS%20%C2%B7%20iOS%20%C2%B7%20iPadOS-black.svg?logo=apple" alt="Platform: tvOS, iOS, iPadOS" /></a>
  <a href="https://github.com/sponsors/brandomoore"><img src="https://img.shields.io/badge/Donate-%E2%9D%A4-db61a2?logo=githubsponsors&logoColor=white" alt="Donate" /></a>
</p>

---

## A look at it

<p align="center">
  <img src="docs/assets/screenshots/tv-home.jpg" width="412" alt="The Plozz home screen, with a featured show and a Continue Watching row" />
  <img src="docs/assets/screenshots/tv-show.jpg" width="412" alt="A series detail page showing artwork, cast, ratings and episodes" />
</p>

<p align="center">
  <sub><b>Home</b> — one row set across every server you've connected.</sub>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <sub><b>Detail</b> — artwork, ratings, cast and episodes, filled in automatically.</sub>
</p>

<p align="center">
  <img src="docs/assets/screenshots/tv-player.jpg" width="412" alt="The Plozz player showing an episode with the transport bar visible" />
  <img src="docs/assets/screenshots/tv-settings.jpg" width="412" alt="Plozz settings, showing a library sync in progress and the settings list" />
</p>

<p align="center">
  <sub><b>Player</b> — plays essentially anything, with real subtitle control.</sub>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <sub><b>Settings</b> — per-profile, and there is a lot you can change.</sub>
</p>

<p align="center"><sub>More screens, including iPhone and iPad, are on <a href="https://plozz.app">plozz.app</a>.</sub></p>

## What it is

Plozz plays the movies, shows, and music on **your** server, on your Apple TV,
iPhone, and iPad. It's free and open source.

It talks to Jellyfin, Plex, Emby, and Silo, and it can read a plain network share
directly if you don't run a server at all. Connect more than one and Plozz
can bring them together in one library, while keeping individual libraries
available when you want them.

## Features

### Your servers, together

- **Jellyfin, Plex, Emby, and native Silo** — connect directly to your media
  servers. Silo uses its native API, not its Jellyfin-compatibility connection:
  approve the device in your browser, choose a Silo profile, and keep that
  profile's library access, watch history, and watchlist.
- **Network shares too** — SMB, NFS, WebDAV, SFTP, and FTP. A bare folder of
  files becomes a real library with artwork, descriptions, ratings, and cast.
  Browse folders as grids on both iOS and tvOS, with recognized movies and
  shows opening their usual details, seasons, and episodes.
  Recognized titles stay in detail navigation during library scans. Choose
  **More actions > Browse Files** on a title to inspect its original folders
  and individual files; unknown or mixed folders remain browsable grids.
  Choose movie, TV, mixed, or personal-video content, with a separate anime
  option. Personal videos stay as files without movie or TV matching.
  Library scans run while the app is active: normal passes skip unchanged
  folders, while a daily deep pass (or **Scan now**) rechecks all contents,
  including changes a server's folder timestamps cannot reveal.
  (Share support is still evolving during the beta.)
- **One merged library** — connect several servers and see one set of rows
  instead of picking a server first.
- **Jump to a letter** — an A–Z menu for name-sorted individual and combined
  Plex, Jellyfin, Emby, and Silo libraries, on all three platforms. Apple TV also
  has a fast-scroll letter rail. Deep Silo and combined-library jumps load on
  demand, show progress, and can be cancelled without losing your place.
  Other sorts and collection-member lists keep their own ordering.
- **Common Sense Media in Ratings** — Plex movie and show details can display
  a recommended age independently of review scores, with separate detail-header
  controls for each. Open the tile for topic-by-topic guidance when the viewing
  Plex account has eligible Plex Pass access.
- **Sync watch history across servers** — optional, and off until you ask for it.
- **Found automatically** — Plozz looks for Jellyfin, Emby, Silo, and Seerr
  servers on your local network. Silo discovery checks its standard port 8090;
  custom ports, remote addresses, and reverse-proxy paths can be entered manually.
- **Server sign-in** — Jellyfin **Quick Connect**, Plex **Link**, and
  Silo **browser approval**. Emby also supports password sign-in.

### Watching

- **Continue Watching without an app-imposed cutoff** — all titles supplied by
  your servers remain reachable, ordered by recency. Older next-up episodes move
  back instead of disappearing; server settings and your removals still apply.
- **Plays essentially anything** — HDR, Dolby Vision, AV1, and the awkward files
  other clients hand back to you, powered by
  [AetherEngine](https://github.com/superuser404notfound/AetherEngine).
  ([The full format list](https://github.com/superuser404notfound/AetherEngine/blob/main/docs/formats.md).)
- **Change versions without leaving the player** — switch between files or
  editions on the active server on Apple TV, iPhone, and iPad. Keep your
  playback position, pause state, speed, quality limit, and matching audio and
  subtitle choices. Different cuts can have different timelines; switching
  never silently picks another edition or server.
- **Control streaming quality on iPhone and iPad** — choose a preset or a
  custom resolution and total bitrate limit for Plex, Jellyfin, Emby, and Silo
  movies and episodes. Save separate per-profile defaults for local networks,
  remote Wi-Fi/Ethernet, and cellular, or change just the current video.
  Maximum is the local/remote default; cellular starts at 720p / 2 Mbps.
  The original plays when it fits the limit; otherwise the server converts it.
  Codec preferences and forced conversion are available where supported;
  conversion can change HDR and audio formats.
  These controls are separate from downloads and don't apply to Apple TV,
  music, Live TV, or file shares.
- **Know what is actually playing** — Info and streaming-quality details show
  measured dimensions, video/audio formats, and known dynamic range for the
  current converted stream. Playback diagnostics keep the original file,
  selected limit, stream bitrate, and network throughput distinct. A source
  badge is not a claim about the TV's HDMI output mode.
- **Subtitles you can actually read** — change font, size, weight, colour,
  opacity, background, shadow, position, and HDR brightness from inside the
  player. Position adjusts in 0.5% steps from -5% to 100%, with consistent sizing
  across fonts. 0% aligns to the bottom edge, 100% to the top; negative values allow cropping.
  Extra Line Position (Above, Center, or Below) controls how additional lines
  expand. Above is the default.
- **Two subtitle tracks at once** — for learning a language, or for a household
  that doesn't share one.
- **Find subtitles in the player** — search and download through supported
  servers' subtitle services, including native Silo, with language and
  accessibility preferences.
- **Mark as watched** — a whole season, or everything up to a given episode.
- **Watched and unwatched indicators** — a checkmark, or an unwatched corner
  badge in the Infuse / classic-Plex style, on every poster.

Streaming capabilities depend on the server and its configuration. Silo's
current native API supports H.264 conversion at 480p, 720p, 1080p, and 4K;
unsupported 240p/1440p and HEVC **conversion** choices are unavailable.
This does not prevent playing an existing HEVC file. Custom bitrate limits
include audio. Plozz checks Silo's returned playback plan against the selected
limits and refuses an incompatible plan rather than quietly using Maximum.

### Take it offline

- **Downloads on iPhone and iPad** — save movies and episodes for playback
  without a server connection, with local artwork and metadata for browsing.
  Native Silo downloads are supported too; they use the server's download
  permissions and preparation options, not a temporary playback link.
- **Choose download quality separately** — streaming preferences don't change
  your saved download settings. Available renditions and background-transfer
  behavior depend on the provider. Apple TV does not offer offline downloads.

### Music

- **Your Plex, Jellyfin, or Emby music library too** — browse albums and
  artists, queue things up, and keep listening with a mini-player while you
  carry on browsing. Audio keeps playing in the background.

### Live TV

- **Your own channels and guide** — combine M3U playlists, optional XMLTV
  guides, and authorized Plex, Jellyfin, or Emby Live TV channels on Apple TV,
  iPhone, and iPad. Search the guide, save favorites, and return to recently
  watched channels.
- **Multiview and library channels** — watch several channels together or
  build a scheduled lineup from your own library.

Live TV is still experimental. Native Silo Live TV integration is not offered,
and Plozz does not supply channels or an IPTV subscription.
[Live TV setup and capabilities](docs/live-tv-prototype.md).

### Make it yours

- **Themes** — light, dark, or Pure Black.
- **Layout** — change how dense the rows are, whether the big hero banner shows
  at all, and how navigation behaves.
- **Profiles on every device** — keep library choices, layout, playback, and
  subtitle preferences with the active Plozz profile. Apple TV system-user
  support and Plex Home/Silo server-profile selection keep the right identity
  in view. Server-side access and watch history still belong to the server user
  you choose; device-wide settings remain device-wide.
- **Set up another device** — use nearby-device setup, a QR code, or a pairing
  code to import an existing setup. iCloud sync carries profiles, settings, and
  server details; Silo asks you to approve each receiving device independently.
  Servers still needing sign-in remain available in **Settings > iCloud Sync**
  rather than disappearing from the import.
- **Circadian mode** — warms and dims the app at times you choose, so late-night
  viewing isn't a floodlight.

### Connected services

- **Trackers** — Trakt, AniList, MyAnimeList, Simkl, and Last.fm, across movies,
  TV, anime, and music.
- **Seerr** — request something you don't have without leaving search.

Seerr profile links belong to the server where you chose that user. Reconnecting
to the same address, including after an API-key change, keeps those links.
Switching servers requires relinking in Settings; requests never fall back to
the administrator because a link is stale. Links saved by older versions need
one confirmation. After replacing a Seerr database at the same address, relink
profiles manually.

TV requests track each season separately. The request button summarizes pending
or processing seasons, while its menu shows individual season states and offers
only missing, unrequested seasons. Requesting one season never marks the whole
series as requested; failed requests remain visible for attention in Seerr.

## Getting started

Plozz is in **public beta** on TestFlight.
[**Join the beta**](https://testflight.apple.com/join/EKfReNMu) and it installs
on your Apple TV, iPhone, and iPad.

You'll need an Apple TV, iPhone, or iPad running tvOS/iOS/iPadOS 18 or later,
plus a Jellyfin, Plex, Emby, or Silo server—or a network share—with your own
media on it. Plozz will offer to set up compatible servers it finds, and you can
enter an address for anything it can't discover.

Plozz itself is free. Server-side permissions, hardware, configuration, and any
provider subscription requirements still apply to features such as conversion
or detailed Plex family guidance.

## Found a bug? Want something?

[**Open an issue**](https://github.com/brandomoore/Plozz/issues/new/choose) and pick
a template — 🐞 **Bug report** or ✨ **Feature request**. Bug reports are read and
they do get fixed; feature requests genuinely shape what gets built next.

Please don't paste tokens, passwords, or credentialed server URLs into an issue.

## Contributing

Pull requests are welcome. Building the app, running the tests, the module
layout, how localization works, and the release process are all in
[**CONTRIBUTING.md**](CONTRIBUTING.md), with the deeper notes in
[`docs/`](docs/).

## Donate

Plozz will always be free and open source, with no paywall, ads, or obligation.
If it's useful to you, donations toward upkeep are welcome — and not donating is
completely okay.

**[Donate via GitHub Sponsors](https://github.com/sponsors/brandomoore)** — one-time
or recurring.

## Credits & attribution

Plozz is an unofficial client and is not affiliated with, endorsed, or certified
by any of the services below.

- **AetherEngine** — on-device playback engine (FFmpeg demux → VideoToolbox
  decode) by Vincent Herbst, LGPL-3.0 with an App Store exception.
  [superuser404notfound/AetherEngine](https://github.com/superuser404notfound/AetherEngine).
  Its bundled FFmpeg is a decode-only, LGPL-3.0 build (see [`NOTICE.md`](NOTICE.md)).
- **The Movie Database (TMDB)** — some artwork and metadata is provided by the
  TMDB API. This product uses the TMDB API but is not endorsed or certified by
  TMDB. TMDB's marks and logos are trademarks of TMDB.

  <a href="https://www.themoviedb.org"><img src="https://www.themoviedb.org/assets/2/v4/logos/v2/blue_short-8e7b30f73a4020692ccca9c88bafe5dcb6f8a62a4c6bc55cd9ba82bb2cd95f6c.svg" alt="The Movie Database (TMDB)" height="24" /></a>

- **[TheTVDB](https://thetvdb.com)** — some metadata and artwork is provided by
  TheTVDB. Please consider adding missing information or subscribing at
  [thetvdb.com](https://thetvdb.com). This product uses the TheTVDB API but is
  not endorsed or certified by TheTVDB.

  <a href="https://thetvdb.com/subscribe"><img src="https://www.thetvdb.com/images/attribution/logo1.png" alt="TheTVDB" height="24" /></a>

- **OMDb API** — optional IMDb ratings enrichment (requires your own OMDb key).
- **AniList** — keyless community scores for anime titles.
- **Plex**, **Jellyfin**, **Emby**, and **Silo** — compatible media servers.
  Plozz does not supply media; you bring your own library. Names and logos belong
  to their respective owners.

## License

[GPL-3.0](LICENSE), with an [App Store Exception](LICENSE-EXCEPTION.md)
© 2026 Brandon Moore

<!-- app-family:start -->
<!-- Generated by https://github.com/brandomoore/brando — edit apps.json there, not this block. -->

---

<p align="center"><b>More open source</b></p>

<p align="center">
  <a href="https://github.com/brandomoore/hozz" title="Hozz — Apple Health, exported to storage you own"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/brandomoore/brando/main/logos/lockups/hozz-dark.svg" /><img src="https://raw.githubusercontent.com/brandomoore/brando/main/logos/lockups/hozz-light.svg" height="40" alt="Hozz" /></picture></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/brandomoore/Mozz" title="Mozz — Your music, wherever it lives"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/brandomoore/brando/main/logos/lockups/mozz-dark.svg" /><img src="https://raw.githubusercontent.com/brandomoore/brando/main/logos/lockups/mozz-light.svg" height="40" alt="Mozz" /></picture></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/brandomoore/Plozz" title="Plozz — Movies &amp; TV on Apple TV, iPhone &amp; iPad"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/brandomoore/brando/main/logos/lockups/plozz-dark.svg" /><img src="https://raw.githubusercontent.com/brandomoore/brando/main/logos/lockups/plozz-light.svg" height="40" alt="Plozz" /></picture></a>
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <a href="https://github.com/brandomoore/Twozz" title="Twozz — Twitch on Apple TV, with real emotes"><picture><source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/brandomoore/brando/main/logos/lockups/twozz-dark.svg" /><img src="https://raw.githubusercontent.com/brandomoore/brando/main/logos/lockups/twozz-light.svg" height="40" alt="Twozz" /></picture></a>
</p>

<p align="center">
  <a href="https://brando.page">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/brandomoore/brando/main/logos/brando-white.svg" />
      <img src="https://raw.githubusercontent.com/brandomoore/brando/main/logos/brando-black.svg" height="22" alt="Brandon Moore" />
    </picture>
  </a>
</p>
<!-- app-family:end -->
