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
  `IdleSleepGuard`: AVKit display-criteria match + keep-awake while
  playing.

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
playback. Cellular, expensive, and unclassified paths use the cellular policy;
connection changes reapply the relevant saved default. The player Quality sheet
changes only the current video's rendition, not the saved preferences.
Its sliders button lives beside speed, audio, and subtitles in the visible
transport. Loading shows no temporary Quality button; a failed stream offers
Change quality and Try again with the central error, not beside Close.

Preparation follows real negotiation, stream opening, and first-video stages.
Live conversion buffers segments as the viewer watches; there is no invented
whole-title transcode percentage or claim that a timeout means HEVC is disabled.
Server decision codes, HTTP failures, native player errors, and startup timeouts
remain distinct. Only allowlisted error domains and numeric codes enter the UI
and playback journal; raw server messages and authenticated URLs do not.
Permission, connection, and server errors do not trigger codec retries.

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

Automatic and Prefer HEVC allow H.264 fallback at the same quality. HEVC output
depends on server version, encoder support, permissions, and configuration;
Plex hardware transcoding generally requires Plex Pass. Force transcoding is
an advanced option, not a server hardware-encoder selector. Transcoding may
change HDR/audio formats. A failed bounded rendition never retries the original
file or an on-device remux; errors leave the Quality control available.

Rendition changes stop old media I/O, retain the chosen source/version, current
position and pause intent, reapply track selections, and retire the old server
session. Prefetched episodes must match the current quality policy before
adoption. A downloaded local file bypasses this policy. Plain network shares
do not implement the conversion protocol and have no player quality control.
Existing Apple TV callers and Live TV never opt in.

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

## Where to look first

- `VideoEngine.swift` — the protocol every engine implements.
- `PlayerViewModel.swift` — the orchestration & resume contract.
- `EngineFactory.swift` — how the alternate on-device engine (Plozzigen)
  is plugged in without this module depending on it.
- `SubtitleStyleRules.swift` — `SubtitleStyle` → AVPlayer text rules.
