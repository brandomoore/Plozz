# Live TV reliability decisions

Prioritize uninterrupted healthy playback, bounded recovery, useful errors and
correct guides. Learn failure scenarios from other players; adopt a change only
when Plozz has a demonstrated gap. This is a targeted source comparison, not a
runtime quality ranking of those applications.

Current behavior belongs in [Live TV](live-tv-prototype.md) and
[playback routing](playback-engines.md#iptv-live-streams). Historical context is
in [IPTV history](iptv-history.md). This document owns decisions and remaining
evidence gaps, not duplicate implementation instructions.

## Next decisions

| Priority | Evidence / uncertainty | Next action and acceptance criterion |
| --- | --- | --- |
| Remaining schedule size | The old "Live TV preferences" category included generated-channel definitions and full library-item snapshots. Downloaded IPTV guides/catalogues remain local. Existing published duplicates and overlapping-but-different item sets still occupy space. | Use the separated breakdown, including pending bytes, to attribute actual data. A more compact cross-device format needs explicit migration/older-client compatibility, not removal of required schedule inputs. |
| Remaining guide work | Large downloads now reuse temporary file-backed data. Each channel batch still parses the document, and the first download still assembles Data. | Profile the remaining parsing/peak-memory cost before adding an indexed representation. Preserve exact matching, windows, cancellation and HTTP cache directives. |
| Playback fault breadth | Bounded synthetic sessions are not an evening of real-provider viewing. | Cover discontinuities and key/init changes independently of session renewal. Require advancing decoded images, bounded recovery, preserved pause intent and zero owned requests after stop. |
| Plex shutdown | Shared and Plex lease owners serialize updates before closing; obsolete queued reports may delay cleanup behind a slow request. No user-visible failure is demonstrated. | Reproduce blocked transport plus queued updates before changing ordering. Preserve exactly-once owned-session cleanup and never release another viewer's tuner. |
| Real-provider confirmation | Simulator fixtures do not establish Dispatcharr interoperability or resolution of the Level Up report. | Exercise representative authorized server/feed inputs, including audio on hardware. Keep this distinct from local installation success. |

Use existing [performance workloads](performance-lab.md) and
[test runners](testing-policy.md). Record the baseline before editing; compare
the same completed workload afterward. No-benefit findings are valid. Do not
add retries, raise limits, or introduce another engine merely to match a reference.

## Decisions implemented

| Problem demonstrated | Decision | Regression owner |
| --- | --- | --- |
| Schedule inputs were counted as ordinary preferences; total retained bytes looked like recurring upload work. | Separate Plozz Channels schedules and show pending-upload bytes. Keep totals honest: these are local encoded payloads, not measured CloudKit storage/traffic. | [Inventory tests](../Tests/FeatureSyncCloudTests/CloudSyncDataInventoryTests.swift) |
| Advancing a published guide horizon re-encoded unchanged snapshots; metadata-only automatic recipe changes duplicated inputs. | Revalidate definitions while reusing encoded records; share identical snapshot inputs for new revisions. Preserve existing revisions, profile ownership and v1 wire compatibility. | [Capture tests](../Tests/AppRuntimeTests/LiveTVPortableCapturePerformanceTests.swift), [schedule tests](../Tests/FeatureLiveTVCoreTests/LibraryChannelSyncSizeTests.swift) |
| A guide larger than 16 MiB was downloaded again for each channel batch. | Retain one account-scoped document per provider instance using the existing temporary mapping primitive; expire within 60 seconds or a shorter max-age. No-store/no-cache remain uncached. | [Cache tests](../Tests/ProviderIPTVTests/IPTVGuideCacheTests.swift), [measured workload](../Tests/ProviderIPTVTests/IPTVPerformanceProbeTests.swift) |
| A finite 429 cooldown blocked a proxy for its lifetime; overlapping shorter refusals could shorten an active cooldown. | Honor strict seconds/HTTP-date Retry-After with monotonic deadlines; preserve the longest cooldown and terminal refusals. No new retry loop. | [IPTVPlaybackRecoveryTests](../Tests/ProviderIPTVTests/IPTVPlaybackRecoveryTests.swift) |
| Dispatcharr-style JSON 503 capacity errors lost their cause. | Classify the original response with bounded bytes/time. Show the existing capacity error without another diagnostic GET or retaining provider text. | [IPTVPlaybackDiagnosticsTests](../Tests/ProviderIPTVTests/IPTVPlaybackDiagnosticsTests.swift), [hosted playback](../Tests/SubtitlePresentationSupport/IPTVContinuityHostedTests.swift) |
| HTTP-200 HTML/JSON/XML/empty live roots reached the decoder as media. | Recognize conservative signatures using the existing 16-byte prefix; preserve upstream status and suppress repeat origin attempts on that lease. HEAD, ranges, encrypted children and VOD remain opaque. | [Proxy diagnostics](../Tests/ProviderIPTVTests/IPTVPlaybackDiagnosticsTests.swift), [engine failures](../Tests/EnginePlozzigenTests/PlozzigenLiveFailureTests.swift) |
| Three retunes exhausted recovery permanently despite later healthy viewing. | Replenish after 300 seconds of observed advancing playback. Interruptions/sample gaps discard credit; retain three attempts, 20-second spacing and current authorization/pause gates. Five minutes is a policy choice, not a measured optimum. | [Budget tests](../Tests/FeaturePlaybackTests/LiveChannelRetuneBudgetTests.swift), [model tests](../Tests/FeaturePlaybackTests/LiveChannelPlayerModelTests.swift) |
| Configured Xtream XMLTV 404 repeated across batches and blocked available account-guide recovery. | After other explicit guides, allow the same account's whole-guide `xmltv.php`; reuse confirmed 404s only within that refresh. Do not add per-channel recovery fan-out or hide other errors. | [Provider tests](../Tests/ProviderIPTVTests), [guide imports](../Tests/FeatureLiveTVCoreTests/LiveTVServerGuideImportTests.swift) |
| Valid playlist/guide variants were unsupported. | Accept `tvg-url`, colon-form numeric timezones and bounded programme-only channel identities. Do not guess names or weaken matching. | [XMLTV parser](../Sources/FeatureLiveTVCore/LiveTVXMLTVParser.swift), [Live TV core tests](../Tests/FeatureLiveTVCoreTests) |

Implementation commits: `4c93f73a4` (transport/continuity), `6e820ea90` (guides),
`f19ba41f6` (recovery credit/non-video responses).

## Invariants to preserve

- Ordinary failed refreshes retain last-good catalogues/guide windows;
  authorization revocation does not permit stale-data access.
- Guide failure does not interrupt an unrelated active stream. An empty
  successful guide is different from an error or unrequested coverage.
- One live relay does not open overlapping root streams. HLS child requests and
  intentionally separate Multiview streams are different cases.
- Current ownership, profile/account authorization, pause intent and cancellation
  are rechecked after asynchronous work. Removed sources cannot reappear.
- Credentials stay within their permitted origins and secure stores. Diagnostics
  contain fixed classifications/counts, not stream addresses or provider bodies.
- Stream/guide matching and persistent channel identities are not optimization
  shortcuts. Existing favorites and manual mappings must survive.

Coverage: [provider lifecycle](../Tests/ProviderIPTVTests/IPTVPlaybackLifecycleTests.swift),
[redirects](../Tests/ProviderIPTVTests/IPTVPlaybackRedirectTests.swift),
[playback ownership](../Tests/FeatureLiveTVCoreTests/LiveTVPlaybackPreparationTests.swift),
[indexed cache](../Tests/FeatureLiveTVCoreTests/LiveTVIndexedCacheTests.swift).

## What the comparison changed

| Reference and pinned revision | Useful lesson | Decision / tradeoff |
| --- | --- | --- |
| [Rivulet](https://github.com/l984-451/Rivulet/tree/926e30eace67eddcb9a1981943e2e9201df5a27a) | Distinguish capacity refusals, preserve pause intent, retire obsolete keepalives. | Independently implemented response classification; keep Plozz's ownership guards. Queued shutdown work remains a candidate. |
| [Lume](https://github.com/bilipp/Lume/tree/a1edf063efafddbc39f6588ab1403b683a807b17) | Coalesce recovery; distinguish unmeasured sessions from healthy ones; cap slow-start allowances. | Do not reset attempts on a momentary playing state or open a replacement before the old session closes. Adaptive startup needs a reproduction first. |
| [AerioTV](https://github.com/jonzey231/AerioTV/tree/c3a5334830a8e49d3d4adf1e1dff11f5c21a078b) | Bounded-memory guide loading and meaningful provider refusal errors. | Investigate remaining guide download/parse costs; reject extra diagnostic GETs and response-text logging. |
| [OrivioTVAppleTV](https://github.com/prehakanson-art/OrivioTVAppleTV/tree/5e4c904f165238fff3181f87cdc48bf426007552) | Repeated buffering events must not indefinitely rearm recovery; a timer tick is not playback progress. | Preserve engine-authoritative phases; verify failure scenarios rather than adding a second state machine. |
| [IPTVnator](https://github.com/4gray/iptvnator/tree/9c5bbf628d070a8fe16b0d624a04e94e9782116f) | Keep spent attempts through brief recoveries; retire obsolete guide work. | Supports sustained-health recovery and existing generation fences, not its exact retry counts or platform mechanisms. |

Inspect the pinned implementations and regressions, not stars or README claims.
Rivulet is PolyForm Noncommercial, Lume AGPL-3.0, AerioTV/OrivioTV GPL-3.0 and
IPTVnator MIT. These changes were implemented independently; no source was
transplanted.

## Evidence and limits

Matched optimized tvOS/iOS simulator workloads, with one warmup and five samples:

| Completed workload | Before → after | CPU median reduction, tvOS / iOS |
| --- | --- | --- |
| Seven captures, including five horizon-only edits and one real input change | Seven → two full snapshot encodes | 57% / 62% |
| Five real-planner channels after metadata spelling changes | Nine → five snapshots; 3.69 → 2.21 MB encoded | 23% / 30% |
| Two guide batches, 4,000 channels and 32,000 returned programmes | Two → one download; 47.66 → 23.83 MB; two parses unchanged | 15% / 27% |

These are generated workloads, not a promised reduction in an existing user's
cloud footprint. Previously published snapshots are not rewritten. Resident
memory snapshots were mixed and are informational, not proof of lower peak
memory or absence of leaks. Guide reuse trades bounded temporary disk I/O for
fewer downloads; capture reuse retains immutable encoded backing longer.
No cloud schema, compression format, source-restoration or schedule policy changed.

The 2026-10-20 follow-up ran `IPTVContinuityHostedTests` and
`IPTVPlaybackHostedTests` on tvOS 26.2 and iOS 26.2 with the real provider, lease,
proxy, engine and player model. Each platform had 21 passes and one opt-in
real-relay skip. Healthy rolling fMP4 presented 899 changing images over 60
seconds. Disconnect recovery produced visible gaps, not seamless playback.
Audio was muted. These observations do not prove hours-long or audible
continuity; five-minute recovery credit was separately tested with injected time.

An additional 330-second fMP4 scenario passed on both platforms with three
session expirations, explicit pause, background/foreground and resume. It
presented 4,900 / 4,901 changing images (tvOS / iOS), opened exactly four origin
sessions and left zero owned requests after stop. Longest image gaps were
3.10 / 3.20 seconds, including the deliberate three-second pause. This exercises
repeated renewal, not 300 consecutive healthy seconds across those interruptions.

Fixtures are locally generated, not television content: ffmpeg `testsrc2`,
160x90 at 15 fps, H.264 ultrafast/CRF 32/GOP 30/yuv420p and mono 48 kHz AAC.
The 90-second TS and 420-second fMP4 single-file HLS indexes use two-second
segments. The HTTP fixture publishes an advancing four-segment window, or eight
segments for the pause scenario so native live holdback leaves a usable DVR range. See
[IPTVContinuityHostedTests](../Tests/SubtitlePresentationSupport/IPTVContinuityHostedTests.swift)
and its fixture resources for the actual workload.

## Deferred behavior and features

Partial guide publication requires explicit incomplete-coverage/error semantics;
the current array-or-error API can discard new partial rows when a later required
source fails. Do not silently turn that into success or weaken auth/cancellation.
Dedicated Dispatcharr onboarding, DVR, provider archive catch-up, recommendation
shelves and sports integrations remain deferred, not reliability work.

[#107](https://github.com/brandomoore/Plozz/issues/107) and
[#116](https://github.com/brandomoore/Plozz/issues/116) supplied evidence of an
explicit Level Up XMLTV HTTP 404, not confirmation that the configured URL or
actual service is fixed. [#113](https://github.com/brandomoore/Plozz/issues/113)
and [#168](https://github.com/brandomoore/Plozz/issues/168) likewise need their own
relevant evidence; these controlled changes do not establish their causes.

### XMLTV compatibility comparison

The October 22 build-61 diagnostic for #116 shows the missing explicit guide
falling back successfully to HTTP 200 and 94,191,315 bytes of XML. Parsing then
fails as `malformed`; subsequent channel batches reuse the downloaded body and
the remembered 404. The attachment does not contain the XML or a native parser
error, so the rejected construct and actual provider compatibility remain
unconfirmed.

Behavioral references, not copied implementations:

- [Kodi IPTV Simple](https://github.com/kodi-pvr/pvr.iptvsimple/blob/2066e6e6d9fc34f7fe454d91025bcb56de156b74/src/iptvsimple/Epg.cpp)
  and its [channel metadata handling](https://github.com/kodi-pvr/pvr.iptvsimple/blob/2066e6e6d9fc34f7fe454d91025bcb56de156b74/src/iptvsimple/data/ChannelEpg.cpp)
  combine repeated channel IDs and expose parser errors. Plozz independently
  combines names only for identical IDs, retains its stricter identity/region
  safeguards, and logs numeric locations/codes instead of source fragments.
- [Jellyfin.XmlTv](https://github.com/jellyfin/Jellyfin.XmlTv/blob/6c8c302c8520e5f41cd51dd392ac631f97179d82/src/Jellyfin.XmlTv/XmlTvReader.cs)
  accepts reduced-precision dates and disables character checks in its XML
  reader. Plozz accepts minute precision but does not copy broad character
  validation bypasses or guess repairs for malformed XML. Its text selection
  now follows the same requested-language, untagged, first-usable fallback order
  without retaining every translation.
- [Tvheadend's XMLTV importer](https://github.com/tvheadend/tvheadend/blob/51ec612fa22c4c78b4697e4c262c943da9cbd6cc/src/epggrab/module/xmltv.c)
  skips channel records without IDs and preserves language-tagged programme
  text. Plozz likewise skips unusable channel declarations with diagnostic counts,
  while retaining its XML/entity checks, resource budgets and exact identities.
- The [XMLTV specification](https://github.com/XMLTV/xmltv/blob/f33601698cf1f1c7a67030b9ec2d3ad565421b5a/xmltv.dtd)
  allows shortened timestamps, optional channel declarations and multiple
  display names. Plozz already supports programme-only feeds and standard
  DOCTYPEs; its declaration guard now distinguishes real entities from literal
  mentions in comments, processing instructions and CDATA.

The parser, gzip and indexed paths share regression coverage for these cases,
strict failure/privacy behavior, cancellation and resource budgets. These are
bounded compatibility changes, not proof that Level Up's particular XML is
accepted. Fresh diagnostics can distinguish syntax, structural, entity and
resource failures without collecting feed content.

### Further guide compatibility

The November 14 comparison inspected Lume at
[`b3648b8`](https://github.com/bilipp/Lume/tree/b3648b8a56d6b907cb5142fac4c56e71d05ee48c),
specifically its
[XMLTV parser](https://github.com/bilipp/Lume/blob/b3648b8a56d6b907cb5142fac4c56e71d05ee48c/Lume/Services/Network/XMLTVParser.swift),
[timestamp reader](https://github.com/bilipp/Lume/blob/b3648b8a56d6b907cb5142fac4c56e71d05ee48c/Lume/Services/Network/XMLTVDate.swift)
and background guide scheduling. Its streaming batches and explicit coordination
with catalogue refresh are useful comparison points, not evidence that all of
its parser fallbacks are appropriate here. Plozz does not adopt unchecked partial
XML publication or a locale-dependent date fallback.

The XMLTV DTD's shortened-date contract and
[Jellyfin.XmlTv's date cases](https://github.com/jellyfin/Jellyfin.XmlTv/blob/6c8c302c8520e5f41cd51dd392ac631f97179d82/tests/Jellyfin.XmlTv.Tests/XmlTvReaderDateTimeTests.cs)
identified a concrete gap: valid year/month/day/hour precision was dropped.
Plozz now interprets omitted components as the start of the specified period,
preserving strict calendar/offset validation and existing stop-time rules.
Independently authored fixtures cover plain XML, gzip, indexed ingestion and
replacement of an older empty account index.

Inspection also found that manual station search considered only the first
display name. It now searches all declared aliases without merging station
identities, changing automatic matching or confirming a correction. Bounded
parse summaries distinguish unmatched stations, out-of-window listings and
unusable row fields without exposing feed content. These changes use Plozz's
existing implementations; no reference source was transplanted. They do not
establish compatibility with an unavailable failing provider feed.
