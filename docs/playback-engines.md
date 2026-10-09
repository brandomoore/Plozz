# Playback Engine Architecture

Plozz uses two playback engines, automatically selected per-item based on
container, codecs, and subtitle requirements. The goal is maximum format coverage
with the best possible quality (Dolby Vision, Atmos, full-timeline seek).

## IPTV live streams

IPTV playlist URLs can declare live output as `ts` or `m3u8` while publishing
extensionless channel URLs. The provider carries that declaration into its
encrypted loopback URL without changing the upstream address or opening an
extra probe connection. This keeps declared MPEG-TS on the ingest/remux path
instead of the HLS-only native bypass. Explicit stream extensions take
precedence; the hint never applies to movies, episodes, or HLS child resources.

Raw live transport streams (`ts`, `m2ts`, `mts`) use Aether's supported `fastZap`
join profile. Unlike HLS, these sources have no existing playlist window to
fetch: the standard full-holdback gate can wait longer than AVPlayer's initial
playlist timeout on a long-GOP channel. Fast start permits a shallower initial
window after two finalized segments and a bounded grace period. It can trade
some initial buffering protection for earlier playback; it does not remove the
source's keyframe wait or guarantee instant tuning. Native HLS and unknown-format
streams keep their existing route and standard join policy; on-demand is unchanged.

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

Plozz pins the subtitle-corrected
[AetherEngine fork](https://github.com/brandomoore/AetherEngine/tree/53a85c708dcfb4fa539cc97909b0d1d67edbc920)
at commit `53a85c708dcfb4fa539cc97909b0d1d67edbc920`, based directly on upstream
release **7.23.0** (`cb439e8593cb9bfc052b0c80e16c0637d143eb3d`).
ASS/SSA packets with neither a decoded end nor a packet duration are now discarded
instead of lingering for a fabricated five seconds. This also applies to sidecars;
other subtitle codecs retain their established fallback. The 7.23.0 audio-output
flush epoch prevents a buffer decoded before a software seek from entering
the newly flushed queue, where its old timestamp could leave playback silent.
Its subtitle packet store appends in place rather than copying all retained
packets on every addition, reducing contention during dense ASS openings.
FFmpegBuild and LibDovi stay on their prior minor versions.

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
owns the FFmpegBuild 3.6.x and LibDovi 2.1.x dependencies; Plozz does not link a
second FFmpeg build. This release also retains both earlier integration fixes:

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
- **Audio codec:** Any (fMP4-legal codecs are stream-copied; incompatible ones
  like TrueHD/DTS are bridged to lossless FLAC internally)
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
| Dolby Atmos | ✅ (passthrough) | ✅ (if stream has E-AC3 JOC) |
| HDR10 / HLG | ✅ | ✅ |
| Full-timeline seek | ✅ | ✅ (if not live transcode) |
| PGS subtitles | ❌ | ❌ |
| DTS bitstream | ❌ (bridged to FLAC) | ❌ |
| TrueHD bitstream | ❌ (bridged to FLAC) | ❌ |

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
