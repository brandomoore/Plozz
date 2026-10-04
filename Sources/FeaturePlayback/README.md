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
- **Subtitle rendering** — `SubtitleOverlayView` draws in-app captions from
  sidecars, Plozzigen decoders, and `NativeSubtitleCueOutput` for native legible
  tracks. `SubtitleStyleRules` remains the reduced AVPlayer styling adapter
  for system-owned external presentation.
- **Native video assets** — tvOS feeds the resolved original URL directly to
  AVPlayer even when sidecars are available. Track menus still use provider
  tracks; the owned overlay authorizes and fetches selected SRT/WebVTT sidecars.
  Embedded captions retain native cue extraction. iOS keeps the existing
  `SubtitleHLSComposer` / `SubtitleInjectingResourceLoader` path; real provider
  HLS, trailer audio composition, and Plozzigen are unchanged.
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

Native asset diagnostics identify `original-url`, `provider-manifest`,
`subtitle-wrapper`, or `trailer-composition` without recording the URL or tokens.
Bypassing the legacy tvOS wrapper preserves native media delivery; it is not
proof of HDR10+ HDMI output, nor a change to the Plozzigen path.

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
intervals, including overlapping lines. Selection replaces the output to fence
old callbacks; seeks flush its state; teardown detaches it. In-app drawing is
suppressed at the native output, with an explicit selected-rendition handoff
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
Hiding the controls restores normal placement; style
editing, previews, and saved position values are unchanged. The normal dialogue
percentage remains screen-relative. Captions already encoded into video pixels
cannot be repositioned.

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
tvOS episode handoffs use the same range preparation for automatic advance, Next,
Previous, and episode-picker selections. A matching in-flight/ready prefetch is
reused; other selections from Plozzigen HDR playback resolve and probe before
the outgoing engine stops. Matching HDR display classes retain Aether's display
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
The 4pt gaps are centered on the original time boundaries. Each half-gap is
capped at a quarter of either neighboring section's width so a tiny range is
not consumed or enlarged. Outer timeline ends remain unchanged.
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
