# FeaturePlayback

Aether-primary playback coordination, engine-agnostic playback surface, resume
reporting back to the server, caption style rules, trickplay scrubbing,
and the diagnostics overlay.

The optional tracker-playback callback carries actual engine-clock evidence at
bounded checkpoints and final stop, independently of server progress reports.
It retains one viewing identity across engine/request recovery, ignores metadata
runtime as evidence, and honors ordinary-watch suppression. App composition
captures profile, server viewer and opt-in tracker consent before playback.

## Responsibility

Automatic on-demand subtitle selection applies the profile's **SDH subtitles**
preference to embedded tracks and external files, including network shares and
offline playback. Prefer SDH falls back to regular subtitles in the chosen
language; Only SDH is strict, including remote search/download. Full dialogue
still outranks forced-only passages unless the subtitle mode is Forced Only.
Manual choices and remembered Off take precedence. Server conversion, native
rendition matching, and bitmap-engine routing preserve the selected SDH class.
Provider flags and explicit SDH/CC track titles identify accessibility tracks;
unlabelled content cannot be assumed to contain SDH cues.
The debug playback journal records each automatic subtitle decision, including
the effective SDH preference, remembered-choice precedence, selected track, and
bounded language-match/accessibility flags without track titles or URLs.

- **Engine abstraction** — `VideoEngine` protocol + the two seam files:
  - `NativeVideoEngine` — the always-shipped AVPlayer-backed engine.
  - `EngineFactory` — closure-based factory that the composition root
    (`AppShell`) wires up. The on-device decode engine (Plozzigen /
    AetherEngine) is injected here as a closure, so `FeaturePlayback`
    never imports `EnginePlozzigen` directly. This keeps the dependency on
    the FFmpeg xcframeworks out of the rest of the app.
  - `EngineSelection` chooses Aether without codec/container/subtitle gates.
    Native owns OS-managed download packages, separate trailer audio, and the
    constrained HEVC-HLS initialization repair; bounded recovery is retained.
    The adapter loads the server-selected source, never a preview-only original.
    See [playback engines](../../docs/playback-engines.md#routing-logic).
- **View model / view** —
  - `PlayerViewModel` orchestrates engine lifecycle, audio/subtitle
    selection, scrub state, resume, and progress reporting.
  - `PlayerView` + `CustomPlayerContainer` host the engine's vended
    bare video surface and overlay the shared transport chrome.
- **Subtitle rendering** — `SubtitleOverlayView` draws in-app captions from
  sidecars, Plozzigen decoders, and `NativeSubtitleCueOutput` for native legible
  tracks. `SubtitleStyleRules` remains the reduced AVPlayer styling adapter
  for system-owned external presentation.
- **Native-only video assets** — when that engine is selected, tvOS feeds the resolved URL directly to
  AVPlayer even when sidecars are available. Track menus still use provider
  tracks; the owned overlay authorizes and fetches selected SRT/WebVTT sidecars.
  Embedded captions retain native cue extraction. iOS keeps the existing
  `SubtitleHLSComposer` / `SubtitleInjectingResourceLoader` path; real provider
  HLS, trailer audio composition, and Plozzigen are unchanged.
- **Trickplay scrubbing** — `ScrubGeometry`, `ScrubThumbnailProviding`,
  `TrickplayThumbnailLoader`, `PlexBIFThumbnailLoader`: focus-driven
  scrub bar with per-provider thumbnail loaders (Jellyfin "trickplay"
  PNG/JPG tiles + Plex BIF). When the server has neither,
  `GeneratedScrubThumbnailLoader` decodes keyframe stills on the device from
  the original file through `ScrubStillExtracting`, which Plozzigen supplies
  via `EngineFactory.makeScrubStillExtractor`. Pending requests in the same
  two-second cell share one decode. Playback teardown invalidates stills and
  closes every network-reader clone before awaiting transport drainage, even
  while the outgoing preview view remains mounted. Original-quality Plex,
  Jellyfin, and Emby transcodes retain a preview-only original source; reduced
  streaming quality and offline playback never use it. Missing BIFs (404/410)
  fall back permanently, while timeout/rate-limit responses remain retryable.
- **Diagnostics** — `PlaybackDiagnosticsSampler` +
  `PlaybackDiagnosticsOverlay`: opt-in HUD with engine, codec, bitrate,
  dropped frames, etc. The Aether adapter supplies `AetherEngine v<version>`
  from the linked engine's public version API for both VOD and Live TV.
  Delivery stays a separate Direct Play/Remux/Transcode fact.
  `PlaybackDiagnosticJournal` separately retains bounded lifecycle and typed
  failure evidence for Settings' consent-gated Send diagnostics action. Recording
  is event-driven, disk work is off-main, and no HUD polling is enabled by it.
  On-demand failures retain quality/codec preference, source range, failure
  stage, first-frame state and the selected route. A native item is pinned
  before retry/teardown; the shared `NativePlaybackFailureCapture` reads its
  numeric error chain, last four error-log codes and latest access counters
  off-main, with a 500 ms deadline and at most two active readers. The initial
  failure explicitly marks a pending capture; its `failureEvidence` event keeps
  the original attempt even if playback has moved on. Missing, busy and timed-out
  captures remain distinguishable. No descriptions, addresses, headers or
  identifiers from player logs are retained. Export can report a still-pending
  capture rather than block the UI or imply complete evidence.
- **Display matching** — `DolbyVisionDisplayCriteria` /
  `IdleSleepGuard`: AVKit display-criteria match + platform-specific keep-awake.
  Mobile playback owns a foreground presentation lease through startup and
  buffering; pause, failure, EOF, backgrounding, and dismissal release it.
  tvOS continues to follow actual engine playback.

## Live channel recovery

Live video dimensions are sampled by the existing player monitor and passed as
an explicit input to the retained video surface. A late aspect ratio or a format
change updates Normal/Crop/Stretch geometry without a zoom gesture, retuning, or
resizing the subtitle overlay; no additional polling loop is created.

On iPhone and iPad, the Live TV guide's inline preview uses the shared
previous/play-pause/next controls and an in-place fullscreen action.
Fullscreen also exposes a bottom-trailing inward-arrow action to return to the
preview, matching the expand control's placement; the top-left Close remains.
Mobile fullscreen video fits the full player bounds, independently of the safe
area used by controls and subtitles. Showing or hiding controls does not resize
the picture. The status bar and persistent system overlays hide with the
fullscreen controls and return when controls are revealed or fullscreen ends.
The engine, video surface, and its native parent remain mounted across expansion, return,
and rotation. Dark inline previews mirror that same compositor surface above, below,
and into available side gutters with native blur and gradual transparency fades.
Light pages instead use a bright, hue-derived gradient, not dark mirrored pixels.
At most twice per second, a scoped native video output or the software renderer's
borrowed enqueued frame supplies a 24-by-14 color sample. Core Image reduction runs
off the main actor; three gradient colors crossfade without per-frame SwiftUI updates.
There is no second player, decoder, demuxer, or software display readback. The software
sample can lead the picture by its render queue. Black/neutral areas add no invented hue.
Source generations reject stale asynchronous results, paused pictures do not resample,
and hidden/detached/background previews release their output and sampling task.
The production `LibraryLiveChannelEngine` wrapper forwards frame readiness and
software-frame access only for its current, ready source; direct-decoder tests
alone do not cover this Live TV integration boundary.
Pictures with space on both horizontal sides use the shared content corner radius.
The glow follows the page theme independently of dark player controls. Dark pages
retain their original reflection treatment without sampling, fading its surrounding
mask in and out over 0.6 seconds without changing the playing picture's opacity.
Both appearances keep reflection bounds during channel changes and retarget
interrupted fades from the currently displayed state. Glow colors fade
in, out, and between palettes over 0.6 seconds, retargeting from their currently
displayed colors if interrupted. Channel changes stop sampling immediately but
keep the light-mode glow's bounds while its old colors fade out; no decoded
frame is retained for the fade. Reduce Motion disables these color animations.
Leaving the visible inline presentation clears its colors and animations immediately.
Fullscreen, multiview, external playback, and Reduce Transparency disable the reflection. Reduce
Transparency retains inset-picture rounding; fullscreen restores the unmasked,
black-backed video surface.

When loading a new mobile native source, disconnect the outgoing player from
the retained `AVPlayerLayer` before teardown and replacement. Retuning must
present real video frames on that same surface, including on iOS 27.1.

On tvOS, temporary scene inactivity from Control Center or Siri does not issue
a player pause, cancel a live seek, or reload the stream. Playback and explicit
pause intent survive the overlay; genuine system audio interruptions remain
engine/OS-owned. Actual background entry (Home, sleep, or switching apps) still
checkpoints and suspends VOD and tears down live playback. Foreground recovery
keeps its existing play/pause policy. iOS/iPadOS inactivity, PiP, AirPlay, and
background-audio behavior are unchanged.

Live source-reset recovery retains its three-attempt cap and 20-second minimum
spacing. `LiveChannelRetuneBudget` replenishes attempts only after five minutes
of observed playing state, a presented frame and advancing playback position.
Pause, suspension, buffering, seeking, new loads and missing/stale clock samples
discard healthy credit. The existing monitor samples this policy; no additional
watchdog, periodic reload or engine-phase inference is added. See
[Live TV reliability](../../docs/live-tv-reliability.md).

## Player appearance

On tvOS, iPhone, and iPad, **Chapters** joins the bottom player tabs only when the
server metadata or the playing file supplies usable chapter positions. Individual
chapter cards use Cast's shared over-video glass, focus treatment, and reduced-effects
fallback without an enclosing panel. Their leading edges align with the player tabs;
horizontal cards match Cast and Info's panel height and corner radius. When no chapters
have thumbnails, portrait rows show left-aligned text without an artwork placeholder,
and wide layouts vertically center that text in narrow, full-height glass cards.
Text-only cards use Cast's width with a minimum text allowance on small screens;
cards with thumbnails retain their wider artwork layout. Mixed-thumbnail lists
retain aligned artwork slots. On tvOS, artwork cards size their width from the
measured caption so thumbnails have equal top and side insets; the thumbnail's
continuous corner radius is the outer glass radius minus that inset.
Chapter titles and start times share one leading text
edge with corner-aware inner padding. They show titles (or numbered chapter labels),
start times, available server thumbnails, and the current chapter. On portrait iOS,
Cast and Chapters use the same tab-to-content gap as Info, with directional scroll
fades only at edges where more content remains.
Opening Chapters positions the current chapter without fading that first visible
row; its top fade activates only after a user scroll, not the initial automatic jump.
Selecting a chapter closes the panel and uses the normal
seek coordinator, preserving play/pause intent. Existing skip buttons and intro/
credits controls are unchanged. Mobile tabs scroll horizontally when needed.

Plex, Jellyfin, and Emby supply chapters through their existing playback metadata
requests; Emby intro/credit markers are excluded. Invalid, duplicate, and
out-of-duration positions are omitted. Missing thumbnails do not hide chapters.
Existing episode spoiler protection also applies to chapter names and images.
Usable server chapters take precedence, preserving their titles and thumbnails.
Otherwise, Plozzigen exposes container chapters from its existing file load (including
MKV/MP4 over network shares and direct URLs); native playback asynchronously reads
chapter metadata from the already authorized AVAsset, including local downloads.
This does not add a second file probe or fetch chapter metadata from external
services. Engine/load generation guards reject late results after replacement or
stop. Files without chapters still have no tab. Title-relative DVD/Blu-ray chapters
are not exposed by this container fallback.

On tvOS, the shared Audio menu offers **Reduce Loud Sounds** and **Enhance
Dialogue** when Apple TV reports support for the current output. These are
Apple TV-wide settings, not profile preferences or engine capabilities; VOD and
Live TV share one system-backed state, even with only one audio track.
Adjustments appear above the track list, separated by the shared panel divider
only when both groups are present. Long audio labels reuse the focus-driven player
menu marquee, preserving localized `Text` and the Reduce Motion fallback.
`SystemPlaybackAudio` uses the undocumented sound-preferences/distributed-
notification bridge, fails closed when it is unavailable, and requires bounded
state readback before showing a changed selection. Controls refresh while visible,
on route changes and on foreground return. No preference is changed on startup,
profile changes, or teardown, and Plozz never writes the system preference domain.
When tvOS reports dialogue-level support, **Enhance Dialogue** opens the existing
player-style submenu with **Enhance More**, **Enhance**, and **Off**. Outputs with
binary-only support keep a toggle. The tvOS Audio menu and its submenu use a
580-point width so the default English title and level fit on one line, without
widening other menus. A level change must confirm both enablement
and the requested strength; Back returns to the Audio menu. An existing Isolate
state is displayed accurately but is not offered without a verified signal for
its additional Accessibility gate.
This does not configure audio sessions, decoding, channel layouts, Atmos, Spatial
Audio or head tracking. System processing and its audible effect still depend on
the output/content; availability and preference acknowledgement are not proof of
processing for every engine route. Undocumented integration carries OS
compatibility and App Review risk. This system-preference bridge is tvOS-only.

On iPhone and iPad, VOD and Live TV share adaptive native `PlayerMoreMenuButton`
controls. Portrait uses one ellipsis; landscape exposes the available menus as
separate controls, with Version and Multiview opening their existing destinations
directly. Audio, Subtitles and Video reuse the existing player-category icons
(waveform, captions and adjustment sliders) in both VOD and Live TV. Community
timestamps follow the same menu/destination lifecycle for supported VOD items
with an available timestamp source; they remain absent from Live TV. Video combines
zoom choices with Quality in both layouts; Quality opens its existing editor and
never acts as a selectable zoom mode. The standalone Video popup omits its redundant
category heading; portrait retains the named Video entry. Quality remains
available in Video even when zoom is unsupported. Layout follows the actual player
viewport, including iPad split windows, not the device's global orientation.
Subtitles and Audio offer their existing tracks directly with real active-track
checkmarks. Audio has no redundant track-section heading. Subtitles lists all
tracks first, then Search & Download, then Advanced. Native menu configurations
preserve this top-to-bottom order even when opening upward. Advanced opens a touch sheet for supported
appearance, timing and dual-track controls. Live TV
does not offer search/download or dual subtitles. Native speed presets and Video
modes apply immediately; Custom, Quality, Version and supported sync controls
open their existing editors. Live multiview is another menu action; Go Live
remains a transport action. A sole audio track stays visible as disabled metadata.
Opening a menu pins transport controls; playback-clock updates do not rebuild
its snapshot. `PlayerMenuPresentation` releases editor requests only after native
menu dismissal completes. Context changes invalidate pending requests and old
audio/subtitle/speed/zoom actions, and programme transitions release live controls.
Each native popup has its own presentation owner, so overlapping dismissal and
teardown callbacks cannot unpin a newer popup or release a sheet too early.
Popup rows are text-only: checkmarks belong to real track/mode/rate choices.
Custom Speed is an unselected, icon-free command outside the preset selection
group rather than a pretend selectable option. Toolbar controls retain their symbols.
An Enhance Dialogue submenu is offered only for an actual engine enhancement
capability, never inferred from `moviePlayback` eligibility. Neither current
iOS engine exposes that control, so no nonfunctional switch is displayed.
The OS may still process eligible content/routes; this is distinct from proving
that a custom in-app menu can read or change its system setting.

Native and tvOS track menus share `TrackLabeling` and `TrackMenuBuilder`.
Bare language titles no longer suppress known codec/channel facts, for example
`English (Opus 5.1)`. Custom names and commentary are retained, existing format
facts are not duplicated, and unknown formats are not invented.
The Aether adapter's native-bypass track list also retains observed media subtype
and channel information from the already-playing asset, rather than manufacturing
language-only tracks. Single tracks are exposed as metadata without offering a
redundant switch. Synthetic native-selection IDs remain separate from provider
IDs and still route through AVPlayer's own selection group or muxed tracks.

Mobile transport buttons, timelines, and tabs use native **clear** Liquid Glass,
without tint or a colored backing. Like AVKit video chrome, their symbols and
progress remain white in both appearances. Mobile Live TV's top presentation
group contains only available Picture in Picture and AirPlay controls, with no
separate Stop button. Pause/resume, player dismissal, and session cleanup retain
their existing behavior. Playback options, track selection, and multiview sit
at the bottom trailing edge above the timeline. Portrait keeps the title on its
own row above those actions; track menus open upward without covering the seek
bar. The controls scrim dims the video
beneath the transport as well as the edge chrome, so white scenes remain legible
without coloring the glass itself. Mobile Info, Cast, and Live TV Info/On Now/Guide
cards use that same native media (`clear`) material, without a colored backing or an added border;
their labels and badges retain light ink over the dimmed video, and their
actions use native secondary bordered buttons rather than nesting glass surfaces.
Their semantic foreground follows the panel's contrast; the system owns the
button's fill and interaction states. Other inline
panels retain regular native glass. Material variants describe the surface's
role, not a replacement for the user's system Liquid Glass preference. Do not
add a custom Clear/Tinted setting or force a color scheme on mobile sheets,
panels, or their host. Badge-only contrast is scoped to the badge content, never
the card's glass or its presentation host.
tvOS playback chrome retains build 57's dark appearance with regular native
glass, scoped by `playerPlatformAppearance` without changing the browsing theme
or window. That scope clears inherited browsing accents so Live TV's guide tint
cannot recolor native playback buttons, including disabled menu-owner buttons.
TV panels retain their thin edge and selected tabs their highlight.
The mobile reduced-glass/older-system fallback follows light and dark mode with paired
foreground colors. Text directly over video stays white. UIKit-backed route and
options buttons resolve the same icon contrast. The native playback-options
menu alone uses a dark appearance on its owning UIKit button, retaining light
menu labels over video in either app theme. UIKit still owns the popup material,
accessibility adaptation, and interaction; there is no painted menu background,
and presenting a speed/quality/subtitle sheet does not carry that override.

Volume and brightness gesture meters reuse the seek track's native clear surface
and `PlayerTouchProgressFill`: 62% white at rest, 90% while adjusting.
All playback tracks, including Live TV and reduced-effects fallbacks, keep light
progress on a subdued track in both themes; never invert to black progress on a
pale solid track. This contrast rule does not tint or override native glass.
Symbols invert only where covered by the fill. Their vertical geometry, inward
direct-touch expansion, overshoot, and fixed 44-by-156-point interaction area
remain independent of the material. The shared gesture feedback view owns
window-safe-area padding once, so both VOD and Live meters clear the Dynamic
Island in either landscape orientation.

On iPhone and iPad, the main transport row is centered on the video. Its 92-point
play button and 64-point skip buttons use 68 points of edge-to-edge spacing in
landscape and 39 in portrait, contracting further in narrow windows. Short
landscape windows use the compact transport so it stays clear of the bottom
controls. VOD and Live use the same full-viewport sizing calculation, not the
Live menu layer's already-inset bounds. Very short windows keep a single
headline instead of stacking metadata into the center controls; Live retains
its position badge beside that headline. Mobile Live headers are text-only:
channel name and position share a baseline above the programme title, or a
single headline when guide data is absent. Artwork remains in the panels.
Position badges show LIVE/BEHIND LIVE (ON NOW/DELAYED for scheduled channels),
not transient connection, seeking, or error messages. Those keep their existing
activity/error presentation; pausing remains visible in the transport. Hide the
badge during transient phases and while paused at the edge, retaining its
localized layout space so the header and timeline do not shift.
VOD and Live chrome use the larger of the
window safe area and native edge margins (21 horizontal, 24 vertical), rather
than adding the two. Adjacent
routing and playback-option controls share one untinted glass capsule while
retaining independent actions. Grouped children have no individual glass
backgrounds or circular clipping, including UIKit menu buttons; Close and the
main transport remain separate. Timeline-only skip feedback preserves the
track-control group's space but hides its native hit and accessibility targets.
Mobile card tabs use native glass buttons with player-sized labels, 8-point gaps,
and a 44-point minimum touch target instead of TV padding. Open cards sit 12
points below their tabs. The mobile Guide fills the card's width in both
orientations; current-channel details belong in Info, not a repeated sidebar.
Phone rows stay compact, with extra width available for programme time.
The Guide uses one media-glass underlay, with no standalone guide gradient on top. Its grid
uses media-contrast text/cell colors on native glass and the selected theme on
the reduced-glass fallback; the standalone guide and tvOS remain unchanged.
The timeline occupies
a 38-point layout row while VOD and Live scrubbing retain a 44-point touch target.
Live uses the same inline timestamp layout, with the picture/seek-target clock
on the left and programme end on the right (`--:--` without guide data).
Clock columns reserve their locale-aware widths, and drag coordinates belong
only to the bar, never its neighboring labels. Programme boundaries, unavailable
history, and the live edge retain their existing timeline semantics.
VOD's elapsed and remaining labels align to the outer chrome edges, including
when reserved clock widths are wider than the visible times.
VOD timestamps always include seconds and choose their fields and column
widths from the video's total duration: `mm:ss` below an hour, `h:mm:ss` from an
hour onward, with extra hour digits reserved only for longer videos. Both elapsed
and remaining columns stay fixed across playback rollovers and scrubbing, with
4-point gaps beside the track. Clock mode retains its locale-aware width samples.

During mobile VOD or Live scrubbing, only the original timeline, its timestamps,
and an available thumbnail remain visible. Top/center controls, title, track
actions, routing controls, cards, and gesture feedback are hidden. The preview
floats above the timeline without changing its layout or touch target; its 16:9
frame grows to 360 points wide, bounded by the available window. Releasing or
cancelling a scrub restores the controls. TV's remote scrub presentation is unchanged.

Double-tap skip, speed, and unavailable-level feedback are Plozz components
using native media glass and SF Symbols, not stock AVKit HUDs. They share the
transport's foreground pairing: light ink on native media glass in either theme,
theme-aware ink on the reduced-glass fallback.

## Manual community timestamps

Connected PublicMetaDB accounts can browse community timestamps from the existing
TV Playback menu and mobile options menu. Browsing is on demand, read-only, and
does not enable playback reporting or automatic skipping. Highlights are fetched
only after a separate spoiler toggle.

The shared browser preserves individual contributions, source-release labels and
attribution. A timestamp must fit the current finite runtime, but that alone does
not verify release compatibility. Each start/end jump therefore needs explicit
confirmation and uses the normal seek coordinator; server markers and chapters
are never replaced. Jumping directly to the runtime's end is unavailable. The
confirmation explains that normal progress reporting can follow a seek.

Reads and selections are fenced by the active key/profile connection and player
load generation. Stop, reload, background recovery, cancellation and changed
runtime prevent stale selections. A failed lookup remains an error rather than
a successful empty list. No automatic PublicMetaDB fallback is enabled without
the missing upstream file/release compatibility evidence.

## Skip-marker timeline

Skip behavior resolves the profile's master enablement and Movies/TV Shows/Anime
selection through the same content classifier used for audio and subtitles.
Disabled categories do not present skip buttons, skip automatically, or request
community markers. Server markers can still load for the independently enabled
Up Next card. Each automatic marker uses its configured immediate or 1–30-second
delay, including the credits-based Up Next countdown when autoplay is enabled.
Countdown deadlines and rings share that duration and remain tied to playback
time, preserving pause, seek-entry, dismissal and focus behavior.

The on-demand and Live touch timelines keep the native glass surface continuous wherever
segment cuts would strand tiny pieces. Each uses its measured track width, not
orientation or device type: a cut needs enough room on both sides for the
20-point touched diameter plus the existing gaps. Both cuts around a short
marker or short unmarked interval are omitted, including near the track ends.
The same threshold applies at rest and while dragging, so touching does not
change which cuts appear. Wider layouts retain cuts wherever they fit.

Marker ranges are never enlarged or retimed; skip behavior, linear seeking, and
existing touch targets remain unchanged. On iPhone and iPad, progress is shown
only by the advancing fill, without a vertical playhead at rest or while dragging.
The track is 8 points tall at rest and 20 while dragging. The dimmer buffered or
aired fill remains behind it. Live preserves programme timing, rewind availability,
and its paused/live-edge indicators. tvOS retains its playhead and segmentation.

## Live rewind scrubbing

The live timeline previews a pending seek without moving playback. On tvOS,
horizontal Siri Remote swipes move the pending position; Select confirms it,
while Back, focus loss, or five seconds without input cancels it. iPhone/iPad
drags seek on release. Channel/source changes and overlay teardown cancel pending
preview work and discard outgoing frames.

Native HLS previews use bounded segment prefixes, not a second persistent player.
Channel headers are restricted to their original origin; foreign-origin redirects
and unsupported encryption/layouts omit the preview without affecting playback.
Byte-range playlists and playlists switching initialization maps currently omit
previews. Segments are capped at 2 MiB, playlists at 512 KiB, initialization files
at 2 MiB, and identity keys at 16 bytes. Truncated frames are never intentionally
shown; unsupported or oversized resources leave the preview unavailable.
The decoded-image cache holds 32 entries; init and key caches each hold at most
eight. Reduced-transparency/performance presentation retains the non-glass frame.

## Playback completion reporting

Playback lifecycle reports capture the request, position, duration, and tracker
percentage before suspension and drain in order. At most one unsent heartbeat
is retained, with newer progress replacing its snapshot; lifecycle events
discard that obsolete heartbeat. Ending a session rejects new heartbeats/state
changes; its single stop report follows in-flight reports and queued lifecycle
events, not a backlog of old progress. Rendition replacement resets start/deferred-state admission without
relabeling queued events. Teardown and reporting are owned tasks, so cancelling
a presentation handoff does not cancel the final network request, and repeated
stop callers await the same teardown. Reports remain best-effort on real server
failures; final-report failures are logged explicitly, not retried as potentially
duplicate watched/scrobble writes.

Native teardown disconnects the presentation layer, removes owned subtitle/video
outputs, cancels pending seeks and asset loads, and replaces the outgoing player's
item with nil before releasing it. A retained presentation or diagnostics reference
must not keep a stopped media pipeline attached. Reloads perform the same cleanup
before resolving the replacement URL on both platforms. Cancelled loads return to
idle only while they still own the load generation, and late audio-track selections
cannot mutate a stopped or replaced item. Stop does not deactivate the app-wide
audio session, which may still be in use by another player.

## On-demand read-ahead

Playback's device-local read-ahead setting controls Plozzigen's existing disk
buffer, not the transport reader's byte window. The on-demand factory injects a
preference reader, sampled once for each new load and shared by its probe retry.
Automatic leaves `forwardBufferSegments` unset (about 40 seconds); 1, 5 and
10 minutes request 15, 75 and 150 segments. Maximum available requests the
pinned engine's ceiling of 2,700 segments (about 3 hours). These are approximate
targets, not guaranteed durations or an extra startup wait.

Aether retains its free-space budget, process-wide retention claims and producer
backpressure. Automatic leaves the byte policy unset. Explicit durations and
Maximum request `Int.max`; the engine clamps this to its safe temporary-volume
allowance (a quarter of available space, or 2 GiB when capacity is unknown).
This removes the ordinary 2 GiB cap as an early limit on a requested duration,
but does not reserve space or promise unlimited buffering. It can also retain
more already-played segments for backward seeks. The protected playback window
may exceed the nominal budget rather than evict media the player still needs.
Storage and network use depend on bitrate and playback path, and may include unwatched material.
The cache remains temporary; this does not implement downloads or next-episode
preloading. Changing the preference does not reload active playback.

Direct preview constructors, scheduled library-channel requests and local
downloaded files keep Automatic. `softwarePacketCacheStorage` stays automatic:
tvOS software playback retains its separate purgeable-memory policy, not the
larger loopback disk allowance. Native AVPlayer/server HLS buffers are not
governed by the segment-cache byte budget.

Playback diagnostics identify an active cache's actual memory/disk storage,
usage/budget, and read-ahead target. Software/FEL packet caches publish bounded
metadata alongside native segment-cache status, without a synchronous cache scan.
The software producer reports a byte-limit status only while actually parked
at its budget, not from the file's Dolby Vision profile or a bitrate estimate.
The memory count excludes purgeable played history; disk counts include retained
segments/packets. Neither is substituted for contiguous playable seconds ahead.
Unsupported routes, cleanup, missing telemetry and replacement sessions clear
the rows. This is temporary cache usage, not download progress or guaranteed duration.
The TV overlay uses consistent label/value rows across all sections and groups
the source and engine beneath its left-aligned title. Numeric values use tabular
digits; the panel still yields to playback controls rather than covering them.

`PlaybackReadAheadBufferingHostedTests` uses the real engine with synthetic
H.264/AAC media and a range-serving loopback source. It compares Automatic with
5 minutes across the same 45-second supply outage at 2x playback, checks actual
displayed-frame changes (the clock alone is not playback proof), recovery,
source-byte growth and cancellation before server teardown. This is a controlled
simulator regression, not a reproduction of a particular rclone installation.
A buffer can absorb temporary shortfalls after it fills; it cannot make a source
whose sustained throughput is below the media bitrate keep up indefinitely.

## Live TV buffer

The separate device-local `LivePlaybackBuffer` defaults to Automatic and offers
10, 20, 30 and 45 seconds. Both app shells sample it for each real stream load.
`liveEdgeCushionSeconds` requests a minimum safe distance behind live; it never
moves playback closer than the source's normal holdback. Automatic preserves
the existing route policy. The option works across native HLS, loopback and
software routes without enabling DVR or changing on-demand read-ahead.

A raw transport stream can take real time to fill the cushion. HLS with retained
segments can fill at source speed. More buffering therefore trades broadcast
delay and potentially slower channel changes for resilience to short outages;
it cannot repair a sustained bandwidth deficit. Plozz allows the sampled
cushion in addition to its 30-second startup watchdog, bounded at 75 seconds.
Settings changes cannot alter an in-progress load's allowance. Scheduled
library playback does not inherit this stream-startup allowance.

For explicit cushions, the live indicator and Return to Live affordance use the
engine's safe-edge verdict so the deliberate delay does not look like a rewind.
Automatic retains the existing time-shift presentation. Returning to Live
respects the selected cushion rather than bypassing it.

## On-demand player clock

The on-demand timeline normally shows elapsed and remaining playback time.
On tvOS, stationary touchpad taps cycle through controls with playback times,
current local time at the scrubber and estimated finish time on the right, then
hidden controls. Clock values replace the two existing numbers in place without
adding a label or row; the current time keeps following the scrubber.
Physical clicks retain their transport actions, and swipes begin seeking without waiting for tap
recognition. Moving, held, cancelled, or clicked contacts cannot toggle the clock.
iPhone and iPad use native buttons on the two time labels instead of changing
the video-tap or scrubber gestures.

Scrubbing always shows the media position. On tvOS, hiding the controls preserves
the outgoing clock labels through their fade and stops clock ticks; the next
reveal resets to elapsed/remaining time. Mobile retains its reset-on-hide behavior.
Finish estimates use the current position and selected playback speed, and update
after seeking or pausing. Unknown duration or invalid timing omits the estimate.
Clock formatting follows the device locale/time-zone conventions. The clock only
ticks while requested, and mobile label slots retain their width during scrubbing.
Live TV retains its existing guide-based program times.

## Mobile player orientation

The iPhone full-screen on-demand and expanded Live TV players read the active profile's
`PlaybackSettings.orientation` (Landscape by default, Auto, or Portrait).
The existing playback-settings store and profile snapshot transfer carry the
preference; it has no effect on iPad, tvOS, or inline trailers.
Landscape permits either sideways direction. Compact iPhone browsing stays
portrait, including the guide when no eligible preview is playing. Expanded phone
windows with at least 600 points in both dimensions follow system rotation,
like iPad; opening a larger display does not itself request fullscreen playback.

Orientation is configured only in Settings > Playback, never in the player's
options menu. Explicitly saved Auto or Portrait choices remain unchanged when
loading existing profiles; older settings without an orientation use Landscape.
The on-demand cover stays portrait while loading versions and showing
the first-use question or pre-play version picker. The saved rotation preference
activates only after that gate completes; cancelling or failing the gate never
forces rotation. Episode/version handoffs retain the preference once playback starts.
The mobile presentation owner supplies the shared player's dismissal action.
Failure-screen Back and end-of-playback dismissal use that same owner as the
mobile X button, rather than a SwiftUI dismiss action outside a SwiftUI cover.

The actual presented UIKit hosting controller owns on-demand orientations.
Live TV keeps one window-scoped owner while its destination is active, without
moving or recreating the playing view. With Auto selected, a visible, authorized
preview in a compact phone window that has presented video permits system rotation: accepted landscape
rotation expands that player, and rotating upright returns automatically expanded
playback to the guide preview. Manual fullscreen does not collapse on rotation.
Closing fullscreen restores portrait browsing and suppresses automatic expansion
until the phone is physically upright again. Forced interface rotation on Close
does not clear that suppression. Hidden previews, multiview, interrupted playback,
external playback, and inactive destinations cannot automatically expand.
Channel changes retain automatic return while fullscreen; callbacks still use
the coordinator's current authorization and source checks.
Native options menus and Custom zoom controls retain the
expanded player's window restriction, including when a presentation temporarily
covers its embedded owner; only removing that owner ends its policy.
Auto follows accepted system interface rotation rather than forcing rotation from
sensor notifications, preserving system rotation lock. Playback ownership never
applies a different window's or inactive profile's preference. Closing on-demand
playback also restores the browsing policy.
iPad follows system rotation and offers no app orientation control, preserving
multitasking. iPadOS refuses forced Portrait/Landscape changes in multitasking
mode, even when a window fills the display.
Rotation waits for native presentation transitions, including dismissal of the
pre-play sheet, rather than racing the selection continuation. Transient geometry
rejections are logged and retried at most three times within a bounded reconciliation
window; they never replace the saved preference with Auto or show a window-management
toast. Dismissal, ownership changes, and newer requests cancel stale reconciliation.
Returning to the foreground rechecks the active player's orientation.

The mobile in-player Guide reuses the guide grid without its standalone top
inset, aligning the ruler with the current-program column. That column uses the
shared raised content surface inside the single outer glass panel, not another
glass layer. The standalone guide and tvOS grid retain their existing spacing.

## Mobile player gestures

On iPhone and iPad, double-tapping either side skips using the active profile's
backward/forward interval. Additional taps while the feedback is visible
accumulate from the requested position, not a lagging playback clock. Directional
chevrons and the signed total share a compact dark glass pill, replacing the main
controls while retaining the player's actual timeline in its normal position,
with its time labels, playhead, buffer and segment styling, and scrubbing behavior.
Each accepted skip launches one native chevron outward: right for forward, left
for backward. It starts partially folded, not flat, and opens to its normal shape
while traveling 20 points over 0.25 seconds. It then stops fully visible for half
a second and fades in place over 0.3 seconds. The pill reserves that travel
inside its layout before adding a 16-point outer inset, mirrored for backward
skips. The number-to-icon layout gap is 4 points, and the icon slot uses its
native width rather than extra blank space. Reduce Motion needs no travel space.
Rapid taps add independent,
overlapping chevrons without restarting earlier ones or queuing a replay.
Each chevron is removed after its own animation finishes; the signed total
retains its existing feedback lifetime. Reduce Motion shows one steady chevron
instead, and enabling it removes any moving chevrons immediately. Single taps
still toggle controls; native controls and open menus keep their own touches.

The mobile on-demand player owns hardware-keyboard playback commands: Space
toggles play/pause and Left/Right skip by the profile's configured intervals.
Keyboard skips reuse the cumulative gesture feedback and real timeline, including
while Up Next is visible. Commands yield to open menus, sheets, expanded cards,
scrubbing, external playback, and inactive scenes. Mobile key events do not also
enter the Apple TV remote recognizers. The native keyboard owner remains attached
through loading and engine handoffs; the visible overlay supplies its current
actions. Left/Right and Space have been confirmed on a physical iPad; simulated
full-player key delivery remains an unresolved interaction-test limitation.

Mobile Up Next uses a tappable episode card with spoiler-aware artwork, the show
name and episode metadata, plus a separate dismiss control. There is no separate
Play button; selecting the card advances to the next episode. Its countdown still
follows playback time. The card shares a bottom stack with the measured transport
content and stays above that reserved band even while controls are hidden, so
revealing the timeline cannot cover the card or move its tap target. While the
card is present, play/pause and both skip buttons sit above it in the same stack,
with the title and timeline below it, instead of overlapping the card at the
center of a narrow or large-text player. The thumbnail fills its content row,
preserving equal outer insets even when the adjacent title wraps. Open player
menus, expanded information cards and scrubbing temporarily hide Up Next.

Holding on-demand video for at least one second temporarily accelerates moving
playback to at most 2x when the engine supports it; shorter presses do not boost
speed. Releasing, pausing, seeking, leaving the player, or backgrounding cancels
the override without changing the saved speed. Only a top-centered glass pill
with the active rate and fast-forward symbol is shown during the hold; the
timeline and its backdrop stay hidden. Both gesture pills reuse the player's
shared native Liquid Glass surface and its reduced-transparency/older-system
fallbacks. Text and native icons inherit the Info/Cast buttons' semibold callout
style together, keeping symbols proportional to their labels as text size changes.
They do not intercept touches. Live TV supports skips only inside an available
rewind window, not speed boosting.

Pinch inward for Normal fitting clear of the display cutout. Landscape video
uses the full display height behind the home indicator instead of reserving a
bottom strip; portrait keeps the full safe-area inset. Controls and ordinary
captions retain their safe-area placement. Pinch outward for edge-to-edge Crop. This
uses the existing session-only zoom state without reloading video or revealing
the timeline. Authored subtitle geometry follows the displayed picture; ordinary
captions retain their screen-relative placement. Inline, tvOS, and external
playback keep their existing geometry. Horizontal seeking on the video surface
is not implemented.

Vertical, one-finger swipes in the outer 30% of the video adjust screen brightness
on the left and **system** volume on the right. The center, horizontal movement,
system-edge gestures and native controls do not change either level. The
profile-scoped Playback setting enables these gestures by default without
changing tap-skipping, pinch or keyboard preferences. They work in full-screen
on-demand and Live TV playback, including while Up Next is visible, but yield to
menus, sheets, VoiceOver, external playback and inactive scenes. Multiview and
inline Live TV do not adjust shared device outputs.

Level feedback is a 32-by-156-point monochrome vertical capsule, inset 8 points
from the respective safe-area edge. It fills upward with
the swipe, without revealing the timeline. Only the fill and 16-point native output icon
are visible; the percentage is available to accessibility, not drawn on screen.
Volume uses the muted speaker at zero, then native one-, two- and three-wave
speaker symbols across the lower, middle and upper thirds of its range.
The icon is white over empty glass and black where covered by the fill, using
the same bottom-aligned mask as the fill. This preserves contrast through zero,
partial-icon crossings and full output without flipping the whole symbol at a
threshold. Native glass and reduced-effects backgrounds share the same layout.
The capsule slides through its nearest edge and scales on entry and exit,
without fading; Reduce Motion presents and removes it without animation.
Keep the feedback host mounted while idle so expiry can animate out.
Once visible, its fixed 44-by-156-point hit region accepts direct taps and drags:
the finger's vertical position sets the level absolutely, with the top at full.
Direct contact widens the capsule inward to 44 points, preserving its edge inset;
release returns it to 32 points. Ordinary screen swipes stay relative to the
whole player height and do not widen the capsule. The existing gesture surface
owns both interactions and excludes skipping, play/pause and speed holds during
direct adjustment. Window-coordinate geometry keeps the hit region aligned
with the safe-area-padded feedback, including Live TV and rotation. Expiry stays
cancelled throughout contact and restarts 1.2 seconds after release.
Dragging beyond full stretches the capsule upward; dragging below zero stretches
it downward. The opposite end stays anchored while the body gently narrows,
with increasing resistance and at most 20 points of extra height. Output remains
clamped, the icon keeps its size, and release springs back without changing the
level. Reduce Motion disables stretching and the spring.
Successful adjustments emit subtle selection ticks on supported hardware after
each further 5% movement from the last tick, in either direction. Small reversals
do not repeatedly buzz. Reaching zero or full output emits a stronger light
impact instead of a tick, not on every clamped update. Moving away and reaching a
limit again re-arms the feedback; starting at a limit does not buzz immediately.
Unavailable-output messages retain their wider inset and do not emit haptics.
The system-volume bridge drives an `MPVolumeView`'s
native slider, the same approach used by
[AetherPlayer](https://github.com/superuser404notfound/AetherPlayer/blob/main/Sources/iOS/Player/PlayerSystemVolume.swift);
it does not attenuate the engine or amplify past the system limit. The bridge
belongs to the actual player view and is removed when the swipe ends, preserving
the system hardware-button HUD elsewhere. An unavailable native output reports
unavailability rather than pretending to change volume. Brightness is restored
when playback leaves the foreground or closes, unless something else has since
changed it. The fullscreen presentation owns that brightness lifetime across
episode, channel and engine handoffs, not each replaceable gesture overlay.
System volume remains at the user's chosen level.

## Mobile playback settings

Before the first multi-version movie or episode, both platforms ask the profile
to **Ask every time** or **Choose automatically**, using the shared Live TV
introduction layout. Asking opens the version picker; choosing automatically
immediately resolves and starts that video without another choice.
Settings > Playback > Version selection can change the mode later; the existing
profile settings payload carries it through switching, transfer, and cloud sync.
Unanswered older profiles retain their per-title memories but still see the
introduction on their first multi-version playback.
The old Remember my choice mode migrates to automatic selection.

Before deciding whether a picker is needed, the gate awaits the provider's
authoritative `playbackItem(id:)` inventory, even for a cached one-version seed.
Both shells await the existing bounded cross-server discovery rather than relying
on the detail page's speculative background pass. Same-account edition sources
are refreshed before presenting their files; partial lists and failed
remote discovery cannot fall through into playback. On iPhone/iPad, a usable
download bypasses server inventory and version prompts, including when another
server or version is selected. Playback prefers that version only among usable
local copies, then tries the other matching downloads in the active profile.
Incomplete or missing copies cannot hide a completed file. Matching uses captured
provider identities or account-scoped source references, never a bare server item
ID; media kind and episode ordinals remain boundaries. Local subtitles and metadata
follow the chosen file. Episode prefetch resolves the incoming episode locally,
and a newly available download supersedes an already-prefetched server stream.
tvOS shows a loading indicator during its server inventory wait.
Cached automatic recommendations are recomputed against the complete inventory;
deliberate selections keep their precedence.
Discovered primary references are stamped with that fresh inventory before a
choice is routed, so selecting one file cannot collapse the remaining choices.
Preparation failures retain their typed message on both platforms and record a
safe stage/error code in the playback journal; raw server descriptions and URLs
are not shown.

**Remember series version choices** is an independent, default-on profile setting,
not a first-use question. It controls reads and writes of episode/series version
preferences across detail pages, player switches, and the pre-play picker.
Disabling it retains stored preferences without applying or replacing them;
movie-specific memories and explicit selections remain intact. Asking always
opens the picker, with the preferred/recommended version selected.

On tvOS, the introduction and version list stay in the player's existing overlay
as centered, content-sized cards, up to 1,100 points wide and 860 points tall.
Longer content scrolls within the available safe-area height; shorter content
must not stretch the card or push Cancel to the screen edge.

`PlaybackVersionChoiceModel` gates player creation and next-episode/playlist
handoffs. Ask every time includes autoplay. Automatic selection uses the shared
detail-page resolver: explicit selection, permitted movie/series preference,
then the existing device-capability recommendation and server-default fallback.
A missing preference never opens a picker in automatic mode, even when only one
version remains. Automatic choices do not overwrite explicit memories or turn
an automatic source into a manually locked source. Cancelling does not start playback
or record an unchosen file. In-player version changes and retry/failover do not
repeat the introduction. Qualified picker IDs still resolve to original
account/item/file identities before playback.

Mobile Playback settings keep network quality limits on the main page and move
codec selection and forced transcoding into Advanced. Only unsupported codec
selections and enabled forced transcoding show brief contextual notices.
The community-marker row retains a short disclosure of the services and title
IDs used for lookups; changing this layout does not change playback preferences.

Quality selection observes `NWPath.usesInterfaceType`, including the physical
interfaces reported beneath a tunnel. When several types are eligible, it uses
their `availableInterfaces` preference order rather than always choosing cellular.
An interface must still pass `usesInterfaceType`: availability alone does not
establish eligibility. `isExpensive` is not an interface type either; Personal
Hotspot can be expensive. Missing preference evidence retains the conservative
cellular fallback when cellular is eligible.
An offline transition retains the current session's selection rather than
restarting playback with the cellular limit. A usable new route immediately
re-evaluates the saved settings and server locality. An initially unresolved
or explicitly cellular path retains the existing conservative cellular policy;
no VPN is disabled or bypassed. Diagnostic path records include interface
booleans and type preference order, not network names, addresses, or credentials.

Jellyfin/Emby compatibility renditions retain the server's stream-copy decisions
when the source fits the selected quality and conversion is not forced. Codec
preferences do not turn compatible copied video into a new encode. Oversized,
unknown-size capped sources, forced conversion, and bitmap burn-in still
prevent video-copy escape. Plex likewise permits compatible native video copy
and validates the decision before starting the same owned server session.
Unsupported audio remains server-converted; only an explicit video-and-audio
copy decision earns the lossless server-remux label. A codec fallback forces
encoding for that retry, so it cannot copy the same failed bitstream again;
the saved quality, codec, and force-conversion preferences remain unchanged.

Native server HLS renditions start and resume through AVPlayer's automatic
stall-minimizing buffering, rather than explicitly bypassing its buffering
decision. Playback speed is preserved without a fixed buffer duration
or client-side delay. Ordinary direct files, trailers, and non-server streams
retain immediate playback. `StreamingBufferingHostedTests` exercises an actual
decoded H.264/AAC stream with a delayed second segment and checks recovery at
the selected speed without replacing the player. Automatic buffering cannot
predict an arbitrary encoder pause or compensate for a server that cannot
sustain playback; this fixture does not validate a real server's capacity.

Plex renditions opt into a session-scoped keepalive every ten seconds after
playback starts, including while paused or buffering. It does not depend on
position changes, scan a library, update watch progress, or scrobble to Trakt.
The playback owner cancels and drains an in-flight ping before stopping or
replacing its rendition. Original files and providers without this capability
do not start a maintenance loop. This preserves an active server session while
the app can execute; it cannot keep a session alive while iOS suspends the app.

The native AVPlayer engine supports the same iOS Picture in Picture contract
as Plozzigen, including server renditions. Its inline layer is retained across
player replacements, and the controller is notified when the player changes
even if the layer does not. PiP continuation and background-audio preferences
remain independent. Native captions switch drawing ownership for external
presentation and revert to the shared overlay afterward; stop clears the
presentation state and detaches the old player.

## Invariants

- **Engine-agnostic.** All transport chrome drives engines through the
  `VideoEngine` protocol — never down-casts. A second engine
  (Plozzigen / AetherEngine) must work with the same chrome and `PlayerViewModel`.
- **Resume is the contract.** Progress reports back to the provider on
  pause/seek/end so `Continue Watching` is always accurate.
- **Subtitles through the rules pipeline.** No view directly twiddles
  AVPlayer text style — it all flows through `SubtitleStyleRules`.
- **No secrets in URLs logged.** Stream URLs frequently embed tokens —
  `PlayerViewModel` redacts before logging.

Plozzigen's Audio **Processing** row samples Aether's active audio pipeline
label, independently of source-video probe availability. `TRUEHD → FLAC
bridge` or `TRUEHD → EAC3 bridge` identifies ordinary channel processing.
Both TV and mobile also show **Encoding**: **Lossless encoding** for an active
FLAC bridge, **Lossy encoding** for EAC3 or APAC, **No re-encoding** for stream-copy,
and **Decoded to PCM** for the software decoder. These display-only descriptions
recognize the active engine's pipeline labels; unknown labels keep their raw
Processing detail without an encoding claim. They describe the local encoding
step, not the original recording's fidelity, resampling/downmixing, or the
receiver's final output. In particular, stream-copy of a lossy source is not
labelled lossless. The same shared rows follow live pipeline changes on both
platforms, without changing audio selection or conversion behavior.
On tvOS 26+, the profile's default-on **Spatial audio** choice requests a 7.1.4
APAC intermediate bed for supported on-demand playback. This is lossy conversion,
not a speaker inventory or bitstream passthrough. Saved Off choices survive.
`PlayerViewModel` captures the active preference for initial and handoff loads;
live streams, shared players, muted previews and other platforms stay off.
The engine owns source eligibility and fallback. On tvOS 26+, software/FEL
playback can use the same spatial-audio choice; other platforms keep channel PCM.
Stream-copy and software-decoding routes retain the engine's own labels.
The software route's compressed E-AC-3/JOC renderer is also **No re-encoding**;
it is not mislabeled as PCM or inferred from the source badge.
The row is unknown until the engine publishes a pipeline and follows track
changes, fallbacks, and teardown. Do not infer it from the Atmos source badge,
channel count or requested bridge mode, or parse the label to make
playback decisions. **System output** reads `AVAudioSession.renderingMode`, and
**Connection** reads fixed output-port types (HDMI, AirPlay, Bluetooth, etc.).
Both refresh while diagnostics is open, on every playback engine. Unreported
values are omitted, never inferred from the source, channel count, settings, or
an older sample. No personal device names or route identifiers are collected.
Descriptive output labels are localized; format and connection brands such as
Dolby Atmos and AirPlay remain verbatim in both layouts.
The system's rendering mode does not detect the physical speaker layout.

The TV diagnostics use three columns capped at 1280 points (two-thirds of a
1920-point TV viewport), above the measured visible playback controls, including
the Info/Cast tabs and cards. Format summaries combine related video/audio facts;
system output includes the connection, while Processing remains separate.
The buffer row labels player and engine measurements independently. Both platforms
use **Source** for the video format summary (for example, `Dolby Vision P7 · 10-bit`);
server transcodes use **Stream** because those facts describe the current rendition.
The summary retains reported color/range facts without inferring compatibility,
FEL processing, or display output from the profile or bit depth. It does not label
Profile 7 as a confirmed dual-layer decoding route. Playback-health metrics, including zero
stalls/drops, memory, thermal state, and seeking, remain visible. Mobile retains
its expanded, scrollable rows. Long filenames are
limited to two lines on TV (the mobile sheet keeps the complete value). If a
tall menu leaves no room for the complete panel, diagnostics temporarily yield
to the controls instead of overlapping them, clipping rows, or shrinking text.

Native asset diagnostics identify `original-url`, `provider-manifest`,
`provider-initialization-repair`, `subtitle-wrapper`, or `trailer-composition`
without recording the URL or tokens.
Bypassing the legacy tvOS wrapper preserves native media delivery; it is not
proof of HDR10+ HDMI output, nor a change to the Plozzigen path.

Negotiated HEVC server transcodes also inspect a bounded, same-origin fMP4
initialization segment for an empty `sdtp` in an empty sample table. Emby's
muxer can emit this box, which makes AVFoundation fail with -11829/-12848
before decoding. Only that empty box and its ancestor sizes are changed;
codec headers, HDR metadata, timing, audio, and encoded samples are preserved.
The repaired initialization and fixed VOD playlist are served by an item-owned
resource loader; media segments keep their exact provider URLs. Adaptive,
live, encrypted, byte-range, foreign-origin, and multi-initialization playlists
remain untouched. Inspection failure retains normal playback and codec fallback.
`HEVCInitializationPlaybackHostedTests` covers the native rejection, repaired
decode, and seeking with a six-second synthetic FFmpeg `testsrc2`/silent AAC
fixture (160x90, 24fps, x265 `hvc1`, one-second keyframes), not captured media.
Its video initialization deliberately adds the empty 12-byte `sdtp` box.

WebVTT sidecars distinguish caption class names from literal CSS colors.
An unstyled `<c.green>` is a compatibility alias for bright `lime` (`#00FF00`),
while CSS `color: green` and SRT `<font color="green">` retain `#008000`.
Header `STYLE` foreground colors support global `::cue`, cue-element/class
selectors (including compound classes and selector lists), common named colors,
hex and RGB/RGBA values, inheritance, specificity, source order and `!important`.
Explicit rules override class defaults; nested spans restore their parent color.
CCExtractor's blank line after `STYLE` is tolerated. External stylesheets,
conditional/complex selectors and other CSS properties are not interpreted.
All resulting colors still obey the viewer's existing source-color preference;
unstyled text retains the viewer's chosen color. Native/engine-decoded attributed
captions keep their decoder-supplied colors rather than reinterpreting them.

Foreground recovery captures a request- and engine-scoped position before
suspension can reset the decoder clock. An internal engine recovery at zero is
not proof that the correct position survived. Restoration uses the normal
latest-wins seek queue and verifies the landing before reconciling play/pause;
an explicit user seek supersedes the saved point. Continuing PiP/background-audio
sessions are not rewound. Paused/recovering heartbeat callbacks cannot report
false playback at zero, and a stop retains the saved position even after load
generation invalidation.

Diagnostics resolve the active internal AVPlayer on each sample, including
Plozzigen player/item replacements. The player buffer, engine cache frontier,
stall count, and dropped-frame count are separate measurements; unavailable
values remain unknown. A ready player with no contiguous loaded range reports
zero buffered seconds. Loopback delivery throughput is not labelled as media
server/network throughput, and encoded stream bitrate is not a network rate.
The instance counter labels native adapters rather than claiming to count every
AVPlayer hidden inside third-party engines. New stall records retain measured
player/engine buffer context in the existing playback journal.

Playback diagnostics row labels use the shared app localization catalog on TV
and mobile. Media filenames, server names, codec identifiers, and the HDR format
label remain verbatim; do not mark app-owned field labels as developer content.
TV rows wrap longer translations and values rather than truncating them.

Diagnostic builds also journal cached Plozzigen pipeline snapshots at most once
every two seconds, independent of whether Playback Info is open. These read the
engine's existing off-main telemetry rather than issuing additional synchronous
AVFoundation reads. The record separates source bytes fetched, muxed bytes,
served bytes, reader-window bytes, and cached media; the native consumer's
loopback throughput must not be called the media server's network rate.
`audio POLICY` records language/default-selection inputs and `audio SELECTED`
plus the pipeline snapshot identify the engine's actual audio track and delivery
path. None of these diagnostics change the audio selection policy.

## Playback options and zoom

The tvOS Playback control replaces the standalone Speed control. Its two rows
stay fixed: Playback Speed adjusts inline (0.25–2x, in 0.05 steps), while Zoom
Mode opens a normal submenu. Normal, Crop, and Stretch apply and return; Custom
adjusts directly on its row (50–200%, in 1% steps), including values below 100%
for zooming out. Back returns to Playback and restores the Zoom Mode row.
The rows and native input scope are shared with subtitle appearance. All screens
retain one native input host and menu width. The host forwards presentation
environment values explicitly, not the outer SwiftUI graph's focus environment,
which can retain duplicate highlights. Mobile adds Zoom Mode to its existing
native playback menu. Live TV offers the same zoom controls without playback-speed
changes.

The picker labels Normal as the default; concise names follow Infuse's Zoom Mode
terminology. Crop enlarges proportionally, Stretch fills both axes without
preserving proportions, and Custom scales relative to Normal. `VideoPresentationView`
transforms and clips only the stable video surface, without restarting playback,
changing the engine layer's gravity, or processing frames.
The subtitle overlay uses the same displayed-video rectangle for source-positioned
and bitmap cues, including both axes under Stretch; ordinary text size, screen
position, and transport geometry stay independent. Plozzigen uses the software
renderer's displayed size or the native item's presentation size before falling
back to coded dimensions.
Authored bitmap clearance maps the image, lower-region envelope, and protected
artwork boundary through that same zoom/stretch geometry before moving a region.

Zoom belongs to the current player session, not a global/profile preference.
A new VOD player or a different live channel starts at Normal. PiP and AirPlay retain
their system-owned presentation rather than inheriting this local viewport crop.
Hosted coverage includes synthetic 4:3 video and a 720x576 H.264 fixture with 64:45
sample aspect (16:9 display), checking real native and software playback without
changing the video layer, playback position, or subtitle text geometry.

## Subtitle appearance

`Match Apple TV Subtitle Style` (`Match Device Subtitle Style` on mobile)
reads this device's subtitle appearance through
MediaAccessibility and applies it to Plozz's text overlay, including Plozzigen
playback. The actual system typeface is retained even when it is not in Plozz's
font picker, including descriptor features such as small capitals. Text-line
backgrounds and the enclosing window keep separate colors/opacities; the window
also retains its corner radius. System appearance changes and foreground return
refresh the overlay. All appearance controls remain visible and show effective
system values. The first real edit freezes that complete appearance into the
profile, applies the edit, and switches matching off; a no-op edit does not.
The toggle and custom appearance remain profile-scoped and sync only with that
same profile. Matching resolves against each device's own system settings; it
does not copy one device's accessibility appearance to another profile/device.
Turning matching back on resumes the current device settings. New/default styles
start with matching enabled, while persisted choices and legacy custom migration
retain their existing behavior.
`Reset to App Default` restores Plozz's own Atkinson/outline appearance and turns
matching off; it is intentionally different from the new-profile default.
Enabling matching over a custom style requires confirmation in both editors;
Cancel leaves the style untouched. Disabling matching and the first custom edit
remain immediate.
On tvOS, numeric and choice rows reserve Left/Right for adjustment, including
at numeric bounds. The native focus scope prevents diagonal escapes to Back
without changing Up/Down navigation. It consumes horizontal clicks and swipes
directly instead of relying on SwiftUI's fallback move command. Each click/swipe
starts with one fine step; held clicks repeat after a short delay and accelerate,
stopping on release, cancellation, focus loss, dismissal, or app deactivation.
The scope also declares horizontal input ownership so window-level sidebar
observers cannot mistake an adjustment's unchanged focus for a page boundary.
Right opens submenu rows, including the nested System Fonts list, once per
click/swipe; Select remains available and holding Right does not repeat navigation.
All subtitle-style screens retain the same native input scope so changing screens
does not tear down the focus binding before the selected font receives focus.
The matching option names the device directly, without a focus-dependent helper
paragraph changing the rows' positions.
Explicit system font, text-color and opacity overrides take precedence over
the corresponding source formatting. Image-based subtitles retain their authored
pixels. This maps Apple's public appearance settings, not its private layout
algorithm or pixel-identical glyph/effect rendering.

Frozen styles retain a securely archived font descriptor (traits, feature
settings, variations and cascade), text opacity independently of overall
opacity, line-background and window colors/opacities, window radius, edge style,
and all ten public source-override policies. Policies for attributes absent from
Plozz's cue model remain preserved rather than being presented as parsed source
data. Apple does not expose native padding, base point-size/layout rules, line
spacing, or edge color/thickness; those controls remain explicitly Plozz values.
The low-level per-field source policies are retained as compatibility data, not
exposed as a long list of switches. The separate **Subtitle file formatting**
page offers only supported controls: authored positions, colors, and bold/italic
emphasis. The primary appearance page contains the viewer's own style controls.

`Font > System Fonts` puts all eight Apple subtitle families first, separated from the
device's installed font families by a divider on TV and native sections on mobile.
Installed families come from UIKit rather than a fixed OS-specific list.
The main list retains Plozz's curated fonts; its System Fonts submenu uses normal menu
typography and a separate divider/section rather than another font preview.
Selecting a system font alone
does not enable system appearance or overwrite other style controls. Its choice
persists per profile and independently for Live TV; a named font unavailable on
another device logs a diagnostic and uses the saved Plozz fallback.

Settings exposes the same appearance controls on tvOS and iOS. Live TV inherits
the profile's library appearance by default. Enabling `Use a separate style for
Live TV` starts from the current look and saves an independent override, including
its own system-style choice. Disabling it removes that override and resumes
inheritance. This applies to IPTV and library-generated channels, including
retained multiview panes. Saved edits update active panes without retuning.

Live playback sends the selected style to both the owned overlay and the engine.
In-app native captions are extracted rather than painted by AVPlayer. PiP and
external presentation retain their native rendition handoff and
`SubtitleStyleRules`; the app overlay must not draw a second copy. System-owned
rendering supports fewer effects than the overlay.

### Caption timing and control avoidance

Plozzigen's primary embedded ASS/SSA tracks preserve their packet text, script
header and embedded font attachments for libass. With source position, colour and
emphasis enabled (and system-style matching off), the adapter composites authored layers, vector drawings, transforms and
karaoke into bitmap cues; it does not flatten animation fragments into dialogue.
The main-thread cue bridge passes raw packet strings through without scanning or
rebuilding their contents. Only newly admitted events are split on the rasterizer
actor; replayed read-ahead snapshots must not reparse thousands of old packets
on the presentation thread. The rasterizer skips unchanged snapshot revisions,
admits only appended packets on cumulative updates, and periodically extends
its future-cue window without losing cues after a seek. Plain-style fallback
still normalizes joined packets before parsing text.
The read-ahead window is two seconds, and libass's native pruning periodically
removes expired packets without rebuilding the live track, reducing work without
lowering text resolution or modifying authored effects.
Rendering is serialized off the main actor with at most one frame in flight,
coalescing busy display ticks to one latest timestamp rather than building a
backlog. Authored animation follows the source video frame rate (24–60 fps)
rather than rendering duplicate 60 Hz display ticks for 24 fps material.
The raster task runs at user-initiated priority because its result is needed
for the current video frame, while the frame pacer still reserves time for
software video and audio work.
When a frame exceeds its budget, subtitle rendering yields more time to audio
and video instead of running continuously. Authored cue starts and ends bypass
that animation backoff so short-lived glyphs appear and expired artwork clears
at the next available display tick; seeking still draws immediately.
Recent render latency leads the sampling clock by at most 200 ms while playback
is advancing, compensating for slow frames without pushing paused subtitles
ahead of the video. Costly, heavily layered ASS animations can still drop
subtitle frames on older hardware; the renderer reserves video/audio headroom
rather than degrading the underlying playback.
Animated ASS reads the software presentation timebase directly; native
playback converts the item's continuous clock through Aether's presentation-axis
map. Seek/wait states retain the engine's held picture time. The published status
clock is too coarse for animation and must not throttle it to roughly five fps.
Rendering uses source time minus the subtitle offset. Paused frames redraw only for changed
cue data; backward seeks rebuild the retained event set. Track changes, Off,
native presentation and teardown fence late output. The existing overlay retains
video-rect mapping, HDR brightness and control avoidance.

Authored ASS frames keep clearly separated upper and lower artwork in separate
bitmap regions. The upper region stays fixed; only a lower region that intersects
visible controls can lift. Its clearance envelope absorbs small animated
glyph/shadow changes so the whole effect keeps moving together instead of being
re-aligned every frame. Movement must fit below the protected upper artwork and
above the controls; otherwise the original placement is retained.
Center/crossing/full-screen compositions remain one fixed authored image. This
uses the existing libass mask bounds in one render pass, never title-specific
rules or pixel scanning. Ordinary PGS/DVD bitmap avoidance is unchanged.

The pinned libass 0.17.5 source target enables ARM NEON acceleration and uses
checksum-pinned font dependencies without adding another FFmpeg or MPV. Glyph
masks blend directly into premultiplied RGBA, avoiding one CoreGraphics mask
allocation and clip per layer. Raster output is capped at 1080p;
render caches and retained events are bounded. Turning off source position or
colour uses the ordinary styled-text fallback, which discards vector drawing
commands rather than displaying coordinates. System-style matching also retains
the normal text renderer so explicit device caption preferences win. Embedded
fonts are session-local libass data; they are never installed into the system.
Secondary ASS and separately
downloaded ASS files retain the existing text path; native PiP uses its plain
subtitle rendition rather than promising authored ASS effects outside the app.

The full-screen startup indicator covers an absent picture only. Actual frame
readiness retires it even if a rewind occurs before the original resume position
is reached; a parked displayed frame also needs no startup cover. Seek and
buffering delays use the scrub-bar indicator, not a center overlay over video.

`NativeSubtitleCueOutput` receives complete caption presentation states from
AVFoundation, including empty states that clear the display. They are scheduled
at the supplied **item presentation time**, never callback arrival time or a
timestamp guessed from the source file. Successive states close the preceding
intervals, including overlapping lines. Changing the selected rendition replaces
the output to fence old callbacks; selecting the already active rendition keeps
its output and cue timeline intact instead of briefly clearing paused captions
and relying on the decoder to send them again. An initially selected rendition
still enables extraction, and Off always clears it.
Seeks flush its state; teardown detaches it. Replacement removes
the previous registration before adding the next: even a transient overlap can
prevent paused track switches from delivering cues on tvOS 26.2. The registration
order is covered independently of the runtime, alongside real paused HLS switching.
Track changes from an active embedded tx3g rendition first clear that selection
and yield its teardown, then replace the output and select the requested rendition.
Replacing an output while its tx3g rendition is selected can leave tvOS 27's
decoder delivering no captions. This workaround uses AVFoundation's actual
subtitle subtype, not provider codec labels. HLS changes replace the output and
switch directly; an intermediate Off can lose paused cues on tvOS 26.2.
Neither path seeks or resumes playback. Renderer ownership handoffs retain their
deselect/register/reselect order to clear the old native line.
Real embedded MP4 and paused HLS switches
cover both tvOS 26.2 and 27, including repeated Off/reselection at a paused time.
Explicit Off still clears the selection and cue timeline.
In-app drawing is suppressed at the native output, with an explicit selected-rendition handoff
for external presentation. The handoff restores the current item's last selected
rendition if AVFoundation temporarily clears it; an explicit Off or track change
discards that fallback. The Plozzigen remote-HLS bypass uses the same bridge
for tracks it identifies as natively rendered; its decoded tracks keep their
existing cue pipeline.

`VideoEngine.subtitlePresentationTime` is separate from scrub/resume time:
Plozzigen-decoded cues use the engine's source-picture clock, whereas native
presentation events retain AVFoundation's item clock. Both VOD and Live TV use
this contract, including scheduled-library wrappers.
Visible live captions have a display-link clock independent of the 250ms
transport/status monitor, so routing native events through the overlay does not
introduce a quarter-second presentation delay.

Presentation callbacks do not supply seekable subtitle history, and advance
delivery is best-effort. They therefore **do not newly advertise manual subtitle
offsets or dual native-track decoding**. Complete sidecar timelines and
Plozzigen-decoded tracks retain those controls. An existing sidecar offset
must not silently delay a native event stream. This preserves native timing
while gaining the shared visual renderer instead of offering controls that fail
after a seek.

Visible control pieces are measured separately from the full-screen scrim,
hidden Info/Cast transport rows, and parked cards. Their rectangles remain separate, so
a left-aligned Info pill does not lift a centered caption above empty space.
Only intersecting captions lift above those bounds: dialogue and dual
lanes move together, while bitmap and authored-position cues are checked at
their own positions. Ordinary track menus retain the normal title clearance
while the title fades, preventing subtitles from dropping into its empty space.
The normal transport reserves its full title-to-tabs band, including gaps between
controls: a short title must not let centered captions stay beneath the timeline.
Info/Cast and full appearance editing release that reserved clearance.
On iPhone and iPad, the visible center transport also reserves the band down to
the bottom controls, so lower captions move above the play/pause and skip row
rather than into its buttons or the space below it. Top controls are measured
separately. A mobile caption moves only when the complete text/dual-lane block
or movable artwork fits above every obstruction; otherwise its original
position is retained, without a partial lift. TV placement is unchanged.
Hiding the controls restores normal placement; style
editing, previews, and saved position values are unchanged. The normal dialogue
percentage remains screen-relative. Captions already encoded into video pixels
cannot be repositioned.

Mobile on-demand subtitle settings include the existing subtitle-delay control
directly, rather than a separate Playback Sync menu entry. Engines that support
audio delay retain that adjustment in the same settings. Availability, ranges,
and the existing engine/overlay timing setters are unchanged. If no other
playback options remain, their empty menu trigger is hidden.

Coverage: `NativeSubtitleCueOutputTests`, `SubtitleOverlayGeometryTests`,
`SubtitleLineRenderingTests`, and the shared tvOS/iOS app-hosted
`NativeSubtitlePresentationTests` / `SubtitleControlAvoidanceHostedTests`.

### Customizing without playback

Settings > Playback > Subtitle style > Customize subtitle style opens the actual
player appearance editor beside a live preview. The Live TV style entry opens the
same page with the independent Live TV binding. TV reuses `SubtitleStylePanel`;
the player and Settings share its `panelWidth` rather than separate layout widths.
Mobile's existing forms live in `MobileSubtitleStyleEditor`, shared by Settings
and the player through `SubtitleStyleEditingContext`. There is no reduced second
set of settings or separate preference store.
Each mobile subtitle destination (file formatting, shadow/outline, background,
and dual subtitles) owns the shared native settings switch style. This keeps
enabled switches green under the Settings and player's monochrome accents
without changing neighboring pickers, sliders, navigation, or menu checkmarks.

The preview renders real `SubtitleCue` data through `SubtitleOverlayView`. On TV,
it lays out a 1920x1080 playback canvas and scales the entire result into the
16:9 preview, including glyph size, outlines, padding, and positioning. Its
background reuses the music player's liquid mesh with restrained two-color
palettes cycling through blue, pale neutral, and dark surfaces, with no theme
scrim. The page, menu, and focus colors still follow the app theme; only the
preview is theme-independent. Animation is confined to that background,
stops off-screen/inactive, and uses a static light/dark comparison for Reduce
Motion. Optional samples demonstrate authored file formatting.

All edits use the normal profile persistence path immediately. System-style
mode retains its usual ownership of font/color/effects. The second-subtitle
toggle controls a sample, not playback track selection, and preserves its style
when the sample is hidden. Selecting real tracks and adjusting synchronization
remain playback operations rather than appearance preferences.

Text size uses the shared `SubtitleStyle.fontScaleRange` and `fontScaleStep`:
20% through 400%, in 1% increments. The TV editor's existing repeat ramp advances
1, 2, 4, then at most 8 percentage points per event, resetting after an idle gap,
direction change, or row change. Mobile uses the same range and step.
Changing HDR Brightness enables HDR preview automatically. The saved brightness
is never changed merely to demonstrate an effect.

On TV, a separate compact Preview section sits below the editor. Focusing it
reveals background, file-formatting, and HDR-preview controls; moving between
those controls keeps it expanded. It collapses only after focus leaves the
section. The picture itself is non-focusable, so Left/Right stay dedicated to
adjusting editor values and Down reaches preview controls. Select on the Preview
header opens an actual full-screen canvas at playback scale; Back returns focus
to that header without losing the chosen appearance or preview options.
The full-screen Settings editor keeps Back above its stationary page title and
the large picture stationary. Only the bounded left tool pane scrolls; the
redundant Appearance heading is omitted. Expanding Preview smoothly reduces the
pane's height, using the shared Settings motion and respecting Reduce Motion.

### Genuine HDR preview

`HDR preview` plays the bundled, original `Resources/SubtitleHDRPreview.mp4`:
silent 1080p60 HEVC Main 10, BT.2020/ST 2084 (PQ), with HDR10 mastering and content
light metadata. Its slow blue ribbon carries a flowing, approximately 1000-nit white highlight,
not SDR pixels carrying an HDR label. Generate or verify it locally with
`python3 tools/generate-subtitle-hdr-preview.py [--verify-only]`; verification
checks the encoded format and decodes pixel values through the PQ EOTF.
The sixteen-second loop sweeps a luminous ribbon through dark and blue regions.
It retains useful HDR glare without filling the scene with circular white blobs.

`SubtitleHDRPreview` owns one muted AVQueuePlayer/loop and one video surface
across inline/full-screen transitions. It does not configure an audio session
or keep the screen awake. Pause retains the displayed frame; backgrounding,
disabling HDR, and leaving the page release playback. On tvOS it requests the
asset's AVFoundation display criteria only for an unowned window and clears only
its own request. Another player's display ownership or load failure is surfaced,
not overwritten or disguised as a working HDR scene.

The UI's **HDR10 test scene** label describes the content, not a measured HDMI
signal. tvOS honors display criteria only when system settings permit it. Actual
HDR output requires an HDR-capable display and Match Dynamic Range or an HDR
system video format; otherwise AVPlayer can tone-map the scene. Neither source
metadata nor EDR headroom is treated as proof of HDMI HDR output.

## Mobile streaming quality

iPhone/iPad movie and episode playback opts into `StreamingQualityProviding`.
The shared `PlaybackSettings.streaming` value is profile-scoped: local network
and remote Wi-Fi/Ethernet default to Maximum; cellular defaults to 720p / 2 Mbps.
The mobile shell waits for the first network-path result before starting managed
playback. Cellular and unclassified paths use the cellular policy; Wi-Fi and
Ethernet retain their local/remote classification even when marked expensive.
Connection changes reapply the relevant saved default. The player Quality sheet
changes only the current video's rendition, not the saved preferences.
Each picker also offers Custom: an independent resolution ceiling and integer
total bitrate in Kbps. Plex/Jellyfin/Emby support 240p–2160p and reserve 128 Kbps
for audio. Silo's native API supports 480p/720p/1080p/4K and H.264 conversion;
its stereo AAC budget is 192 Kbps. A 1080p / 2,000 Kbps selection therefore
leaves 1,872 Kbps for video on the former adapters and 1,808 Kbps on Silo.
Unsupported Silo choices are disabled, and an unsupported saved limit is
reported instead of silently becoming Maximum. See ProviderSilo's README for
native recipe validation and server limits.
Custom edits are drafts until Apply, and Cancel leaves the previous choice intact.
Presets retain their legacy serialized names; custom values persist their own
dimensions/budget per profile and network category. Invalid custom values remain
explicitly invalid and are rejected before provider I/O, never treated as Maximum.
The same value travels through codec retries, seeks, and version changes.

The transport keeps subtitles directly accessible and groups quality, version,
audio, speed, and sync in one playback-options menu. The existing Info card owns
media details, restart/episode actions, and Playback Info (diagnostics); there is
no duplicate Now Playing sheet. Audio controls appear only for alternate tracks
or Dialog Enhance, on both mobile and tvOS. Info keeps its existing technical
badges without a redundant audio/source-audio text row beneath them.
The shared Info card owns both its dark color scheme and dark badge palette:
the native player host can inherit a Light browsing palette even though the
playback surface remains dark. This local pairing keeps badges readable on TV
and mobile without overriding the profile's Light, Dark, Black, or System theme
on browsing surfaces, or changing reduced-effects/accessibility preferences.
Provider-generated format/default labels use the shared friendly codec naming;
the current selection is a checkmark, not the container's Default suffix. Subtitles remain
one separate button, without a duplicate menu entry. A native button snapshots
the menu on opening; playback-clock updates never replace its presented rows.
Its presentation lifecycle suspends control auto-hide until dismissal, including
time spent in the audio submenu. Audio labels share the localized track-label
builder with the SwiftUI controls. Version choices
stay on the active account, reuse detail-page edition/file routing, and carry the
current position, pause intent, speed, quality, and matching tracks to the new
player. The per-profile version preference also applies to later playback.
On Apple TV, Up reaches the transport controls; the stacked-rectangles Version
button appears when the active server offers multiple files or editions.
Its panel focuses and checks the playing version. Selection uses the same
account/file routing and playback continuation as mobile, swapping players
inside the existing cover. An explicit choice never silently fails over to
another source. Resolved file lists refresh the playing source without
discarding other editions in a combined title.
Pre-play, detail, context-menu and in-player version pickers share
`MediaVersion.PickerPresentation` and `CoreUI.MediaVersionChoiceButton`.
Edition/quality/size and release text precede the compact wrapping badge footer,
including video format, audio format and reported audio languages. Bitrate and
runtime remain text when supplied. These describe the source file, not the
engine's negotiated output; missing facts are not guessed. A reported English
track does not establish that the file is English-only.
Every native startup resume waits for readiness and verifies both seek completion
and the actual landing. A rejected seek fails before playback starts at zero,
allowing the existing alternate-engine fallback to keep the requested position
instead of waiting for the first-frame watchdog and adopting the wrong clock.
A paused handoff clears loading only when the engine has a displayable frame at
the resumed position; it does not force playback merely to advance the clock.
tvOS episode handoffs use the same range preparation for automatic advance, Next,
Previous, and episode-picker selections. A matching in-flight/ready prefetch is
reused; other selections from Plozzigen HDR playback resolve and probe before
the outgoing engine stops. Silo is excluded from both speculative prefetch and
pre-teardown HDR preparation: its inactive sessions can end before a signed
URL expires. The incoming player negotiates a fresh session at playback time.
Matching HDR display classes retain Aether's display
criteria; unknown ranges, SDR, or native-engine transitions still reset normally.
Cancelled handoffs release unadopted sessions and clear retained display criteria.
The source-range decision does not establish HDMI output; physical-TV verification
must check both initial Dolby Vision and forward/backward episode transitions.
Mobile retains its existing handoff path without adding a network probe to
offline playback; it does not drive the tvOS HDMI display-mode switch.
For a server conversion, Info's existing badge row describes the active rendition
and is labelled Transcoded alongside the badges: exact encoded dimensions, video codec, known range,
and actual audio format/channels. No original-file badges are substituted while
the stream is unknown. Quality shows the selected limit separately from Current
stream. Diagnostics likewise separates CURRENT VIDEO/AUDIO from ORIGINAL FILE;
declared stream bitrate and network throughput have distinct rows.
The shared diagnostics sampler reads enabled AVPlayer tracks and their format
descriptions even when diagnostics is closed, with system metrics disabled in
that lightweight mode. Only changed stream facts update Info/Quality. Reads are
fenced to the item and sampling generation; retries and version changes clear
the prior snapshot. PQ establishes HDR10, not HDR10+; missing color metadata
does not establish SDR, and AAC stereo never inherits the source's surround or
Atmos flags. These are media facts, not a claim about display/HDMI output.
Loading shows no temporary Quality button; recovery lives with the central error,
not beside Close. Multiple-version failures expose Version and Quality together.

Preparation follows real negotiation, stream opening, and first-video stages.
Its loading UI contains only a spinner, short status (such as "Transcoding…"),
and selected quality for a bounded quality preset. Maximum uses the original
loading indicator rather than the streaming-quality status panel.
The mobile full-screen player holds the shared hero trailer paused for its whole
presentation, including loading, errors, and version changes. Late trailer
resolution, readiness callbacks, and background scrolling cannot restart it.
The hold is released only after the outgoing player's media I/O has stopped;
other playback owners and surface pause intent still take precedence.
Live conversion buffers segments as the viewer watches; there is no invented
whole-title transcode percentage or claim that a timeout means HEVC is disabled.
Server decision codes, HTTP failures, native player errors, and startup timeouts
remain distinct. Only allowlisted error domains and numeric codes enter the UI
and playback journal; raw server messages and authenticated URLs do not.
Transport failures and explicit authorization errors are not treated as codec incompatibility.
Ordinary original-quality playback retains the same structured failure evidence
as quality-limited playback on both platforms. Plozzigen uses the pinned engine's
typed `errorInfo`, never message parsing. Confirmed expired/missing streams, rate
limits, certificate failures, and exhausted device storage do not trigger engine
swaps or server conversion. A native `URL -1008` without an HTTP error, provider
refusal, stronger typed engine failure, or underlying transport/file-system failure
is not confirmation that media is missing. It retains its unavailable diagnostic
while allowing the existing bounded compatibility recovery, including after an
alternate-engine attempt; the once-only engine, transcode, and codec limits remain
unchanged. Retry negotiates again while retaining the selected file,
quality, playback position, and account. Full-screen TV/mobile and Live TV
interruptions use CoreUI's shared `PlaybackFailureView`: a short factual summary,
Details, Retry and Back/Close actions. Quality and version controls remain in the
regular player, not on the error screen; no recovery action promises success.
Failure reports are captured before engine teardown and cleared for a new attempt.
Details retains the provider, actual failure stage, engine, typed engine reason,
bounded underlying error chain, HTTP status and known provider rejection codes.
Readiness timeouts are not network timeouts, and HTTP 410 alone is not proof of
idle-session expiry. Unknown causes stay unknown. Raw descriptions, URLs and
credentials never enter a shareable report. Live TV retains its existing report
format; retry exhaustion does not overwrite the original failure with advice.
Plex bounded streams first validate the server's universal-transcoder decision
with the same session and settings as the start request. HEVC uses fragmented
MP4 HLS. Decision parsing reads only status codes and the output format; it must
not decode unrelated library-item fields, whose wire types can differ here.
Automatic recovery uses the observed/negotiated codec: a failed H.264
conversion can request HEVC on a capable device; HEVC can fall back to H.264.
There is one compatibility retry, not a loop through the same codec.
The Plex H.264 fallback requests MPEG-TS at the unchanged budget.
Confirmed missing or ended resources require a fresh user retry, not a codec change; retry
never falls back to the uncapped original. Decision status and numeric codes are retained without
copying raw server descriptions into the player.

On iPhone/iPad diagnostics use a separate large, scrollable sheet, with stacked
label/value rows and adaptive columns in wide layouts. Failure details scroll
with the metrics. It shares the existing sampler and formatting with the
unchanged tvOS HUD. Original-file video/audio facts remain labelled as source
facts when the delivered stream is transcoded.

Plex, Jellyfin, and Emby adapters negotiate each request independently. Original
files can direct-play only when their known bitrate and dimensions fit all
selected bounds; unknown facts require conversion. Server HLS requests constrain
video plus a 128 Kbps audio budget and maximum dimensions. These are encoder
targets, not a metered-byte guarantee: variable bitrate, buffering, protocol
overhead, and artwork mean hourly estimates are approximate.

Automatic offers both HEVC and H.264 to the server. Prefer HEVC makes an HEVC-only
conversion request first on capable devices; a refused codec/decision or failed
rendition can retry H.264 once at the same quality. An HEVC-only request rejected
as an invalid/unsupported request (HTTP 400/415/422) gets that same bounded retry.
Authentication, permission, rate-limit, network and HTTP 5xx failures do not.
The selected preference is retained during fallback; the player's quality sheet
shows the observed stream codec when available, never the original file's codec
or the requested preference as proof of output. Direct play remains preferred
when the original fits the limit; the codec preference does not force conversion.
HEVC output
depends on server version, encoder support, permissions, and configuration;
Jellyfin/Emby mobile profiles explicitly advertise 10-bit HEVC capability and
8-bit H.264. Their rendition requests carry those limits through to the encoder;
10-bit sources requested as HEVC also select Main 10. A profile name alone is
not proof of 10-bit output, and these requests do not claim HDR is preserved or
that the server performed tone mapping.
Plex hardware transcoding generally requires Plex Pass. Force transcoding is
an advanced option, not a server hardware-encoder selector. Transcoding may
change HDR/audio formats. A failed bounded rendition never retries the original
file or an on-device remux; errors leave the Quality control available.
For bounded Jellyfin/Emby conversion, only bitmap subtitles request server burn-in.
Text tracks remain available through the existing subtitle overlay; a stale
server-generated `SubtitleMethod=Encode` is replaced by explicit `External`
delivery for text/off renditions. Both singular and Emby's plural track selectors
are disabled, and manifest-subtitle requests are removed from that video URL.
Omitting the delivery method alone can still trigger Emby's default burn-in.
An ordinary server fallback can instead return ASS already burned into the video.
The final rendition's explicit `Encode` method and subtitle index are carried in
`PlaybackRequest.burnedInSubtitleTrackID`. That primary remains selected in the
menu but owns no client overlay or native legible track, avoiding duplicate text
and ASS drawing commands. Off or another primary rebuilds the server rendition
at the current position, preserving pause, speed, version, audio, and secondary
selection. Burn-in cannot be moved or restyled by the client; timing controls stay
disabled. Rewriting to an offline original clears this rendition-only fact.
The in-player Style entry is hidden for a burned-in primary unless an editable
second track is selected. tvOS still exposes Dual Subtitles directly so a second
track can be enabled; mobile retains its Second Track section. Global appearance
settings and styling for locally rendered ASS remain available.
An engine load that returns after a terminal startup failure cannot publish ready.
Managed native resume waits for actual item readiness rather than seeking an
unknown HLS item after five seconds. The existing startup watchdog bounds that
wait; cancellation releases the exact old item's pending seek immediately.
Same-item user seeks replace the pending resume target without failing the load,
and stale seek completions cannot finish a newer target. A failed/cancelled load
cannot report playback started while its failure callback is still queued.
Terminal managed-stream failures stop the decoder so audio cannot continue
behind the error screen and immediately release the owned server rendition.
Retry/dismiss joins that same cleanup instead of issuing duplicate stop requests.
Retry copy names the codec requested, not an encoder we cannot prove ran; the
negotiated codec is shown separately and all attempts are journaled.
For managed conversion, native playback inspects an HLS master once and opens
its exact media playlist when there is only one self-contained rendition on the
same origin. This avoids master codec/range declarations rejecting otherwise
decodable samples. It does not rewrite color metadata, change the conversion
parameters, select another version, or restart the server session. Adaptive
masters, external audio/subtitle renditions, session keys, and variable-based
URIs retain their original manifest. Inspection has a five-second deadline,
same-origin-only redirects, cancellation/load fencing, and secret-safe logging.
Original playback, TV callers without mobile streaming options, and Live TV
retain their existing path.
Tone-mapping advice requires the returned stream's actual H.264 codec and PQ/HLG
transfer metadata, combined with a decoder-format failure. Neither the original
file's HDR badge nor a numeric error alone establishes this condition. Emby advice
notes the documented Premiere requirement for HDR tone mapping; it does not
claim to have read the server's license or global settings. Compatible HEVC HDR,
properly tone-mapped H.264, and transport failures retain their own handling.
If the decoder rejects an HDR conversion before publishing its format, the
message offers conditional tone-mapping advice, not a claim that it is disabled.
An SDR alternative is offered only when a known SDR file exists on the current
account, and switching always requires selection. Original quality requires
confirmation that it removes the data limit. Neither happens automatically.
The existing transient-status component shows "Playing in SDR" once playback
starts, for an explicitly chosen SDR alternative or a confirmed HDR-to-SDR
server conversion; unknown output format and failed/loading streams never toast.

Rendition changes stop old media I/O, retain the chosen source/version, current
position and pause intent, reapply track selections, and retire the old server
session. Prefetched episodes must match the current quality policy before
adoption. A downloaded local file bypasses this policy. Plain network shares
do not implement the conversion protocol and have no player quality control.
Existing Apple TV callers and Live TV never opt in.
Real-server playback automation is documented in
[`docs/provider-playback-tests.md`](../../docs/provider-playback-tests.md).
Its synthetic harness checks and real-server results are separate; neither a
missing provider/configuration nor a skipped XCTest is a successful live run.

The player's Playlist tab uses standalone, full-height media cards spaced like
Cast. Episodes uses one continuous row across seasons in an Info-style panel,
without season tabs or a width-limited season rail. Each numbered episode shows
its season/episode code at the bottom leading edge of the rounded still, over the
shared artwork scrim rather than a capsule. Only the current season loads on
entry; adjacent seasons load as browsing reaches the row's edges. Empty seasons
are skipped, and a failed adjacent load exposes a retry at that edge. Adjacent
loads belong to the row and follow visible edges, not the lifecycle of lazy
cards; once started they finish even if that edge scrolls offscreen. Cancelling
a view task drains the request without showing an error. A replacement
panel joins that request and restarts it if cancelled, rather than leaving a
loading skeleton with no work running. Transport cancellation on a still-active
panel exposes Retry like other request failures. Initial and adjacent loads
coalesce independently, and player teardown cancels all of them. Switching the
retained sequence panel from Playlist to Episodes starts its load without
requiring the view to remount. On tvOS, a reusable native
collection owns directional focus and realizes cells throughout held Left/Right
input. Stable episode IDs and layout offset adjustments preserve the focused cell
and its exact viewport position when earlier seasons or retry rows arrive,
including during native focus transitions and in RTL. Native scroll targets use
complete card slots constrained to fully reveal the focused cell, with an initial 24pt
peek of preceding artwork when available. The first episode retains its normal
gutter. Entry targets the current/last-focused episode, not the partial previous
card. Loading uses the same artwork dimensions, spacing, and peek offset, including
right-to-left layout. Episode spacing uses the standard column gap without adding
panel padding between cards (28pt between tvOS slots, 52pt between resting stills).
Native focus can reveal more of the preceding card when making room for its lift.
Mobile SwiftUI
rows defer leading insertions until scrolling settles.
tvOS resets artwork content when the row changes enabled state and when focus
leaves the collection for a tab, without replacing cells or their viewport.
The empty content configuration must complete a layout pass before reinstalling;
otherwise UIKit keeps the old content view and its ancestor-focus projection.
Horizontal episode moves retain their artwork views. Disabled cells immediately clear their
native focus projection, caption offset and marquee, even before UIKit finishes
moving focus out of the closing drawer. Episode activation does not leave a
persistent collection selection. Episode browsing auto-hides after 15 seconds
without navigation; each focus move restarts that window. Other cards retain
their existing timeout.
The playback focus surface and controls hosts are siblings under a nonfocusable
root. TVUIKit also projects artwork when an ancestor is focused, so returning
focus to a parent containing the drawer would highlight every parked episode,
regardless of the cells' own focus state. Up from every bottom tab, including
Episodes and Playlist, uses the same seek-surface exit as Info and Cast. Back
exits every bottom card through the same drawer-close and playback-focus handoff.
Initial loading
uses nonfocusable artwork/caption skeletons with the loaded cards' dimensions,
not a spinner or visible loading message. TVUIKit projects only the artwork;
captions stay outside that projection and neighboring tiles keep their layout. Episode titles occupy one line,
giving the reclaimed height to larger 16:9 stills, with matching top and bottom
insets. Long tvOS titles use the same native marquee as Home posters: only the
focused title scrolls, it resets on blur/reuse, and Reduce Motion disables it.
Focused episode captions move down by half the Home caption travel (8 points at
standard metrics) without changing the row layout.
Overflowing native captions fade at both edges, with inset resting endpoints
that keep the beginning and end readable. These episode insets are explicit;
ordinary poster captions retain their edge-aligned resting position and
directional overflow fade.
Touch layouts truncate long titles. The shared scrim and episode
text are rendered into that image at display scale so TVUIKit retains them on
focus; this work is cached across focus changes. Panel glass is a separate
background, not a compositor around the native row, so it cannot hide the
focused artwork. The panel clips scrolling content and focus projection at its
rounded boundary.
Portrait layouts use vertical episode rows. Playlist entries retain server
order and load only as they become visible.

The episode browser resolves the playing episode through its owning provider
before loading parents: a retargeted opening card can still carry another
server's series and season IDs. The resolved identity must match the playing
episode; missing or failed server metadata remains a retryable error.
Both player layouts use `EpisodeArtworkSource`, matching the detail row's
server/online preference, episode-specific fallback and prepared-image identity.
Requests are isolated by episode, account, spoiler mode and artwork policy,
even when several episodes share the same library fallback image.
The active player's profile-scoped spoiler settings mask unwatched titles
before captions or accessibility see them. Placeholder mode never loads the
hidden episode still; blur mode blurs only the artwork, not its numbered badge.

## Siri Remote input

`ScrubGestureInterpreter` routes upward and downward swipes through the same
actions as the corresponding directional presses: Up reaches the track controls
(or a pending Skip/Up Next affordance), and Down opens Info. Scrubbing locks after
18 points of horizontal-dominant travel; vertical navigation waits for 54 points
of vertical-dominant travel. A right swipe's first delivered sample can still lean
downward, and locking there opened Info and let the rest of the swipe move focus to Cast.

First-generation touchpad edge clicks arrive as UIKit **Select** presses, not
Left/Right. `RemoteTouchInput` reads the old remote's absolute GameController
position while leaving UIKit in charge of input and menu focus. The tvOS app
declares both remote profiles and separate micro gamepads in `project.yml`;
newer directional remotes keep their native press behavior.

`RemoteClickInterpreter` resolves left/right edges to the configured skip
intervals and keeps center clicks as Select. UIKit press timestamps use uptime,
while GameController snapshots use Unix time, so event matching converts clocks
before rejecting stale samples. Do not require `buttonA.isPressed`: rapid clicks
can already be released when UIKit delivers their press.

A clicked touch cannot also pan into a menu or scrub when the finger lifts.
Suppression lasts for that contact only; the next touch can swipe immediately.
These rules are covered by `RemoteClickInterpreterTests` and
`ScrubGestureInterpreterTests`.

Scrub movement is consumed at pan begin, change, and normal lift. UIKit can
coalesce a short swipe into begin/end without a changed event, especially at a
content-matched 24 Hz. The axis threshold excludes only its fixed dead-zone
distance, never the entire first delivered translation. A follow-up pan suspends
the pending flick commit immediately; a tiny follow-up that never locks an axis
reschedules that commit on lift rather than leaving playback in preview mode.
`PlayerScrubInputTests` exercises these UIKit callback phases, including movement
while an earlier engine seek remains pending. Display cadence and backend seek
latency are measured separately; changing the HDMI refresh mode is not this fix.

Per-sample time-label reads live in `PlayerTimelineTimes`, not in the full
controls body, so moving the timeline does not rebuild unrelated menus and
controls. Preserve the existing reveal/fade, playhead, and thumbnail animations
when optimizing this path; removing visual polish is not a performance fix.

`PlayerScrubTrackSurface` uses a light 22%-white translucent fill when Liquid
Glass is reduced, shared by TV, touch, and live timelines. This is a flat,
non-adaptive tint with no blur or refraction. Other performance-mode panels keep
their existing dark surfaces; timeline-specific lightening does not change the
global fallback material. Buffered and played fills still layer above the track.
Liquid Glass has a 10%-white capsule behind the glass itself to keep a nearly
transparent unbuffered track visible. This backing is part of the track surface
inside the skip-marker mask, not a background behind its gaps. The flat
performance fill remains 22% white.

The TV and touch seek bars share `PlayerSkipMarkerTrack`: solid, rounded
sections separated at the start and end of each available skippable range.
There are no internal cutouts, patterns, or user-selectable marker styles.
The base 4pt gaps are centered on the original time boundaries. Each half-gap is
capped at a quarter of either neighboring section's width so a tiny range is
not consumed or enlarged. Outer timeline ends remain unchanged.
Both sides of each gap use the narrower rendered section to size their corners,
with a small amount of extra rounding capped at half the bar height. Slivers use
slightly taller elliptical corners without exceeding their available width;
wider neighbors can use the corresponding circular corner. Base facing corners meet
the gap at the same height. Roomy joins retain full rounding, and rounding never
removes a divider. Live programme tracks use the same geometry.
On TV, constrained corners grow vertically from the 12pt resting geometry as
focus expands the bar to 20pt. Their horizontal width stays constrained while
the curves retain their resting proportions instead of becoming squarer.
The wider side of a tight join gains up to 1.5pt of additional rounding during
focus, without changing the smaller piece or exceeding a fully rounded end.
Tight TV joins also gain up to 1pt of optical spacing at rest, increasing to
2pt at full focus, taken only from the wider neighbor. The smaller piece stays
in place, and the original time boundary remains inside the gap. Spacing tapers
away at fully rounded joins and is bounded so a section contributing to both
neighboring gaps retains at least half its width. Neither seek positions nor
marker times change.
Full-radius roomy joins are unchanged.
Touch timelines retain their existing minimum-width suppression, so expanding
the bar does not introduce tiny sections or change its established rounded caps.
The mask applies to the base, buffered, and played fills and glass backing
together, never the white playhead. Each section retains the bar's exact
material and opacity; only its rounded ends and full-height gaps reveal the
picture. Overlapping/touching ranges merge before masking, so duplicated
metadata does not create extra boundaries inside one contiguous skip range.
Ranges are clamped to a finite positive duration; malformed timing is logged and
ignored. No marker changes focus, gestures, skip modes, or the existing buttons.
The display uses already-loaded server/community metadata, without additional
fetches or a separate clock observer; dismissed skip buttons do not erase the
timeline annotation. Live programme progress is not a VOD skip-marker timeline.

Debug tvOS builds can open `PlayerSkipMarkerPreview` with the explicit
`PLOZZ_SKIP_MARKER_PREVIEW=1` process environment. It shows only two real
`ScrubBar` rows: Liquid Glass and the translucent flat performance fill, both
using the production segmented markers. No alternative pattern/style selector
is retained. Remote controls change example playhead/buffer positions,
normal/focused bar heights, and picture brightness. Section boundaries are
static, independent of playback position. The mask adds no blur, refraction,
timer, or separately colored overlay.
Menu/Done returns to the normal app. The preview uses isolated local models,
and never saves profile preferences. A scenario control cycles through a
60-minute episode with a 30-second intro, a 24-minute episode with a 90-second
intro, a three-hour movie with two-minute credits, a 90-minute recording with
four ad breaks, and a 45-minute episode with an eight-second recap. Marker
widths always use the exact duration ratio, without a minimum-width enlargement.
Example playhead/buffer positions do not seek the separate background video.

The Info card's artwork is a focus-independent child view. Moving between
actions or revealing/parking the card must not reconstruct its image loader
or synchronously reload artwork policy. URL/geometry changes still update it,
and metadata-provider policy notifications invalidate the child explicitly.
The horizontal Cast row realizes only nearby faces on its first visit instead
of constructing all twenty glass cards. Its fixed-height lazy row remains
mounted underneath person details, preserving the scroll offset and native
return-focus target after a deep drill; no artwork prewarming is required.
The subtitle track menu resolves only its selected track when it opens.
System-caption font resolution belongs to the font editor, not track-list focus.
Panel glass is rendered on a separate background layer, not around the changing
content subtree. On supported systems, the normal player keeps Liquid Glass
instead of using source format, bitrate, or hardware memory to select a cheaper
surface. The previous cutoffs were deliberate performance tradeoffs; the new
path reduces first-visit and focus work while keeping the material. Both shells
still honor the existing profile/OS transparency resolution, and older OS
versions retain their non-glass fallback.

tvOS transport badges use CoreUI's `PlayerControlButton`. Live TV multiview
actions retain visible title-and-icon labels with the same `playerGlassButton`
modifier, including native menus without replacing their behavior. Transport
icons keep accessible titles. Do not set a blanket foreground on their containing screen:
native glass owns label contrast, focus and material. Only the existing
reduced-transparency path uses the shared frosted fallback.

The real app enters the synthetic comparison through its normal profile route;
Settings exposes **Player marker examples** only in Debug builds after Developer
Mode is unlocked, never in ordinary Settings or a Kids Profile. Notification
requests recheck the developer gate; turning Developer Mode off closes the
preview. Release builds have no entry point. Explicit Debug-only launch flags
remain available to the test harness. Library footage additionally requires the complete profile/Plex
authorization gates. `MarkerPreviewLibrarySource` selects an episode from an enabled library
on an active source; mapped Plex Home users require their resolved server
identity. It rechecks profile, credentials, and library visibility across each
request, releasing stale preparations. The existing Plozzigen engine plays
the library video muted with display matching suppressed, without normal
player progress, watched-state, or scrobble reporting. Closing, changing the
profile, hiding the video, or leaving the foreground stops it and drains its
owned transport/session. Startup is bounded and failures expose Retry.
No clip is generated, downloaded to the repository, or uploaded elsewhere.
Standalone test fixtures use the static picture and make no media requests.

Velocity smoothing uses elapsed touch-event time rather than a fixed weight per
callback, preserving the same response at 24 Hz and 60 Hz without changing
Match Content settings.

For live input diagnostics, launch with `SCRUB_DIAG=1` and capture stdout.
`PLZSCRUB remote-` lines include touch boundaries, press types, sampled positions,
resolved click actions, pan decisions, and focus transitions. The probe is
disabled by default and logs no media URLs or credentials.

## Transport layout — read before moving anything in `PlayerControls`

The controls look like a simple stack, but four rules hold it together. Each was
paid for with a real regression; breaking one produces a symptom that looks like it
comes from somewhere else entirely.

**1. Measure the box your view is actually laid out in.** A `GeometryReader` in the
controls layer's `.background` reports a DIFFERENT box (960 tall, ending at y=1020)
from the one the `ZStack`'s children receive (ending at y=1080). Positioning a child
using the background's numbers puts it exactly one safe-area inset (60pt) out of
place. `ControlsBottomKey` is therefore measured by a **sibling probe inside the
ZStack**, so both edges of the arithmetic come from one geometry. If you re-anchor
the menus, keep measuring from a view in the same layout box — and verify the
rendered frame rather than reasoning about it, because these boxes do not differ in
any way you can see.

**2. The bottom cluster is a fixed stage moved by ONE transform.** The Info card is a
permanent stack member; "closed" is the whole cluster translated down so the card
clears the screen (`infoCardLift`). Nothing is inserted and nothing reflows, which is
what makes the reveal read as one object instead of parts arriving separately. The
consequence: **any change to the cluster's height or margins moves the card**, and
because it parks flush against the screen edge, a stray few points shows up as the
card peeking into view. If the card peeks, something changed the cluster's layout —
don't look at the card.

**3. `bottomMargin`, `infoCardGap` and `infoCardCatchUp` are one equation.** Parking
the cluster puts the card's top at `bottomMargin − infoCardGap` above the screen edge,
so a gap tighter than the margin would leave the card showing; `infoCardCatchUp` makes
up the difference by letting the card travel that much further. Change one, recheck
all three. Padding *below* or *inside* the card cancels out and is free.

**4. One animation modifier at cluster level.** `.animation(value:)` retimes ANY
change in flight, however unrelated the value it watches. A `titleVisible` fade sitting
at cluster level grabbed the reveal a frame in and handed a 0.42s spring to a 0.28s
curve — visible as a lurch. Every other fade is scoped to the view it belongs to.

Focus has its own rule, from the same family as the tvOS note in
`AGENTS.local.md`: **gate what is focusable; never chase focus after it lands.** The
engine does not defer to a `@FocusState` value already in place, so the Info tab is
kept out of the focus order unless its card is open, and an entry narrows the order to
the single control the pressed direction targets.

## Live channel transport

`LiveChannelTransport.swift` is the expanded live player's chrome, assembled from
the VOD transport's parts rather than drawn separately: the title block and
`playerGlassButton` badges (Audio · Subtitles · Multiview, plus Go Live when
time-shifted), `PlayerScrubTrackSurface` for the timeline, `PlayerTabButtonStyle`
tabs, the shared `PlayerOptionsPanel` for track/style menus, and
`PlayerOverVideoCardStyle` cards. The card parks by one cluster offset exactly as
rules 2–3 above describe, with the same constants on tvOS. Track menus live in
their own layer, placed from the badges' measured GLOBAL top, never as an overlay
on the badges (an overlay is sized from the badges' box and ended up over the
timeline).

Live has no arbitrary seek, so the timeline measures the airing programme (faint
fill = aired, bright fill = on screen, trailing it while paused or behind live).
It is the focus hub: Select plays/pauses, Up reaches the badges, Down lands on the
last-used card tab and opens its card. With the card closed only that one tab is
focusable (VOD's `entryFocusTarget`, made structural); open, Left/Right walks
Info · On Now · Guide and focus alone switches the card. Do not put
`onMoveCommand` on the timeline: it swallowed the Down press.

On Now retains the player's original card geometry: the player panel radius and
content inset, with artwork corners derived from their difference (minimum 8pt).
Browsing-card density and mobile artwork-radius changes do not reshape these
cards. Programme art, fallback logo plates and progress masks use the same inner
corner. Boxed source logos keep their own corners inside Live TV playback,
including its embedded guide; standalone guide and library styling is unchanged.

Channels change only on the remote's Channel Up / Down buttons (`.pageUp` /
`.pageDown`, see `LiveChannelRemotePresses`), never on Left/Right.

Guide opens `LiveChannelGuideOverlay`, the player's own lineup over the playing
picture. It is modelled on the Multiview picker but is not the browse guide:
nothing retunes while browsing, it opens on the playing channel, and Menu returns
focus to the timeline. The Info card's Playback Info toggle shows the VOD
player's diagnostics overlay (`PlaybackDiagnosticsOverlay`), sampled from the
live engine while it is up.

Go Live ignores ordinary HLS segment latency: it appears after a deliberate
pause leaves playback behind, or after at least 30 seconds of unrequested drift.
A refresh near the live edge must not erase pause intent while still paused.
Both channel-load paths reset that intent. TV Playback Info stays top-left;
mobile uses the shared diagnostic sheet.

Live style edits use the same profile-scoped `SubtitleStyleStore.liveTV`
override as Settings, with changes propagated to already-created settings models
and retained panes. The interim `com.plozz.liveSubtitleStyle` value is migrated
once, without replacing a newer canonical override. There is no separate native
subtitle preference: system matching belongs to the shared style. Dual-track
selection is a host capability, not another tracked property on the controls
model; live menus do not offer it. A subtitle download divider appears only when
the download row itself is available.

## Where to look first

- `VideoEngine.swift` — the protocol every engine implements.
- `PlayerViewModel.swift` — the orchestration & resume contract.
- `EngineFactory.swift` — how the alternate on-device engine (Plozzigen)
  is plugged in without this module depending on it.
- `SubtitleStyleRules.swift` — `SubtitleStyle` → AVPlayer text rules.
