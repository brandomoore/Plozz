# FeatureMusic

Music browsing (artists / albums / tracks) and an app-scoped audio
player that is **independent** of the full-screen video `PlayerViewModel`,
so audio keeps playing as the user navigates the rest of the app.
The Music tab is currently integrated into the tvOS shell, not the iOS/iPadOS
shell.

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
- **Pending selection wins over outgoing completion.** If the old track ends
  while a selected track is resolving or buffering, report the old track's
  completion without advancing away from the requested selection. End events
  must belong to the actual current player item; the newly playing track still
  advances normally after the handoff.

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
