# FeatureMusic

Music browsing (artists / albums / tracks) and an app-scoped audio
player that is **independent** of the full-screen video `PlayerViewModel`,
so audio keeps playing as the user navigates the rest of the app.

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
  the environment.
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
