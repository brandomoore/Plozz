# Playback Engine Architecture

Plozz uses two playback engines, automatically selected per-item based on
container, codecs, and subtitle requirements. The goal is maximum format coverage
with the best possible quality (Dolby Vision, Atmos, full-timeline seek).

## Dependency version

Plozz pins upstream AetherEngine **7.8.1** to commit
`b89240afcaebb958632b4b2c69284138c96e275f`. Its iOS/tvOS 18 minimum matches
Plozz's existing deployment targets. The engine owns the FFmpegBuild 3.4.x and
LibDovi 2.1.x dependencies; Plozz does not link a second FFmpeg build.

This release contains both merged integration fixes:

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

### Supplemental Emby HDR10+ detection

Emby's `ExtendedVideoType` can identify HDR10+, but a missing declaration is
not proof that the file lacks dynamic metadata. The delayed detail-page probe
can confirm HDR10+ on an original HEVC source independently of its audio codec,
including titles whose Atmos badge is already known. It is not a library-wide
scan and playback never waits for it.

The HDR probe examines bounded video packets, not filenames or arbitrary byte
matches in a container. Only positively identified HDR10+ metadata upgrades the
source badge. An exhausted budget, inaccessible stream or ordinary HDR10 result
does not downgrade a server declaration. Dolby Vision keeps its primary
classification. The existing Atmos decode probe is requested only when its own
confirmation is missing.

HDR inspection is capped at 8 MiB of reserved HTTP ranges, 128 packets and five
seconds, with two-second request deadlines. Ignored or invalid Range responses
are rejected before buffering a full body; redirects may not cross origins.
The engine's existing FFmpeg libraries demux the bounded data, and the probe
validates HEVC SEI/T.35 HDR10+ payloads without opening a video decoder.

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
