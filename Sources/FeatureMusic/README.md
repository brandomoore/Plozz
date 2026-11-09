# FeatureMusic

Music browsing (artists / albums / tracks) and an app-scoped audio
player that is **independent** of the full-screen video `PlayerViewModel`,
so audio keeps playing as the user navigates the rest of the app.
The Music tab is integrated into the tvOS shell and, in development/TestFlight
builds only, the iOS/iPadOS shell. App Store builds do not create the mobile
music runtime or probe music libraries.

## Responsibility

- **Browse UI** — `MusicTabView`, `MusicScreens`, `MusicViewModels`,
  `MusicAggregator`: artist / album / track screens that aggregate
  across the active accounts via `MediaProvider`.
- **Audio engine** — `AudioPlaybackController`:
  - owns a single long-lived `AVQueuePlayer` + manually-managed queue so it
    can resolve each track's stream URL on demand and support shuffle /
    repeat / next / previous; the upcoming track is resolved and
    *pre-enqueued* behind the current one (the "treadmill") so it prerolls
    while the current song plays, and track changes advance the queue
    (`advanceToNextItem()`) onto that already-buffered item rather than
    emptying/replacing the item, so the output route stays alive across songs
    (keeps AirPlay 2 from dropping to silence on skip); route-change /
    interruption observers recover playback if the system parks it after a
    jump the treadmill couldn't preroll;
  - configures `AVAudioSession` `.playback` + `setActive(true)` so audio
    keeps playing across screens / screensaver;
  - publishes `MPNowPlayingInfoCenter` (title / artist / album / artwork
    / duration) and registers `MPRemoteCommandCenter` handlers so Siri
    Remote play/pause/skip and tvOS Control Center work.
- **Mini-player & Now Playing** — `MiniPlayerView` + `NowPlayingView`
  observe the **same** injected `AudioPlaybackController` instance from
  the environment on tvOS. `iOS/` ports the Mozz player presentation onto this
  same engine on iPhone/iPad; it does not introduce another playback engine.
- **Artwork** — `MusicArtworkImage` + `MusicCard` render through
  `CoreUI.FallbackAsyncImage`. Server art is always tried first; if it's
  missing, `MusicArtworkFallback` produces an async closure that asks
  `MetadataKit.ArtworkRouter` for a Deezer / Cover Art Archive image.
  One provider path, one cache.

## Invariants

- **Independent of video playback.** `AudioPlaybackController` and
  `FeaturePlayback.PlayerViewModel` are separate lifecycles. They must
  not share state, AVPlayer instances, or audio session ownership in a
  way that causes one to interrupt the other unexpectedly.
- **Single shared controller.** The mini-player and Now Playing screen
  observe the same `AudioPlaybackController` injected at `AppShell`.
- **Server art first.** `MetadataKit` art is a fallback, not the
  default.
- **Dual-provider.** Browsing works against both Plex and Jellyfin via
  `MediaProvider` / `JellyfinMusicProvider`.
- **Discovery failures are not empty libraries.** Retain cached availability for
  failed active accounts, while immediately applying disabled/removed accounts.
  Retry transient discovery failures twice (2s/8s); foreground activation and
  credential changes trigger a fresh probe. Cancelled/superseded probes cannot
  publish late results.
- **Playlist occurrences are distinct.** Preserve authored order and repeated
  songs. `MusicTrack.playlistEntryID` identifies a loaded occurrence for selection
  and shuffle; `id` remains the provider media ID used for playback/reporting.
- **Reporting owns its original sinks.** Capture provider and scrobble callbacks
  before a queue handoff and deliver lifecycle events in order, asynchronously
  from playback. Pending heartbeats coalesce and are discarded on stop; each
  account has an independent reporting lane so an offline server cannot delay a
  healthy one. Last.fm has its own globally ordered lane, independent of provider
  delivery. A delayed stop must never target the incoming provider.
- **Pending selection wins over outgoing completion.** If the old track ends
  while a selected track is resolving or buffering, report the old track's
  completion without advancing away from the requested selection. End events
  must belong to the actual current player item; the newly playing track still
  advances normally after the handoff.
- **Local mobile selections retire the old song immediately.** Stop/report the
  outgoing song before resetting progress, including explicit queue replacements.
  Keep the pending target's scrubber at zero until its item is installed; failed
  resolution and pause/resume must not revive the outgoing item. Local mobile
  output advances immediately without the HomePod prebuffer/debounce/session
  restart. tvOS (including invisible home-theater forwarding) and explicit mobile
  AirPlay retain the buffered route-preserving handoff.
- **Metadata is not playback readiness.** Mobile system artwork loads off the
  transport path. Duration and artwork completions cannot publish across a newer
  selection; cancelled readiness waits exit instead of spinning until timeout.
- **Queue edits preserve the playing occurrence.** Reordering uses final
  positions relative to Up Next. Clearing history or upcoming tracks also
  updates the unshuffled order, and invalidates only the prepared next item.
- **Mobile authorization is live.** Profile, server-user/credential, offline
  mode and enabled-library changes invalidate the runtime, pending feedback
  writes, navigation and playback. Player feedback is keyed by account and
  provider track ID, never by display title.

## iOS music player

The presentation is ported from `brandomoore/Mozz` revision
`58dab0015d09a4978f2c484e072d1bc0e30f69dc`; see `iOS/Mozz-NOTICE.txt`.
The original morphing island/drawer, artwork transitions, press feedback,
transport glyph motion, scrubbing, queue reordering and immersive lyrics
presentation are retained. The host remains Plozz's native navigation rather
than Mozz's separate split tab bar.
Its light/dark monochrome accent is scoped to the player, including navigation
menus and active controls; the surrounding app keeps its own accent color.
The mobile shell reserves dock clearance only for a visible native bottom tab
bar, measured from its actual placement. iPad top tabs and sidebars leave the
dock near the bottom edge; compact windows with bottom tabs retain clearance.
The bridge observes the native bar's attachment and layout, including detachments
that occur after its child controller's layout callback during window resizing.
Every mobile tab's navigation container reserves the dock's full bottom
obstruction, including its tap area, after subtracting the native safe-area
inset. The reservation follows pushed detail pages as well as root lists and
grids, and disappears when playback stops or the music session is unauthorized.
The overlay stays outside that reservation so its position does not move.
Both docks emphasize play/pause (30-point glyph) over previous/next (22 in the
wide dock, 24 in the compact dock) and shuffle/repeat (18), without changing
control spacing or hit regions.
Both dock sizes reuse the expanded player's scaling play/pause transition and
press feedback. Play/pause retains its press scaling and haptics without a
circular background highlight, in both the docks and expanded player.
Mobile player appearance is configured under Settings → Screens & Navigation →
Music player. Explicit choices override the app theme; Match Theme resolves the
active palette, including Pure Black and system/circadian light or dark changes.
The collapsed dock always inherits the app's color scheme and native regular
Liquid Glass, matching the tab bar. Player-specific colors apply only to the
expanded backdrop and controls, not the dock's glass or text. Existing reduced
transparency and low-power fallbacks remain unchanged.
Measured artwork positions retain the panel spring when lyrics
or the queue shifts the wide player, rather than snapping after layout. The
existing Reduce Motion path keeps these transitions immediate.

Mobile album, artist and playlist details borrow Mozz's artwork-led presentation:
centered album/playlist covers on compact screens, horizontal heroes on wider screens,
an image-led artist header, and compact divided album tracks. Native Play and
Shuffle actions keep the existing provider/account-scoped playback path.
Playlists retain lazy artwork-and-artist rows, bounded thumbnail prefetch,
playlist-entry selection identity, and a neutral current-track highlight.
`iOS/MobileMusicDetail.swift` caps content width at 1,000 points and stacks the
hero/actions at accessibility text sizes. Page headings scroll with content;
Plozz's native navigation bar and back gesture remain in place.
As in Mozz, compact heroes extend through the top safe area; wide framed heroes
fade from the deep page color into the artwork color. Only foreground content
clears the native navigation inset, avoiding a separate dark navigation band.
Native back controls remain, without an additional navigation-bar background or
iOS 26 top-edge scrim over the hero.

The detail backdrop uses the same policy-resolved, cached bitmap as its hero,
with a dark two-tone palette that keeps text legible. These immersive pages use
dark foreground styling even in the light app theme; Pure Black uses a black
background and framed artwork. Reduce Motion disables artist overscroll stretch
and the active-track equalizer animation. Playlist, video, and tvOS details are
unchanged. No artist top-song fetching, downloads, or radio were added.
The presentation host's `--music-detail-fixture` opens the album preview;
`--music-artist`, `--music-light`, `--music-oled`, `--music-no-art`, and
`--music-large-text` exercise its detail variants without a server account.

`MusicPlayerSession` bridges the presentation to Plozz's audio controller,
profile-scoped appearance and shared artwork/lyrics services. Plex exposes
five-star ratings (translated to its ten-point API scale); Jellyfin/Emby expose
favorites. Writes are serialized per account-qualified track and failed
optimistic changes roll back. Unsupported feedback controls are omitted.
Album/artist actions retain their originating account when opening the Music
stack. Mozz downloads, radio, library synchronization and account storage are
not imported.

Mobile browsing reuses the tvOS view models and provider aggregation with
touch-sized cards and vertically scrolling detail pages. The landing page uses
20-point content margins, Dynamic Type section headings, and one horizontally
scrolling row of compact native Liquid Glass category pills on iOS 26+.
Older systems and reduced-transparency/panel-glass settings retain the native
bordered fallback. Glass appearance follows the system preference without a
custom material, fill, or border. The pills use the theme's neutral
foreground (white in dark themes), not the app accent; they still open their
existing grids rather than behaving as selection filters. Rail headings and
first/last artwork align with those margins; tvOS keeps its title-safe insets
and focus clearance. Category grids share the mobile content margin.
`--music-landing-fixture` previews this layout in the presentation host, including
the `--music-light`, `--music-oled`, and `--music-large-text` variants.
Reduced-motion and
reduced-transparency preferences remain effective. The port's source copy is
not yet part of the reviewed translation pipeline.

`MusicPlayerPresentationTests` covers feedback rollback and delayed authorization,
mobile navigation gating, player accent isolation, and mounted expand/collapse/skip presentation. For a
local visual check, launch `PlozziOSPresentationHost` with
`--music-player-fixture` (add `--music-expanded` to start expanded). Add
`--music-light` or `--music-oled` to inspect those player appearances. The fixture
uses generated silent audio and navigable track labels without connecting to a media server.

## Where to look first

- `AudioPlaybackController.swift` — the queue / session / remote-command
  / Now-Playing wiring.
- `MusicArtworkFallback.swift` — how `MetadataKit` art is plugged in.
- `MusicViewModels.swift` — screen state coordination.

## AirPlay 2 / HomePod audio-drop recovery

Seeks, skips, and network blips could silently drop audio on a HomePod over
AirPlay 2. The root cause (progressive-download `AVPlayer` items forcing an
AirPlay stream renegotiation) and every mechanism that fixed it — the
deactivate→reactivate session cycle, gapless-vs-reactivate gating, the `.failed`
retry, and the self-heal watchdog — are documented in
[`docs/airplay-audio-recovery.md`](../../docs/airplay-audio-recovery.md). Read it
before touching the transition/seek/recovery paths in `AudioPlaybackController`.

## FLAC playback

Plex and Jellyfin/Emby advertise native FLAC music playback. The shared
`AudioPlaybackController` plays the original stream through `AVQueuePlayer`;
server bandwidth limits can still require transcoding. Source format does not
guarantee bit-perfect output: the audio session, output route, and receiver
determine the output format.

`FLACMusicPlaybackHostedTests` runs in the tvOS hosted presentation suite. Synthetic
stereo 16-bit/44.1 kHz and 24-bit/96 kHz fixtures cover local decoding, real HTTP
byte-range playback (including extensionless universal-audio URLs), pause/resume,
seek, manual queue changes, and natural end-of-track advancement. Assertions
inspect the actual player clock and audio format, not just optimistic UI state.
The test publisher mutes speaker output while retaining the real player/session.
Provider tests separately verify authenticated original-file selection and
native quality metadata. These checks do not establish physical-device or
AirPlay output fidelity.

The shared `Tests/SubtitlePresentationSupport/Fixtures/music-flac-*.flac` tones
contain no music or third-party recordings. Regenerate them with:

```sh
ffmpeg -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=8' -ac 2 -c:a flac -sample_fmt s16 -map_metadata -1 Tests/SubtitlePresentationSupport/Fixtures/music-flac-16-44100.flac
ffmpeg -f lavfi -i 'sine=frequency=660:sample_rate=96000:duration=8' -ac 2 -c:a flac -sample_fmt s32 -bits_per_raw_sample 24 -map_metadata -1 Tests/SubtitlePresentationSupport/Fixtures/music-flac-24-96000.flac
```
