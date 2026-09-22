<p align="center">
  <img src="https://raw.githubusercontent.com/brandomoore/brando/main/logos/plozz.svg" alt="Plozz logo" width="128" />
</p>

<h1 align="center">Plozz</h1>

<p align="center">
  A free, open source media player for <b>Jellyfin</b>, <b>Plex</b>, and <b>Emby</b> —
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

It talks to Jellyfin, Plex, and Emby, and it can read a plain network share
directly if you don't run a server at all. Connect more than one and Plozz
presents them as a single library rather than a set of tabs you switch between.

## Features

### Your servers, together

- **Jellyfin, Plex, and Emby** — all three are first-class. Nothing is a
  second-tier afterthought bolted on later.
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
  (Shares are supported, but still the newest and roughest part.)
- **One merged library** — connect several servers and see one set of rows
  instead of picking a server first.
- **Jump to a letter** — name-sorted Plex, Jellyfin, Emby, and Silo libraries
  have an alphabet menu on Apple TV, iPhone, and iPad, including combined
  libraries. Apple TV also keeps its fast-scroll letter rail. Silo and combined
  libraries resolve exact positions on demand; a deep first jump may take time,
  can be cancelled, and leaves the current view in place until its titles load.
  TV menu selections move focus to the destination card; rail navigation keeps
  focus on the letters. While rows load, the rail stays visible without claiming
  an unverified current letter. Jump progress appears immediately in the shared
  status toast; **Cancel jump** remains available in the alphabet menu.
  Other sorts and collection-member lists keep their own ordering.
- **Common Sense Media in Ratings** — Plex movie and show details can display
  a prominent recommended age, separate from review scores. When header ratings
  are shown, they default to the age badge plus two available review scores. Open the tile for
  topic-by-topic guidance when the viewing account has eligible Plex Pass access.
- **Sync watch history across servers** — optional, and off until you ask for it.
- **Found automatically** — Plozz detects Jellyfin, Emby, and Seerr servers on
  your network so you don't type an address.
- **Sign in without the remote** — Jellyfin **Quick Connect**, Plex **Link**, and
  Emby password sign-in.

### Watching

- **Continue Watching without an app-imposed cutoff** — all titles supplied by
  your servers remain reachable, ordered by recency. Older next-up episodes move
  back instead of disappearing; server settings and your removals still apply.
- **Plays essentially anything** — HDR, Dolby Vision, AV1, and the awkward files
  other clients hand back to you, powered by
  [AetherEngine](https://github.com/superuser404notfound/AetherEngine).
  ([The full format list](https://github.com/superuser404notfound/AetherEngine/blob/main/docs/formats.md).)
- **Subtitles you can actually read** — change font, size, weight, colour,
  opacity, background, shadow, position, and HDR brightness from inside the
  player. Position adjusts in 0.5% steps from -5% to 100%, with consistent sizing
  across fonts. 0% aligns to the bottom edge, 100% to the top; negative values allow cropping.
  Extra Line Position (Above, Center, or Below) controls how additional lines
  expand. Above is the default.
- **Two subtitle tracks at once** — for learning a language, or for a household
  that doesn't share one.
- **Mark as watched** — a whole season, or everything up to a given episode.
- **Watched and unwatched indicators** — a checkmark, or an unwatched corner
  badge in the Infuse / classic-Plex style, on every poster.

### Music

- **Your music library too** — browse albums and artists, queue things up, and
  keep listening with a mini-player while you carry on browsing. Audio keeps
  playing in the background.

### Make it yours

- **Themes** — light, dark, or Pure Black.
- **Layout** — change how dense the rows are, whether the big hero banner shows
  at all, and how navigation behaves.
- **Profiles** — real Apple TV profile support. Every setting is per-profile, and
  Plozz remembers which one you were using.
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

You'll need one of: a Jellyfin, Plex, or Emby server, or a network share with
your media on it. Plozz will offer to set up whichever it finds.

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
- **Plex**, **Jellyfin**, and **Emby** — the media servers Plozz connects to. All
  library content, artwork, and ratings shown in the app are supplied by your own
  server. Those names are trademarks of their respective owners.

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
