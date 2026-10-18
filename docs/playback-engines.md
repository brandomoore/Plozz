# Playback Engine Architecture

Plozz uses two playback engines, automatically selected per-item based on
container, codecs, and subtitle requirements. The goal is maximum format coverage
with the best possible quality (Dolby Vision, Atmos, full-timeline seek).

## Media-share disc images

Media-share folder browsing and indexed libraries recognize `.iso` files
case-insensitively. Classifier version 16 forces one complete directory rewalk
for existing catalogs, including unchanged leaf folders, without resetting
external metadata enrichment. ISO items retain the same path-based identity
and credential-scoped network-file locator as other share videos.

Plozzigen detects decrypted DVD-Video and Blu-ray images through the existing
random-access `TransportIOReader`, with no forced ordinary-container hint.
The engine selects the main title by default. WebDAV still requires validated
byte ranges and stable representation identity; external HTTPS delivery never
receives the share's credentials.

WebDAV advertises efficient 32 MiB reads to the shared transport reader.
Scattered reads start with a 64 KiB window (or the caller's larger request);
contiguous window exhaustion grows read-ahead fourfold, capped at 32 MiB and
the file's remaining bytes. Cached seeks stay local; random misses and cloned
readers start small again. This avoids fetching megabytes for tiny disc probes
and amortizes HTTP latency during sequential playback.
Transports using the default preference retain 4 MiB windows assembled from
requests no larger than 1 MiB. Range and representation checks are unchanged.
Demand-only adaptive buffers are released before replacement.

Adaptive readers also retain up to eight previously validated windows no larger
than 64 KiB each (512 KiB total) for alternating disc-directory probes. Cache hits
refresh recency; misses evict the least recently used window when full. Large
sequential windows are never added to that cache. It is local to the reader and
its pinned source lease, starts empty in clones, and is released on close.

Once half of a large adaptive window (at least 16 MiB) has been consumed, the
reader may fetch **one** next window, capped at 32 MiB and EOF. It overlaps
network work with consumption rather than splitting a window into concurrent
HTTP requests. Each WebDAV window uses one validated range; its full
representation, range and body-length checks still precede delivery to the
demuxer. The demand read adopts the pending window instead of requesting it
again. Sparse probes and default-size transports do not speculate.

The current and pending windows retain at most 64 MiB of logical payload per
adaptive reader, plus the 512 KiB probe cache. This is not a process/peak-memory
cap: clones, HTTP, decoder and HLS buffers have their own memory costs. Stopping
consumption can leave up to one unused 32 MiB window; no further work is started
until the consumer advances. Seeks within the current or pending window preserve
that same read: cached back-and-forth probes must not cancel and refetch it.
Seeks outside both windows, explicit cancellation and close cancel it, and lease
shutdown drains it. A failed pending window
returns an error, not EOF or an implicit retry; cancel or a seek outside that
cached/pending region resets it.

HTTP 429 responses establish a cooldown in the affected ephemeral HTTP session.
`Retry-After` accepts delta-seconds or an HTTP date; absent/malformed hints use
five seconds. New calls during that interval fail with the same terminal 429
classification without making a request, queuing sleepers or retrying
automatically. Existing in-flight requests are not retried. The cooldown does
not cross account/session boundaries or block DAV metadata just because a
separate anonymous delivery origin was throttled.

The full media-probe budget and default sealed HLS segment delivery remain
unchanged; shortening analysis without track-completeness checks can lose sparse
audio/subtitle tracks.

Related upstream designs separate request sizing from buffered consumption:
[FFmpeg HTTP](https://github.com/FFmpeg/FFmpeg/blob/b7e835e06913e4374a4567003fe8c75cebfffb98/libavformat/http.c)
supports separate initial/steady request sizes and short-seek read-ahead;
[VLC prefetch](https://github.com/videolan/vlc/blob/11bcb6f56d59b43cf589556f426c7a5cbd460fdd/modules/stream_filter/prefetch.c)
uses a bounded producer/consumer buffer; and
[mpv demux](https://github.com/mpv-player/mpv/blob/dde0671072723c311df874a32dc4e48b5197ca62/demux/demux.c)
keeps bounded forward/backward packet caches. These are architectural references,
not measurements of those players on Plozz's test service or copied implementations.

This does not add CSS/AACS decryption, disc menus, BD-J, multi-angle playback,
or a disc-title picker. An ISO extension alone does not guarantee a supported
video disc; unsupported or encrypted images follow the normal playback error
path. No full image download is required.

`WebDAVDiscPlaybackHostedTests` exercises the production folder browser,
playback request, WebDAV adapter, source resolver, and displayed video frames,
including forward/backward seeks. Its ordinary test serves an original ten-second
MPEG-2 test pattern in a DVD ISO over loopback WebDAV. The fixture contains no
third-party media and was generated with the commands below. A separate MP4
fixture exercises ordinary-container playback through the same path.

```sh
mkdir -p /tmp/plozz-disc-fixture/VIDEO_TS
ffmpeg -f lavfi -i 'testsrc2=size=320x240:rate=25' -t 10 -an \
  -c:v mpeg2video -g 12 -q:v 8 -f vob /tmp/plozz-disc-fixture/VIDEO_TS/VTS_01_1.VOB
hdiutil makehybrid -iso -udf -default-volume-name PLOZZ_DISC_FIXTURE \
  -o dvd-test-pattern.iso /tmp/plozz-disc-fixture
```

The separate live test is opt-in: set the test process's
`PLOZZ_WEBDAV_PLAYBACK_INPUT` to a private JSON file (or `cache:<filename>` in
the test host's cache directory) containing `baseURL`, `username`, `password`,
`relativePath`, and one to three `seekPositions` in seconds. Use a credential-free
HTTPS base URL, a decrypted ISO the tester is authorized to access, and a file
owned by the tester with mode `0600`, outside Git. Remove staged simulator
credentials after the run. Missing configuration skips only that live test;
it is not evidence of remote playback. Each load/seek has a 120-second deadline
and frame/progress waits are bounded separately.
After the final seek, the live test observes another 60 seconds and requires
more than 58 seconds of playhead advancement. This is a bounded continued-playback
check, not proof of complete-film playback or physical-device frame smoothness.

## IPTV live streams

The [IPTV troubleshooting history](iptv-history.md) links earlier routing,
redirect and cancellation repairs, including approaches that later changed.

IPTV playlist URLs can declare live output as `ts` or `m3u8` while publishing
extensionless channel URLs. The provider carries that declaration into its
encrypted loopback URL without changing the upstream address or opening an
extra probe connection. This keeps declared MPEG-TS on the ingest/remux path
instead of the HLS-only native bypass. Explicit stream extensions take
precedence; the hint never applies to movies, episodes, or HLS child resources.

When neither an extension nor a declaration identifies an HTTP live stream,
`PlozzigenLiveSourceProbe` examines a bounded response prefix before choosing the
route. HLS manifest bytes retain native playback, including fMP4; three framed
MPEG-TS sync bytes select ingest even with a generic MIME type. Undetermined
non-playlist bytes use Aether's container probe, not its HLS bypass. This adds one
sequential, cancelled-after-inspection GET for opaque addresses, with a 1,024-byte
consumption cap and 15-second deadline. It never buffers an entire live stream.
The authenticated proxy serializes this request with subsequent root playback;
redirected account headers remain origin-scoped. Stops and replacement loads
cancel the inspection, and HTTP refusals remain typed rather than triggering
decoder retries. Declared HLS/raw streams and on-demand playback are unchanged.

Authenticated IPTV relay refusals are retained by exact loopback URL for the
current live attempt. This preserves HTTP 451 access restrictions, authentication
rejections, and rate limits when native playback reports only a generic load
failure. Teardown removes the registry entry; the current engine can retain its
evidence until that attempt ends. Recoverable request failures are not latched
as terminal engine errors. The relay does not automatically retry a provider
refusal or substitute an unadvertised stream format.

Raw live transport streams (`ts`, `m2ts`, `mts`) use Aether's supported `fastZap`
join profile. Unlike HLS, these sources have no existing playlist window to
fetch: the standard full-holdback gate can wait longer than AVPlayer's initial
playlist timeout on a long-GOP channel. Fast start permits a shallower initial
window after two finalized segments and a bounded grace period. It can trade
some initial buffering protection for earlier playback; it does not remove the
source's keyframe wait or guarantee instant tuning. Native HLS keeps its standard
join policy; detected raw transport streams use the same fast-start policy as
explicit `.ts` addresses. Other unclassified containers keep the standard ingest
join policy; on-demand is unchanged.

On the native HLS route the rewind window is the playlist's own: Plozz reads the
item's `seekableTimeRanges` (Aether reports `0...edge` there) and, once it spans
at least a minute, the live timeline seeks through it — remote left/right in
10-second steps, a drag on touch. Presses stack on the last requested target and
commit together; a target at the edge becomes Go Live. The timeline reaches back
past the current programme's start to cover the window (at most four hours),
split at the guide's earlier programme boundaries, with the seekable part filled.
The ingest and software routes still load with `dvrWindowSeconds: nil`, so they
keep pause and Go Live only. Playback Info's LIVE section shows the route, delay
behind the newest segment, window length, playlist clock, start-up cost (AVPlayer's
own `startupTime` beside tune-to-first-frame) and segment delivery from the
access and error logs.

Rewind and Go Live share one seek worker per playback attempt, including across
temporary scene inactivity. Replacing or stopping an attempt retires its worker
so an old completion cannot consume the next channel's seek. Guide lookback is
queried separately from a future browsing window to preserve both under cache limits.
Native access/error logs are reduced off the main actor and published only for
the current item. Live codec facts follow the active tracks; an unmeasured Dolby
Vision profile stays unknown rather than being inferred from the sample-entry tag.

## Dependency version

Authored primary ASS/SSA subtitles use libass **0.17.5**, built from the
unmodified upstream sources in `Vendor/Libass/libass`. `UPSTREAM.json` records
the official archive and SHA-256; Apple configuration and assembly wrappers live
outside that directory. SwiftPM compiles ARM NEON kernels on arm64 and the scalar
fallback on Intel, with optimization enabled even in Debug. The former prebuilt
wrapper disabled assembly and spent 36–67 ms per frame on a font-heavy opening
on Apple TV 4K (2nd generation). The optimized renderer and direct premultiplied
RGBA compositor measured 15–28 ms at the same 1920×1080 resolution; no effects or
font sizing are removed to reach the frame budget.

FreeType 2.14.3, HarfBuzz 14.2.0, FriBidi 1.0.16 and libunibreak 6.1 use
checksum-pinned standalone artifacts from `mpvkit/libass-build` 0.17.5.
Their exact public headers are retained in `Vendor/Libass/dependency-headers`
for the C build. These add standalone text-rendering libraries, not MPV or another FFmpeg.
The adapter consumes Aether's public raw-packet/header/font APIs and emits
composited bitmap cues through Plozz's existing subtitle overlay. Font data is
session-local, frame work is serialized off-main, and late frames are fenced
across track changes, seeks and teardown. `App/Resources/LibassNotices.txt`
ships the upstream and transitive-library notices. Preserve all upstream license
headers when updating the vendored sources, and update sources, public headers,
binary checksums, and bundled notices together.

Plozz pins the playback-corrected
[AetherEngine fork](https://github.com/brandomoore/AetherEngine/tree/2975f3ee9c455ac6ed267a072fe191685f9a8c60)
at commit `2975f3ee9c455ac6ed267a072fe191685f9a8c60`, integrating upstream
release **7.40.0** (`c1885331de8339eabe08659af35972411a42c94c`).
ASS/SSA packets with neither a decoded end nor a packet duration are now discarded
instead of lingering for a fabricated five seconds. This also applies to sidecars;
other subtitle codecs retain their established fallback. Upstream 7.40.0 does not
include this correction; the fork retains it and its regression tests.

The fork also corrects accumulating AAC-LC audio drift in indexed MP4 VOD
([#89](https://github.com/brandomoore/Plozz/issues/89)). When the existing audio
sample index demonstrates a different clock from the decoded samples, the native
HLS path selectively enables timestamp-aware resampling through its audio bridge.
Ordinary AAC and nonaccumulating timing jitter still stream-copy. Stereo uses
FLAC without an extra lossy encoding generation; surround retains the configured
bridge mode. Compensation resets on restart and drains at EOF. The correction
applies independently of provider or transport on tvOS and iOS/iPadOS; it does
not modify SMB reads, video timestamps or Match Frame Rate. Synthetic regressions
cover both drift directions, late-onset drift, 44.1/48 kHz, restart/resume and
decoded HLS timing. The original reporter's media has not been supplied.

The fork exports **AetherEngine as a dynamic framework**. LibDovi and LibTrueHD
each bring a Rust exception personality; statically combining both with Plozz's
Objective-C and C++ text-rendering code exceeds Mach-O compact unwind's three
personality slots. The framework keeps the engine's decoder runtimes in a
separate Mach-O image, preserving unwind metadata and panic handling. Both app
targets must embed and sign it alongside the existing FFmpeg frameworks.

The 7.23.0-to-7.34.1 range adds live-start/holdback and source-open recovery
fixes, corrected software resume/seek timelines, transport-intent preservation
during rebuilds, and blocking engine work moved off Swift's cooperative pool.
Changing speed while paused now leaves the session paused until `play()`.
E-AC-3 JOC stream copies advertise object audio in the HLS master, including
untagged tracks. FFmpegBuild **3.7.x** fixes dependent-substream Atmos signaling;
LibDovi remains **2.1.x**. Upstream 7.36.0 adds DTS:X object rendering, corrected spatial
speaker positions and a tvOS Atmos output activator for receivers that need it.
It also includes live-replay recovery, software-video recovery after a screen lock,
and the intervening 7.35.x playback fixes; these are upstream changes, not new
Plozz-specific implementations.

The current integration explicitly enables `TrueHDObjectAudio`, `DTSXObjectAudio`
and `DolbyVisionStillReshaping`: upstream now defaults all optional components
off. This preserves the existing object-audio path and Dolby Vision scrub stills.
The new `DualLayerDolbyVision` trait remains off; Profile 7 continues through
the native single-layer route. The root manifest requires Swift tools 6.1 for
package-trait selection. LibTrueHD and LibDTSX advance to **3.0.0**;
the latter now ships a separate, dynamically embedded `DTSX.framework` under
LGPL-3.0-or-later. Intervening releases also correct small-block FLAC bridging,
live joins and recovery, and video timing; the fork retains its AAC and ASS fixes.
Release 7.40.0 also streams persistent HTTP/1.1 segment bodies with bounded
backpressure and updates the spatial rendering paths described below.
The fork fixes a Swift 6.4 compile failure in persistent body reads by retaining
the caller's isolation through both the cancellation-handler read and its socket
progress callback. The repair is proposed in
[superuser404notfound/AetherEngine#837](https://github.com/superuser404notfound/AetherEngine/pull/837);
it does not mark the mutable chunked decoder unchecked Sendable or disable
concurrency checking.

On **tvOS 26 and later**, ordinary on-demand playback automatically requests
TrueHD Atmos and DTS:X object rendering with `LoadOptions.objectAudioRendering = .apac(.l714)`.
The 7.1.4 layout is an **intermediate spatial bed**, not a detected physical speaker
configuration. tvOS and the receiver handle final output; there is no speaker
setup prompt or mandatory opt-in. **Settings > Playback > TrueHD Atmos and DTS:X**
provides an on-by-default switch on supported Apple TVs. It is saved per profile,
including profile settings transfer, and applies when the next playback session
starts. The original `trueHDAtmosEnabled` storage key is retained, so existing
profile choices and transfers apply to both formats without resetting the preference.
Keep it on for overhead sound from eligible TrueHD Atmos and DTS:X tracks on
compatible equipment. Turning it off retains the ordinary channel bridge
described below: the compatible channel presentation still plays, but does not carry
the original height positioning. Avoiding the extra spatial conversion may
help when those tracks stutter or seek slowly; it is not a guaranteed remedy for
unrelated playback problems. This is not a global Atmos switch: Dolby Digital Plus
(E-AC-3/JOC) Atmos remains unaffected.
Older saved profiles default to on. HDMI channel counts and the current rendering
mode are not used as Atmos capability gates: neither reliably describes the room's speakers.

Aether converts **48 kHz TrueHD Atmos and supported lossless DTS:X** on its
native/HLS VOD path. For DTS-HD Master Audio, LibDTSX checks the actual packets:
some DTS:X tracks are labelled only DTS-HD MA by FFmpeg, so metadata alone does
not decide eligibility. Confirmed standard DTS:X has its height contributions
removed from the compatible floor-channel downmix using the standard's constant
fold. The standard presentation's bed and heights map one-to-one into 7.1.4;
alternate presentations carrying objects fall back to the channel bridge.
Ordinary DTS-HD MA retains the channel bridge. TrueHD Atmos uses the source's
channel presentation, split between floor and heights by object-energy positions,
rather than mixing object signals into the output. The measurement-only
`TrueHDReferenceRender` trait stays off.
The engine encodes that spatial bed as Apple Positional Audio (APAC), which
tvOS can deliver as Dolby MAT to compatible equipment. This is **lossy conversion**,
not TrueHD/DTS:X bitstream passthrough or preservation of the original dynamic object
stream. It adds decoding/encoding work during eligible playback, not library
scanning or idle sync. Shared live players and muted previews stay off to avoid
additional spatial encoding in those background/concurrent paths.

Live stream loading, iOS/iPadOS and older tvOS keep object rendering off. Plain
TrueHD, ordinary DTS/DTS-HD MA, unsupported DTS:X presentations, ineligible sources and APAC initialization
failures retain the existing bridge: FLAC for source layouts above six channels,
otherwise the E-AC-3 compatibility bridge. Software-video playback does not use
this conversion. E-AC-3/JOC Atmos remains stream-copied. Explicit track selections
and language preferences are still passed to Aether; its automatic selection can
prefer TrueHD Atmos or DTS:X within the same language/dub when rendering is enabled.

Progressive segment delivery remains disabled. The upstream Apple TV reports in
[AetherEngine #731](https://github.com/superuser404notfound/AetherEngine/issues/731)
support this output path, but are not verification of every receiver/speaker
configuration. An Atmos receiver label alone does not prove discrete height
mapping, particularly with tvOS Continuous Audio.

Both apps bundle the unmodified
MIT license, Apache-2.0 license and NOTICE from
[LibTrueHD 3.0.0](https://github.com/superuser404notfound/LibTrueHD/tree/3.0.0)
as `LibTrueHDLicense.txt`, `LibTrueHDApacheLicense.txt` and `LibTrueHDNotices.txt`,
with a shared in-app credit. They also bundle the unmodified Apache-2.0 license,
NOTICE, LGPL-2.1, LGPL-3.0 and GPL-3.0 texts from
[LibDTSX 3.0.0](https://github.com/superuser404notfound/LibDTSX/tree/3.0.0)
as `LibDTSXLicense.txt`, `LibDTSXNotices.txt`, `LibDTSXLGPL21License.txt`,
`LibDTSXLGPL3License.txt` and `LibDTSXGPL3License.txt`, with its own in-app credit.

The retained 7.23.0 audio-output
flush epoch prevents a buffer decoded before a software seek from entering
the newly flushed queue, where its old timestamp could leave playback silent.
Its subtitle packet store appends in place rather than copying all retained
packets on every addition, reducing contention during dense ASS openings.

The preceding 7.22.2 release waits for an observed,
still-running display switch before offering an unproven HDR master. A rejection
during a switch still falls back for that item but no longer latches a
process-wide HDR-master refusal
([superuser404notfound/AetherEngine#667](https://github.com/superuser404notfound/AetherEngine/issues/667),
[superuser404notfound/AetherEngine#669](https://github.com/superuser404notfound/AetherEngine/pull/669)).
Plozz leaves this timing policy inside the engine; it does not add another
display-criteria writer or an EDR-headroom assertion.

The 7.16.1-to-7.22.2 update also includes bounded input/relay handling, stale
load/seek cancellation fixes, off-main bitmap subtitle decoding, corrected
software-video/still colour tags, and recovery improvements for sequential
sources and live audio. FFmpegBuild moves to 3.6.x for MPEG-TS audio-payload
identification; LibDovi stays at 2.1.x. Platform minimums are unchanged.
Played-media bitrate and network throughput remain separate in the engine's
telemetry. New stream-description and software-escalation APIs do not opt Plozz
into new playback features or change its configured routing/track preferences.
Remote-HLS audio tracks newly published as informational data stay out of Plozz's
selection menus: upstream explicitly cannot switch those tracks through
`selectAudioTrack`. The engine's records remain available to diagnostics.

It retains the two stage-2
recovery fixes behind issue #61: the media fallback comes back where the
refused item was placed rather than where the session first started
([superuser404notfound/AetherEngine#621](https://github.com/superuser404notfound/AetherEngine/pull/621)),
and a recovery reload leaves a paused viewer paused rather than starting the
title behind the tvOS screensaver
([superuser404notfound/AetherEngine#623](https://github.com/superuser404notfound/AetherEngine/pull/623)).
7.16.0 keeps IPTV path credentials out of the engine log. Since 7.10.0 it notices a media
services reset after tvOS sleep instead of reloading onto the invalidated
player, stops waiting on a media server that no longer answers
([superuser404notfound/AetherEngine#597](https://github.com/superuser404notfound/AetherEngine/issues/597)),
keeps the playhead through a rebuild raised just after another, and no longer
latches an HDR refusal made while the display is ineligible. Audio and subtitle
language preferences now match parsed tags (`en-US` answers `en`), which can
change the default track picked for some titles. It contains the structural HDR10+
validator and shared probe limits/cancellation from
[superuser404notfound/AetherEngine#583](https://github.com/superuser404notfound/AetherEngine/pull/583),
plus the follow-up fixes in
[superuser404notfound/AetherEngine#586](https://github.com/superuser404notfound/AetherEngine/pull/586).
Validated positive evidence survives later packet damage or soft pass-budget
expiry; whole-probe cancellation/deadlines still throw. Controlled probing
retains normal stream analysis within its input limit, and bounded HTTP probes
wait for an origin slot until their deadline. Plozz's existing public-API
integration and stricter HTTP transport remain unchanged.

Its iOS/tvOS 18 minimum matches Plozz's existing deployment targets. The engine
owns the FFmpegBuild 3.7.x, LibDovi 2.1.x and LibTrueHD 2.2.x dependencies;
Plozz does not link a second FFmpeg build. This release also retains both earlier
integration fixes:

- [superuser404notfound/AetherEngine#566](https://github.com/superuser404notfound/AetherEngine/pull/566):
  item-bound background access/error-log reads, stale-result fencing, and bounded
  diagnostic admission. The release also includes the upstream dedicated-thread
  follow-up for saturated dispatch pools.
- [superuser404notfound/AetherEngine#568](https://github.com/superuser404notfound/AetherEngine/pull/568):
  Vision subtitle OCR runs off the cooperative executor, with one actual native
  operation admitted process-wide and cancellation-safe cursor replay.

The update also includes Matroska keyframe-boundary, bridged-audio priming,
HDR-route preservation, and screensaver/Now Playing fixes. New prewarm and
live-recording APIs remain opt-in; this update does not enable new app features.
The engine's diagnostic fix does not change Plozz's separate native-AVPlayer
diagnostics sampler.

This dependency update retains Plozz's playback routing and optional-feature
settings. It does not connect container chapters to Up Next; marker-less content
continues using the configured lead-time fallback.

The 7.1.1 to 7.7.1 update preserves HDR routing during audio changes and
background recovery, retains the native Now Playing host across screensaver
recovery, and avoids dispatch-pool starvation in loopback connections and source
size probes. FFmpegBuild 3.4.x adds AV1 Dolby Vision sample-entry support.

## Remote AV1 Matroska startup

For HTTP(S) original-file AV1 in MKV/Matroska/WebM with provider-known video
dimensions, Plozz bounds Aether's initial stream-information analysis to 2 MiB
and two seconds of media analysis. The upstream default is 50 MiB / 60 seconds;
font-rich files can spend that budget chasing unresolvable attachment metadata
and hit Plozz's 30-second startup watchdog before presenting video.

This is an analysis budget, not a total download cap or wall-clock deadline.
Container headers, read-ahead, seeking, and subtitle readers can transfer more.
Before accepting the bounded result, the adapter checks the declared video codec
and dimensions, audio parameters and selected track, all declared embedded
audio/subtitle indexes, and ASS headers. An incomplete result is logged and gets
one ordinary full-probe retry, fenced against cancellation and replacement.
External sidecars are not expected in the demuxed inventory. Local files, live
streams, server renditions, other codecs, and sources without sufficient metadata
retain their existing probe behavior.

`PLOZZ_ASS_HTTP_REPRO` enables the hosted full-file HTTP regression using a local
two-audio/two-ASS-track fixture; media is never checked in. It separately measures
startup over a 512 KiB/s connection and sustained AV1/ASS playback over a
2.5 MiB/s connection through the full opening. Five-second animation windows and
a main-thread display-link probe expose long pauses that an overall fps average
can hide. Static authored frames do not emit replacement images, so presentation
gaps alone are not proof of dropped animation. The distinction matters: the reproduction averages about
2.7 Mbps but its opening peaks near 16 Mbps. Reducing probe work cannot make a
4 Mbps connection sustain those peaks.

## HDR10+ source preservation

An HDR10-capable playback path accepts HDR10+ source files without requesting a
server video transcode. HDR10+ has an HDR10-compatible base layer: supported
Apple TV/display combinations can use its dynamic metadata, while an HDR10-only
output retains the base picture. Accepting the source does not force an HDR10+
HDMI mode or claim that the connected display supports it.

Jellyfin/Emby HEVC capability profiles include `HDR10Plus` alongside `HDR10`.
Plex's range gate also recognizes the `smpte2094-40` metadata signal and retains
the SDR-only fallback. Source badges keep HDR10+ distinct from HDR10; Emby's
`ExtendedVideoType: Hdr10Plus` is normalized without inventing it when absent.

Native AVPlayer items leave per-frame HDR display metadata enabled even when
server metadata is missing or says SDR. AVFoundation applies only metadata the
stream actually carries. On tvOS the native engine loads the played asset's
`preferredDisplayCriteria` asynchronously, as prescribed for custom player
interfaces by [Apple](https://developer.apple.com/documentation/avfoundation/avdisplaycriteria).
Synthetic source-hint criteria are only a bootstrap for HDR HLS startup, not
the final substitute for the asset's format. Stopped/replaced loads cannot
apply late criteria, and native teardown does not clear a differing request
that another player has since installed on the same window.

Aether remains the display-criteria writer for Plozzigen. Plozz does not supply
an already-HDR panel assertion from EDR headroom: that reading is unreliable
as proof of the current tvOS output mode. The pinned engine already attempts
an HDR master for an eligible but unproven display during on-demand playback,
with a media-playlist fallback if AVPlayer rejects it. Live playback retains
Aether's separate policy. No Dolby Vision or HDR10+ display support is invented.

The diagnostic HDR label describes the **source**, not measured HDMI output.
On original-source playback, a current engine source probe overrides incomplete
provider range hints, including Emby reporting HDR10 for an HDR10+ file. Server
transcodes retain the original-source metadata rather than treating the
re-encoded asset as evidence about the original file.

These are candidate corrections for issue #58, not a hardware-verified fix.

### Neutral Circadian compositing

Circadian Mode's observer stays attached, but its window-wide multiply layer
exists only while it actually changes colour or brightness. Off, scheduled
daytime, and zero-strength settings leave no neutral sRGB compositing filter
above either video engine. Active warmth/dimming and its transitions remain
available; a superseded fade cannot remove a newly enabled tint.

This is a separate candidate for #58 from the engine's display-switch timing
change. The previous overlay was opaque white even when disabled. Hosted
coverage verifies its removal and active-mode behavior, not HDMI metadata.
Keep native MP4 and Plozzigen MKV comparisons on the same HDR10+ test file and
display; require the metadata-dependent picture change and the TV's HDMI
HDR10+ indication before claiming the reported output problem is resolved.

### Supplemental Emby HDR10+ detection

Emby's `ExtendedVideoType` can identify HDR10+, but a missing declaration is
not proof that the file lacks dynamic metadata. The delayed detail-page probe
can confirm HDR10+ on an original HEVC source independently of its audio codec,
including titles whose Atmos badge is already known. It is not a library-wide
scan and playback never waits for it.

Plozz delegates structural HDR10+ validation and Atmos detection to Aether's
combined probe instead of maintaining a second parser and FFmpeg demux loop.
The requested details are independent: a known Atmos badge does not suppress
missing HDR10+ detection. Only positive evidence upgrades the source badge;
an exhausted budget, inaccessible stream or unconfirmed result never disproves
a server declaration. Dolby Vision keeps its primary classification.

The app retains bounded HTTP transport, including 8 MiB of reserved ranges,
two-second request deadlines, validated partial responses and same-origin
redirects. Upstream whole-probe limits cover opening, analysis, seeks and detail
passes; cancellation interrupts the owned reader and rejects late results.
Those engine limits count delivered input bytes, not network-wire traffic or a
hard native-allocation ceiling. Transport safeguards therefore remain separate
from upstream packet parsing. Network-share probes use the same combined API
through their independent, representation-bound transport readers.

Probe coverage and positive results are cached independently for audio and
video, scoped to the original media-source revision. A replaced file invalidates
both, and cancelled or stale responses cannot restore an old revision. Confirmed
facts are reused in the detail snapshot and fresh playback request, rather than
being lost when the server repeats its incomplete metadata.

HDMI acceptance must be confirmed on an HDR10+-capable TV. A successful build,
an HDR10+ source badge, or correct fallback on an HDR10-only TV is not proof of
HDR10+ output.

## Engine Overview

| Engine | Internal name | Underlying tech | Primary use case |
|--------|--------------|-----------------|------------------|
| **Plozzigen** | `.plozzigen` | AetherEngine (FFmpeg demux → HLS-fMP4 → localhost → AVPlayer) | MKV library content — the workhorse (~95% of local files) |
| **Native** | `.native` | AVPlayer directly | Server-delivered HLS/fMP4 (transcodes, direct-play manifests) |

> `.hybrid` is a legacy routing value meaning "this item needs on-device
> decode." It historically selected a libmpv-backed `EngineMPV`, which has been
> **retired** (recoverable at the `archive/mpv-engine` git tag). The router still
> emits `.hybrid` as its abstract "needs on-device decode" signal, but it now
> resolves to **Plozzigen** — the sole on-device decode engine.

## Routing Logic

Engine selection happens in `PlayerViewModel` at playback start:

```
1. Is there a localRemuxSource descriptor?
   NO  → Native (server is delivering a ready-to-play stream)
   YES → continue

2. Is plozzigenEligibility == .eligible?
   NO  → Native (Plozzigen can't handle this container/codec)
   YES → Plozzigen ✓
```

When the router asks for on-device decode (`.hybrid`), it resolves to Plozzigen
if that engine is linked in; otherwise it falls back to Native (AVPlayer).

## Plozzigen Eligibility Gate

Plozzigen accepts content when ALL of these are true:

- **Container:** MKV / Matroska
- **Video codec:** HEVC, H.264, VP9, or AV1
- **Audio codec:** Any (fMP4-legal codecs are stream-copied; eligible TrueHD Atmos
  is spatially rendered on tvOS 26+; other incompatible audio uses the existing
  FLAC/E-AC-3 bridge)
- **Byte-range readable:** HTTP range requests or local file access
- **NOT Dolby Vision Profile 7** (dual-layer BL+EL+RPU — unsupported everywhere)

## Edge Cases the Engines Don't Fully Cover

The retired mpv engine used to absorb these cases. They now route to Plozzigen
(when eligible) or fall back to Native (AVPlayer):

| Scenario | Current handling |
|----------|------------------|
| PGS bitmap subtitles active | AVPlayer has no bitmap subtitle renderer; server-side burn-in/transcode is the path |
| External audio URL | Plozzigen/AVPlayer play the primary track; server-side mux is the path |
| Non-MKV containers (rare edge cases) | Native AVPlayer / server transcode |
| DV Profile 7 dual-layer | Can't be remuxed to single-layer fMP4 |
| Exotic video codecs (MPEG-2, VC-1) | Native AVPlayer / server transcode |

## When Native AVPlayer Is Used

Native handles content the server has already prepared:

- Server-transcoded HLS streams (`.m3u8`)
- Direct-play of natively compatible MP4/MOV files
- YouTube trailers (no `localRemuxSource` — just a URL)

## Quality Capabilities by Engine

| Feature | Plozzigen | Native |
|---------|-----------|--------|
| Dolby Vision | ✅ (Profile 5/8) | ✅ (if server delivers DV) |
| Dolby Atmos | ✅ (E-AC-3 JOC stream-copy; TrueHD Atmos converted to APAC on tvOS 26+ VOD) | ✅ (if stream has E-AC3 JOC) |
| HDR10 / HLG | ✅ | ✅ |
| Full-timeline seek | ✅ | ✅ (if not live transcode) |
| PGS subtitles | ❌ | ❌ |
| DTS:X heights | ✅ (supported lossless DTS:X converted to APAC on tvOS 26+ native/HLS VOD) | ❌ |
| DTS bitstream | ❌ (channel audio uses FLAC/E-AC-3 bridge) | ❌ |
| TrueHD bitstream | ❌ (eligible Atmos uses APAC; otherwise FLAC/E-AC-3 bridge) | ❌ |

## AirPlay 2 / HomePod Audio Recovery

The Plozzigen and Native engines both output audio through `AVPlayer` +
`AVAudioSession`, so they are subject to the **AirPlay 2 / HomePod silent-drop**
that was root-caused and fixed for music. The cure (a full audio-session
deactivate→reactivate cycle — `setActive(true)` alone is a no-op), plus what
did/didn't work and how to port it to video seek/route-change handling, is
documented in **[airplay-audio-recovery.md](./airplay-audio-recovery.md)**.

## Source Code References

- Eligibility gate: `Sources/CoreModels/LocalRemuxModels.swift` → `plozzigenEligibility`
- Engine routing: `Sources/FeaturePlayback/PlayerViewModel.swift` → engine selection block
- Plozzigen adapter: `Sources/EnginePlozzigen/PlozzigenVideoEngine.swift`
- Engine factory: `Sources/FeaturePlayback/EngineFactory.swift`
- AetherEngine dependency: `Package.swift` → `superuser404notfound/AetherEngine`

## History

Plozzigen replaced a custom local-remux engine (CRemuxCore + cue-table approach)
that suffered from audio/video desync, fragile resume behavior, and inability to
handle Plex content correctly. The prior engine's experimental branches are
preserved under `preserve/remux-*` git tags for reference but are not used.

AetherEngine was adopted because it solves the exact same problem (MKV → AVPlayer
with DoVi + Atmos + seeking) with a battle-tested pipeline. Plozz wraps it via
the `PlozzigenVideoEngine` adapter conforming to the `VideoEngine` protocol.

An earlier libmpv-backed `EngineMPV` engine (routed via `.hybrid`) was also
retired once Plozzigen covered the on-device decode path. Its source, build
scripts, and staged xcframeworks were removed; it's fully recoverable at the
`archive/mpv-engine` git tag.
