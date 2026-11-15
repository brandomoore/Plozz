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
| Guide revalidation | Account guides reuse encrypted station indexes and persist ETag/Last-Modified for eligible conditional requests. | A 304 preserves the generation; changed projections/windows require a full response. Preserve exact matching, cancellation and HTTP cache directives. |
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

Independent guide-source failures now carry usable rows through
`ServerLiveTVPartialGuideError`; consumers preserve the failure and old listings
for uncovered channels. Publishing part of a malformed XML document remains
deliberately unsupported. Do not silently turn either failure into success or
weaken auth/cancellation.
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
  reader. Plozz accepts reduced precision but does not copy broad character
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

### Refresh coordination and real-guide evidence

Lume's [refresh gate](https://github.com/bilipp/Lume/blob/b3648b8a56d6b907cb5142fac4c56e71d05ee48c/Lume/Services/Sync/EPGSyncService.swift)
prevents background EPG work from racing playlist sync and cancels an already
running background refresh when content sync starts. Plozz's catalogue and guide
transfers previously had independent admission. The new provider-local queue
serializes catalogue imports, XMLTV downloads and Xtream per-channel guide requests.
It prioritizes queued catalogue work but keeps an active transfer intact rather
than throwing away its bytes. Saved playback-locator reads remain available.
This is an independently implemented policy, not copied reference code.

Public snapshots captured November 14, 2026:

| Feed | Declared stations | Source programmes | Exact-ID sample | Compared listings |
| --- | ---: | ---: | ---: | ---: |
| Pluto TV US | 457 | 9,224 | 12 stations | 259 |
| EPGShare US2 | 792 | 82,203 | 12 stations | 1,482 |

The capture tool uses an independent XML/date reader to record explicit schedule
intervals. Production gzip parsing and indexed streaming agree with those intervals
for all 24 sampled stations, not merely with each other. The sample IDs are drawn
from guide declarations: this is not evidence of automatic matching against a
real subscriber's playlist, correct regional assignment, or broadcast accuracy.
Raw snapshots, names and listings stay in ignored local storage, not this document.

A separate opt-in live run used real URLSession networking and the production
downloader, then indexed every declared station through the production parser.
Pluto returned 998,824 compressed bytes and 9,224 windowed listings across 457
stations; EPGShare returned 6,833,546 bytes and 70,740 windowed listings across
792 stations. The latter count differs from the source total because ingestion
applies the requested time window. Full-feed ingestion is not an independent
correctness comparison for every listing; the exact interval comparison above
remains limited to the 24 sampled stations.

The same captured payloads also exercise a controlled single-connection transport.
An uncoordinated production-HTTP control receives one HTTP 503 when catalogue and
guide requests overlap. The coordinated client completes both with one active
refresh request and zero refusals. Tests cover both arrival orders, queued
catalogue priority, cancellation, teardown, cache reuse and account isolation.
This proves the scheduling decision under that declared constraint, not that a
particular public or commercial provider applies it. No concurrency stress is
sent to the public endpoints and no stream is opened.

The sampled Pluto stations had 15.38-19.41 hours of future listings at capture;
EPGShare had 53.16-60.49 hours. These snapshots do not establish publication
cadence, typical paid-provider behavior, or justify an adaptive polling policy.

### Conventional guide freshness and conditional revalidation

The reference players do not establish a universal paid-provider interval:

| Primary source | Verified behavior |
| --- | --- |
| [IPTVnator guide fetching](https://github.com/4gray/iptvnator/blob/9f125b93895ffc07453235f1ed5d03db3604412b/apps/electron-backend/src/app/events/epg-fetch.service.ts) | Whole XMLTV source freshness is 12 hours. Fresh sources are skipped; this is not evidence of a repeating background timer. |
| [Open TV Xtream guide fetching](https://github.com/Fredolx/open-tv/blob/1bfa78a181166025a6b977d783f895e819ff720f/src-tauri/src/xtream.rs) | Channel schedules are requested on demand through the Xtream API, not by periodically downloading every channel's guide. |
| [Lume frequency settings](https://github.com/bilipp/Lume/blob/b3648b8a56d6b907cb5142fac4c56e71d05ee48c/Lume/Services/Sync/SyncFrequency.swift#L77-L105) | Guide default is daily, independently of the three-day playlist default. Six-hour, daily, three-day and weekly choices exist. |
| [Jellyfin guide task](https://github.com/jellyfin/jellyfin/blob/2953ed632c9277351483eff04f87a8276390691c/src/Jellyfin.LiveTv/Guide/RefreshGuideScheduledTask.cs#L62-L73) and [XMLTV cache](https://github.com/jellyfin/jellyfin/blob/2953ed632c9277351483eff04f87a8276390691c/src/Jellyfin.LiveTv/Listings/XmlTvListingsProvider.cs#L30-L159) | The task defaults to 24 hours. Its separate one-hour document cache/failure cooldown preserves the last downloaded file on ordinary refresh failure. Cache lifetime is not the scheduled refresh interval. |
| [Kodi IPTV Simple settings](https://github.com/kodi-pvr/pvr.iptvsimple/blob/0159d1149b33df2fcb4123087790af1fa4f516f2/pvr.iptvsimple/resources/instance-settings.xml#L63-L105) | Combined M3U/XMLTV auto-refresh defaults to disabled. Optional repeated refresh defaults to 60 minutes; optional daily refresh defaults to 04:00. The 60-minute value is not an enabled default. |

Official TiviMate and Sparkle pages confirm user-supplied playlist/guide support,
but did not establish current refresh defaults. Reseller claims and user-count
assumptions are not evidence of provider publication cadence or connection limits.
No authorized paid IPTV account was available for this comparison.

Plozz adopts a 12-hour default/maximum for account XMLTV indexes, following
IPTVnator's comparable whole-feed use case. It is a conventional starting point,
not a measured optimum or a claim that all players agree. Shorter HTTP freshness
and no-cache still apply. The existing guide-use/resume path rechecks due IPTV
windows; it does not add a background timer, a coverage-triggered early refresh,
or a promise of OS background execution.

Xtream channel schedules remain demand-driven. A provider capability limits
startup and explicit preparation to the first viewport rather than issuing a
request for every channel; browsing loads further channels as needed. XMLTV
still indexes the complete catalog, and once that index is saved and fresh it
answers browsing requests before the native API is asked. Channels without a
guide identity are never requested per channel. A transient native failure ends
that batch's native requests and keeps the listings already retrieved. Populated feeds with no matches or no rows
in the requested window retain normal source freshness. A truly empty XMLTV
source and a successful empty viewport instead use a 60-second on-demand
negative cache, not 12 hours; shorter source HTTP freshness still applies.
Restoration, 304 and identical-200 revalidation preserve that distinction.
An empty viewport alone does not cause early whole-feed downloads.
Ordinary failed refreshes keep visible
listings and report the failure; they do not mark stale data fresh.

For per-channel sources, guide-only filtering retains unrequested channels so
it cannot prevent their schedules from being discovered. Successful requests
resolve pending channels; partial failures resolve only channels with listings.
Explicit source refresh makes previously browsed windows due without discarding
visible rows or eagerly fetching the unsampled lineup. Regression cases cover
a guide-bearing channel beyond the first 12, confirmed empty filtering, partial
failure/denial, and refreshing an unsampled channel on demand.

Account XMLTV validators live inside the existing encrypted, authorization-scoped
index document. A 304 only succeeds when the exact source, projection and retained
window can answer the request; otherwise a full document is required. Revalidation
does not invent more coverage. Redirected validators are attached only to the
exact final resource that issued them, not other paths or hosts. A malformed 200
replacement preserves committed rows and metadata. No-store revokes persistence,
including a 304 no-store, which requires an unconditional replacement.

Servers rejecting conditional headers with 400, 405, 412, 431 or 501 receive
one ordinary fallback only when the response belongs to the validator-owning
resource and has no Retry-After header. Its failure is surfaced without another
retry. Authorization failures, missing feeds, throttling and redirect policies
remain unchanged. Oversized or newline-bearing optional cache headers no longer
reject otherwise usable XMLTV: validators are discarded, while unusable
cache-policy headers disable persistence and freshness conservatively.

Public response headers supported this design: Pluto advertised an ETag and
300-second max-age; EPGShare advertised ETag, Last-Modified and 14,400-second
max-age. Neither value proves how often new programme data is published.
One conditional GET against each unchanged feed returned HTTP 304 with zero
response-body bytes, compared with 7,832,370 combined bytes for the full bodies.
That initial measurement was a separate HTTP probe, not total network traffic.
The opt-in `IPTVGuideRefreshTests` live test now also exercises Plozz's production
conditional download path after indexing each public feed, reporting the actual
304/200 outcome and body size; publication may legitimately race revalidation.
In the implementation verification, both feeds returned 304 with zero body bytes.
The preceding full responses indexed 9,224 Pluto and 69,624 EPGShare programmes
in the requested retention windows; those counts describe this run, not guaranteed
provider coverage. The captured replay separately retained all 1,741 independently
derived sampled intervals across the two feeds.

Deterministic guide-index, transport, preparation and window tests cover restored
validators, the 12-hour boundary, changed 200 responses, 304 generation reuse,
source/window eligibility, HTTP directives, redirect isolation, failures and
bounded per-channel preparation. Existing cancellation, partial-result and
account-isolation cases remain part of focused regression coverage.
Compatibility regressions also exercise conditional rejection and refusal
boundaries, unusable optional headers, empty-source recovery, and populated
unmatched/out-of-window sources that must not refetch early. Captured public
feed replay continues to match the 1,741 independently derived sample intervals;
the imperfect-server cases are controlled fixtures, not paid-provider evidence.
The public corpus does not establish subscriber-playlist matching or the
distribution of paid-provider behaviors; no authorized paid account is available.
