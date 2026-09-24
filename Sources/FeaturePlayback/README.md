# FeaturePlayback

`AVPlayer` view-model/view, engine-agnostic playback surface, resume
reporting back to the server, caption style rules, trickplay scrubbing,
and the diagnostics overlay.

## Responsibility

- **Engine abstraction** — `VideoEngine` protocol + the two seam files:
  - `NativeVideoEngine` — the always-shipped AVPlayer-backed engine.
  - `EngineFactory` — closure-based factory that the composition root
    (`AppShell`) wires up. The on-device decode engine (Plozzigen /
    AetherEngine) is injected here as a closure, so `FeaturePlayback`
    never imports `EnginePlozzigen` directly. This keeps the dependency on
    the FFmpeg xcframeworks out of the rest of the app.
- **View model / view** —
  - `PlayerViewModel` orchestrates engine lifecycle, audio/subtitle
    selection, scrub state, resume, and progress reporting.
  - `PlayerView` + `CustomPlayerContainer` host the engine's vended
    bare video surface and overlay the shared transport chrome.
- **Subtitle rendering** — `SubtitleStyleRules` translates
  `CoreModels.SubtitleStyle` (font, size, colour, opacity, background,
  edge / outline) into `AVPlayer` text style rules for the native draw path;
  the custom `SubtitleOverlayView` renders the full styled look (including
  dual subtitles) on the overlay path.
- **Subtitles** — `SubtitleHLSComposer`, `SubtitleInjectingResourceLoader`,
  `WebVTTNormalizer`: inject external sidecar subtitles into the
  AVPlayer pipeline as a synthesized HLS variant and normalize timing /
  encoding to WebVTT, AVPlayer's only timed-text format.
- **Trickplay scrubbing** — `ScrubGeometry`, `ScrubThumbnailProviding`,
  `TrickplayThumbnailLoader`, `PlexBIFThumbnailLoader`: focus-driven
  scrub bar with per-provider thumbnail loaders (Jellyfin "trickplay"
  PNG/JPG tiles + Plex BIF).
- **Diagnostics** — `PlaybackDiagnosticsSampler` +
  `PlaybackDiagnosticsOverlay`: opt-in HUD with engine, codec, bitrate,
  dropped frames, etc.
- **Display matching** — `DolbyVisionDisplayCriteria` /
  `IdleSleepGuard`: AVKit display-criteria match + platform-specific keep-awake.
  Mobile playback owns a foreground presentation lease through startup and
  buffering; pause, failure, EOF, backgrounding, and dismissal release it.
  tvOS continues to follow actual engine playback.

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
Every native startup resume waits for readiness and verifies both seek completion
and the actual landing. A rejected seek fails before playback starts at zero,
allowing the existing alternate-engine fallback to keep the requested position
instead of waiting for the first-frame watchdog and adopting the wrong clock.
A paused handoff clears loading only when the engine has a displayable frame at
the resumed position; it does not force playback merely to advance the clock.
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
Plex bounded streams first validate the server's universal-transcoder decision
with the same session and settings as the start request. HEVC uses fragmented
MP4 HLS. Decision parsing reads only status codes and the output format; it must
not decode unrelated library-item fields, whose wire types can differ here.
Automatic recovery uses the observed/negotiated codec: a failed H.264
conversion can request HEVC on a capable device; HEVC can fall back to H.264.
There is one compatibility retry, not a loop through the same codec.
The Plex H.264 fallback requests MPEG-TS at the unchanged budget.
A missing converted resource may trigger this fallback too; it never falls back
to the uncapped original. Decision status and numeric codes are retained without
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
For Jellyfin/Emby conversion, only bitmap subtitles request server burn-in.
Text tracks remain available through the existing subtitle overlay; a stale
server-generated `SubtitleMethod=Encode` is replaced by explicit `External`
delivery for text/off renditions. Both singular and Emby's plural track selectors
are disabled, and manifest-subtitle requests are removed from that video URL.
Omitting the delivery method alone can still trigger Emby's default burn-in.
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

## Siri Remote input

`ScrubGestureInterpreter` routes upward and downward swipes through the same
actions as the corresponding directional presses: Up reaches the track controls
(or a pending Skip/Up Next affordance), and Down opens Info.

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
tabs, `PanelGlassBackground` + `PlayerMenuRowButtonStyle` for the track menus, and
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
Info · On Now · Stats · Guide and focus alone switches the card. Do not put
`onMoveCommand` on the timeline: it swallowed the Down press.

Channels change only on the remote's Channel Up / Down buttons (`.pageUp` /
`.pageDown`, see `LiveChannelRemotePresses`), never on Left/Right.

Guide opens `LiveChannelGuideOverlay`, the player's own lineup over the playing
picture. It is modelled on the Multiview picker but is not the browse guide:
nothing retunes while browsing, it opens on the playing channel, and Menu returns
focus to the timeline. Stats reads the engine's facts plus the origin's master
playlist (`HLSPlaylistSummary`), fetched once when the tab opens and never logged.

## Where to look first

- `VideoEngine.swift` — the protocol every engine implements.
- `PlayerViewModel.swift` — the orchestration & resume contract.
- `EngineFactory.swift` — how the alternate on-device engine (Plozzigen)
  is plugged in without this module depending on it.
- `SubtitleStyleRules.swift` — `SubtitleStyle` → AVPlayer text rules.
