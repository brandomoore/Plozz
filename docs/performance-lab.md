# Simulator performance lab

Use this for the agent-driven optimization loop without installing on an Apple
TV, iPhone, or iPad. It complements [physical profiling](performance-debugging.md),
not a replacement for device-specific evidence. No cloud account, real media
server, credential, or external model service is required.

## Agent entry point

From the active checkout, inspect the machine-readable inventory:

```sh
python3 tools/performance.py list
```

Use a simulator you own. Select an explicit platform and UUID; an iPad is an
`iOS` simulator. The runner verifies platform, runtime build, and device type
before booting, never selects a different simulator or discovers physical devices.

```sh
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
python3 tools/performance.py run --platform tvOS --sim-id "$PLOZZ_SIM_ID" --suite core
python3 tools/performance.py run --platform tvOS --sim-id "$PLOZZ_SIM_ID" --suite matrix
python3 tools/performance.py run --platform iOS --sim-id "$PLOZZ_IOS_SIM_ID" --suite ui
```

`core` is the default. `ui`, `matrix`, `diagnostics`, `network`, and `all` are explicit selections.
Suites include only scenarios supported on the requested platform; explicitly
requesting a platform-incompatible scenario fails before a build starts.
For a bounded investigation, select one or more scenario names instead of a suite:

```sh
python3 tools/performance.py run --platform tvOS --sim-id "$PLOZZ_SIM_ID" \
  --scenario sync-unchanged library-unchanged
```

These are optimized **Debug `-O`** tests so DEBUG-only test interfaces remain
available. They are not a distribution Release build. The debugger, coverage,
sanitizers, and parallel test execution are disabled for measurement. Run
correctness/sanitizer checks separately, not inside the timing experiment.
Builds are incremental in platform- and lane-private DerivedData. Each group
builds once and executes without rebuilding. There is no cache deletion,
from-clean recovery, test retry, dependency version update, or hardware install.

The whole lane owns a shared Apple build lease, including gaps, and a local
performance-runner lock. Do not overlap with another project writer in this
checkout. The runner temporarily moves a shadowing generated project while
using package test schemes, then restores it; a restoration conflict preserves
both copies and fails. A simulator booted by this invocation is shut down in
`finally`; a caller-owned simulator that was already running stays running.
The default whole-run limit is 2,400 seconds (`--timeout`, bounded to 60–7,200).
Cancellation/timeout stops only the owned process group and preserves evidence.

## Baseline → attribution → candidate → regression

`skeletons-idle` observes 24 production `SkeletonCardView` placeholders over
2.3-second idle windows on either platform. It verifies all placeholders mounted
and captures changing visible pixels before timing, so removing the animation
cannot count as an optimization. `skeletons-static` uses the same content with
implicit animations disabled and verifies stable pixels; it is an animation-cost
control, not a simulated system Reduce Motion setting. `cards-idle` separately
covers settled artwork. These fixtures are not the complete Home screen or a
multi-server account. CPU measurements include the app process only; resident
snapshots do not measure GPU/render-server memory or physical-device energy.

The iOS `mobile-preference-sync` scenario applies 24 cloud batches through the
real mobile app model, updating active Hero preferences and an inactive profile's
preferred version in each batch. It verifies all 48 applied values and counts
account invalidations, index resets, and download-model replacements. With no
accounts or external services, it isolates synchronous configuration-apply work;
it does not measure full network/indexing completion, CloudKit delivery, rendered
frames, or physical-device temperature and battery use.

The iOS `mobile-profile-selection` scenario activates sixteen synthetic profiles
through the real app model. It reports synchronous selection time separately
from a fixed 5 ms Plex metadata delay, checks that every selection reaches the
PIN gate, and verifies tokens remain denied. It measures activation work, not
rendered frame pacing or physical-device network latency.

`mobile-home-rail-prefetch` updates the real mobile Continue Watching rail 24
times with the same 180 metadata-rich episodes across twelve synthetic account
identities. Artwork is preloaded into the test cache and online providers are
disabled. It counts series-source construction while preserving every item and
waiting for each hosting-graph update. It isolates repeated layout/prefetch-key
work, not twelve connected servers, profile-transition frame pacing or hardware
scrolling. `watchlist-artwork-rehydration` separately exercises the production
Plex/Jellyfin credential-restoration path, checking every title and cast image.

`mobile-video-glow` measures the light inline video preview in 2.3-second
windows against the existing 160-by-90 continuity fixture. Require the same
surface and advancing playback; it isolates preview overhead, not HD decoding.
`mobile-video-glow-hd` and `mobile-video-glow-hd-disabled` use the same
1920-by-1080, 30 fps synthetic video with and without the color glow. The enabled
case must complete new samples, capped at five per window; the disabled case
must have no sampling task. These report app-process CPU and resident memory,
not GPU/render-server cost or physical-device energy and frame pacing.

The glow fixtures in `Tests/SubtitlePresentationSupport/Fixtures` are synthetic:
`live-continuity-dim.mp4` is the first 30 seconds of `live-continuity.mp4`,
scaled by `colorchannelmixer=rr=0.18:gg=0.18:bb=0.18` and encoded with
libx264 CRF 24. `glow-software.mkv` is its first eight seconds, encoded as MPEG-2
at quality 3 to require the software route. `glow-hd.mp4` uses FFmpeg
`testsrc2=size=1920x1080:rate=30:duration=35`, libx264, preset `veryfast`, CRF 28.
All omit audio and use yuv420p. The dim fixture changes decoded pixels, not an
overlay above the video, so it actually exercises color extraction on dark input.

`mobile-profile-pin-handoff` unlocks a local profile in a sixteen-profile
household using the production 120,000-round verifier. It separates verification
duration from the largest 2 ms main-actor heartbeat gap. Initialization settles
before sampling, and all repetitions reuse one household; the warmup covers
first-entry settings migrations. Each measured switch first leaves the locked
profile and proves its PIN again. Fixture-owned settings are removed afterward.
Moving verification off the UI executor should preserve its cost and result,
not reduce the verifier rounds. Heartbeat gaps are not rendered FPS.

1. Select the scenario matching the suspected work and capture a baseline
   **before** editing production code. Keep the printed run path. Record the
   symptom and configuration; do not replace a reported failure with an easier
   unrelated workload.
2. Inspect sample distributions and counters. Use Instruments/Time Profiler,
   Allocations, or SwiftUI Instruments on the owned simulator when attribution
   is needed. An elapsed-time regression alone does not name its cause.
   `python3 tools/performance.py report .build/performance/runs/BASELINE`
   prints compact JSON with medians, dispersion and counter ranges, omitting
   the large source/fixture manifests so agents need not load them into context.
3. Change only the measured cause. Repeat the identical scenario, simulator
   device type/runtime, toolchain and compilation settings. Keep the host quiet;
   do not benchmark while another build or many simulators compete for resources.
4. Compare the two saved runs:

   ```sh
   python3 tools/performance.py compare \
     .build/performance/runs/BASELINE/result.json \
     .build/performance/runs/CANDIDATE/result.json
   ```

5. Retain an optimization only with explained evidence and preserved behavior.
   A no-benefit result is valid. Add a focused correctness/work-count regression;
   do not weaken assertions, alter the workload, or reset the baseline to pass.
   A changed fixture requires a new baseline under that fixture.

Comparison never overwrites a baseline. Exit codes are **0 within budget**,
**1 regression/invalid evidence**, **2 inconclusive noisy comparison**.
The default timing allowance is the largest of 15% of the baseline median,
three median absolute deviations, and 1 ms. `--tolerance-percent` changes only
the declared percentage; set it for the experiment, never to hide a failure.
Noise above the larger of 20% of baseline or 1 ms is inconclusive.
Do not repeatedly rerun until a favorable sample passes. Diagnose contention or
capture a deliberately new controlled experiment, retaining the failed/noisy one.

`playback-journal-disabled` and `playback-journal-enabled` are an explicit
off/on control for the new persistent journal, not a historical baseline.
Each sample handles 10,000 synthetic lifecycle notifications. The enabled case
awaits encoding and persistence and verifies retained plus discarded counts;
`enqueueMicroseconds` separately measures synchronous notification handling.
Both retain the same notification/UUID workload. Wall/CPU include completion;
neither is a rendered-frame or physical-device energy measurement.

`within-budget` is **not** proof of improvement. Read the deltas and their
dispersion. Work counts are reported separately and bounded by XCTest
assertions, not statistical timing allowances. Resident snapshots/deltas are
informational: allocator caches and framework lifetime make them unsuitable
for a blanket byte threshold. Lifecycle scenarios additionally assert weak
references actually release.

`native-poster-indicators` exercises the actual native-poster coordinator's
foreground path: 72 completed overlays across 24 posters, three visible episode
badges, and changing playback progress. Each sample uses cold geometry. The
distinct-bitmap counter exposes redundant synchronous rendering separately from
wall/CPU time; `native-poster-composition` covers source artwork, not this path.

`portrait-reflection-cold` prepares twelve Detailed portrait reflections through
the native coordinator using the production 960-pixel poster cap and fresh
geometry in every sample. It measures completed
bitmap preparation and the longest synchronous preparation, not frame pacing.
`portrait-reflection-warm` recreates 288 coordinators and requires all requests to
reuse the same twelve finished bitmaps. These isolate first-seen artwork cost
from reuse; neither establishes physical Apple TV smoothness or cache behavior
under unrelated memory pressure.

`poster-preview-admission` exercises the shared preview gate used by media rows
and mobile Home. It visits overlapping 16-item look-ahead windows three times per
position, traversing 181 posters forward and backward for each of Jellyfin,
Emby, Plex, and TMDB URL shapes. Every sample verifies the complete nearest-first
queue of 1,448 previews; counters distinguish 70,584 candidate visits from actual
URL comparisons. This isolates synchronous admission/URL work, without network
requests, image decoding, UI layout, or a claim about the duration of a reported
device hang.

## Native Home navigation attribution

For focus/scroll lag rather than isolated work counts, run the production Home
fixture with real `XCUIRemote` directional input:

```sh
python3 tools/performance.py profile --platform tvOS --sim-id "$PLOZZ_SIM_ID"
python3 tools/performance.py profile --platform tvOS --sim-id "$PLOZZ_SIM_ID" --workload detail-return
python3 tools/performance.py report .build/performance/runs/RUN_ID
```

This route requires an **owned, initially shut-down tvOS simulator**. It builds
the optimized fixture and UI driver, verifies the installed `FocusHost` process,
starts recording, and only then sends navigation input. The driver attaches to
that same app without relaunching it. Three traversals must return focus to the
hero. The runner stops its recorder, terminates its fixture, restores its
temporary scheme and shuts down the simulator even on failure.

The `detail-return` workload uses native top tabs and eight populated library
rows. It opens a poster in a deeper row and returns with three rapid Left presses
for three visits, preserving the profiled app process. The native focus journal
is retained with the sample; return-stage `at` values use the main-thread
monotonic clock rather than the journal writer's asynchronous timestamps.
Animation callbacks do not establish exact presented-frame timing.

`Process Sample` is the default backend and uses macOS's installed `sample`
tool. The report separates main-thread frames, app-owned main-thread frames and
app-owned background frames. Counts are **inclusive stack observations**, which
include blocked/waiting threads; do not add parent and child counts together or
convert them into CPU milliseconds, hitch duration, FPS or input latency.
The capture includes setup/settling and the driver's eight-second idle window,
not only the directional-input intervals. Raw stacks and the XCTest result are
retained for attribution.

`--template 'Time Profiler'` and `--template SwiftUI` explicitly select installed
Instruments templates. They require a tracing-started notification and exportable
samples for the verified PID. On hosts where Instruments cannot attach to the
simulator, the run fails **before input**, retaining the logs; there is no silent
backend fallback. Choose Process Sample for a separate experiment instead.

The fixture uses local artwork and one synthetic provider, 75 items per row,
and a run-specific item namespace so the textless-artwork answer index cannot
skip all writes because of a previous run. It does not delete caches. This makes
the answer identities cold, **not every metadata/image cache**; artwork itself
is prewarmed. It does not reproduce the complete account/session, sidebar,
Live TV guide or concurrent cloud-sync workload. Extend the relevant fixture
dimension when investigating those paths; the separate matrix is not proof of
their navigation behavior.

These runs use `evidenceKind: simulator-navigation-profile`, not statistical
benchmark evidence. `compare` intentionally rejects them. Use stacks to identify
an owner, add a deterministic regression for that mechanism, and retain a fresh
candidate capture. A vanished stack on a warm cache alone is not an optimization.
For example, the textless-artwork index's atomic writes were observed on the
main thread; its regression blocks the disk writer while requiring the main
actor to accept and coalesce newer answers. That tests executor separation
without pretending a sample count measures frame smoothness.

## Workloads and configuration interactions

| Suite | Production path and limits |
| --- | --- |
| `core` | Unchanged sync persistence (10,000 records, 1,000 checks), warm incremental Share scanning (1,000 films), fresh SQLite IPTV import (10,000 generated records). The sync/Share fixtures also verify an actual edit is not suppressed. |
| `ui` | Shared `MediaRowView`/poster presentation with generated local artwork, settled idle, programmatic scrolling, repeated host/view teardown. Shared card scenarios run on tvOS, iPhone and iPad simulators and are **not the entire Home screen**. The tvOS-only `home-artwork-layout` scenarios exercise production Showcase artwork invalidation and duplicate reports across eight populated rows, with direct nested-host fitting duration/counts, sizing/placement counters and layout/focus controls. The `-cold` variant mounts a fresh view graph with warm artwork; it does not simulate every cold cache or a complete navigation session. |
| `matrix` | Full 16-case factorial: 1/4 resolved fixture-provider accounts × Plozz automatic channels off/on × cached Live TV data off/on × local cloud-sync processing off/on. Uses account resolution, `LiveTVLibraryRuntime`, source/portable sync bridges, and ledger persistence, with isolated defaults, in-memory credentials, local catalogues and provider doubles. |
| `diagnostics` | 10,000 operation attempts with recording disabled/enabled, plus 100 bounded snapshot encodes. Measures recorder and event-time serialization overhead without starting Sentry or creating uploads. |
| `network` | `catalog-cached-refresh`: 1,000-channel loopback M3U import with a 100-ms header delay, then an expired-catalog refresh held while three cached reads complete. Verifies one refresh and actual replacement visibility. Cold/cached foreground timings are separate counters; whole-cycle wall time includes setup, controlled waiting and settling. No external playlist or stream links are fetched. |

`live-tv-schedule-sync` uses the real automatic planner for 4,000 films and five
distinct channels, then changes only genre/studio spelling. It measures retained
snapshot records while checking that published broadcasts are preserved.
`live-tv-schedule-capture` captures 12,000 items, advances the published horizon
five times, then changes the inputs; full encoding count must fall without
suppressing that final change. Neither scenario measures CloudKit delivery.
`guide-large-batches` downloads a generated 23.8 MB, 48,000-programme XMLTV file
for two 2,000-channel batches. Request/byte reductions must preserve all 32,000
requested rows; parse count is separate. It uses loopback, not a real provider.

`collection-discovery` runs the production Jellyfin collection provider over
356 native collections, with 5-ms synthetic request latency. The fixture retains
10,000 library slots and sparse membership data to expose accidental fanout, but
each sample must return all 356 server-listed groups in one request, with zero
library-ID or member requests. A subsequent cached grid page must do no network work.
`firstItemsNanoseconds` measures the first nonempty progress update (or the final
return without progressive support); request counts distinguish library ID
paging from member probes. This native-listing contract intentionally replaces
the older 24-result client-filtered scenario; results from those different
workloads are not compatible automated performance baselines. Correctness
coverage separately requires a cold 356-item list to finish within one second
with 200-ms synthetic request latency. Neither fixture establishes real-server
or physical-device latency.

For network-file startup and seek overhead, select `network-file-read-ahead`.
It exercises the production transport reader with four scattered metadata probes
followed by 64 MiB of verified sequential consumption. The synthetic source
advertises 32 MiB requests and adds 5 ms latency per read. Counters distinguish
consumed bytes, fetched bytes, request count and largest request; read-ahead may
reduce round trips while increasing unused sequential bytes. This measures reader
work and synthetic latency, not real WebDAV throughput, TLS/HTTP allocation cost,
video decode, or device smoothness. Resident snapshots are not peak memory.
Pair it with the hosted WebDAV playback checks in
[Playback engines](playback-engines.md#media-share-disc-images) when changing
actual network playback.

`disc-probe-cache` performs 21 scattered, overlapping 2 KiB metadata reads
through the same production reader and 5 ms synthetic-latency source. It
models alternating disc-directory regions, separately from the sequential
workload, and records actual transport requests/bytes as well as completed
probes. Reuse must not change returned bytes, clone isolation or cache bounds.

`http-response-assembly` separately measures the production HTTP delegate's
body accumulation: 32 MiB delivered in 2,048 callbacks of 16 KiB, followed by
byte-for-byte validation. It has no network delay and starts no URL task;
this isolates callback CPU/allocation cost from server throughput. Task state
must keep the body uniquely owned while appending, rather than repeatedly
copying the growing `Data` out of dictionary-held value state. Response-size
limits, ordered delivery and cancellation have separate correctness controls.

`webdav-playback-window` verifies a 32 MiB production WebDAV read with the
same fixture accepting either one full range or two 16 MiB ranges. Synthetic
delivery delay is 400 ms for the full range and 200 ms per half, modeling
per-connection throughput. Counters distinguish consumed bytes from HTTP
request count. This isolates overlap and assembly cost; it does not promise
parallel requests will increase throughput on a shared-bandwidth server.
The retained single-request path separately checks identity drift, EOF and
cancellation.

`webdav-paced-playback` consumes and verifies a complete 128 MiB file through
the production WebDAV byte source and transport reader. Its synthetic HTTP
responses accept both single windows and the former two-range implementation,
with 100 ms per-request latency plus a size-dependent transfer delay. A paced
32 MiB/s consumer separates download waits from downstream work. Counters
include time inside reader calls, requests, requested range bytes and consumed bytes;
the entire file must be delivered exactly once. Use this workload to measure
download/consumption overlap, not just the latency of an isolated range.

This is a deterministic byte-pipeline model, not decoded 4K playback, a public
server bandwidth measurement or a frame-stall count. The single-window scenario
can get slower when removing parallel connections even as paced consumption
gets faster with fewer requests. Read-ahead may fetch one unused future window
on a seek or stop; this EOF-bounded workload alone does not measure that waste.
Cancellation, failed-prefetch, sparse-probe and clone tests cover those paths,
and hosted loopback playback separately checks engine integration. Keep public
service credentials out of local benchmarks and do not use repeated remote
playback loops after receiving throttling responses.

`webdav-cached-seeks` uses the same paced file and HTTP delays, adding 31
back-and-forth 2 KiB probes two MiB behind the consumer. These targets remain
inside the current read-ahead window. It measures whether cached seeks cancel
and recreate an already useful next-window request. Every main byte and probe
must still be delivered; explicit cancellation and seeks outside both windows
retain separate correctness coverage. Requested range bytes include cancelled
attempts, so they are **not** bytes transferred over the network. This is a
controlled seek pattern, not a trace or frequency claim about every demuxer.

For decoded local integration, `WebDAVDiscPlaybackHostedTests` accepts
`PLOZZ_WEBDAV_LOCAL_PLAYBACK_FIXTURE`, the filename of a synthetic `.mkv`
already staged in the owned test host's Caches directory. The loopback-only
test adds 80 ms response latency and 1 ms per 64 KiB, seeks to 35/5/20 seconds,
then requires over 58 seconds of advancement during a 60-second observation.
Use a fixture longer than 85 seconds; the measured workload uses a generated
90-second 3840x2160 10-bit HEVC / six-channel AC-3 file at approximately
96 Mbps. It is not the remote Blu-ray ISO or proof of public-service performance.
The test skips unless explicitly configured and never interprets this filename
as a network address. Remove staged copies from the owned simulators afterward.

For Home metadata work, select `home-metadata-publication`,
`home-observed-metadata-publication`, `home-row-metadata-updates`, and
`home-row-metadata-reuse` on either platform.
These hosted scenarios measure real silent Home reloads and production-row
updates, distinguishing independently decoded equal snapshots from reuse of
existing values. The observed-publication variant changes metadata and waits
for the observing production row to receive every update. A background sampler
reports main-actor scheduling delays, not presented-frame hitches or FPS.
Pair `home-observed-metadata-publication` with
`home-observed-metadata-diagnostics` in the same run to measure the same Home
workload with the in-memory diagnostic recorder disabled/enabled. The enabled
variant does not start Sentry or upload anything.
Credits, sort metadata, membership/order, and provider parity
remain correctness controls; unchanged identity must not hide changed metadata.

For card-activation and menu stalls, `mobile-home-card-routing` updates 24 real
mobile Home cards against a four-source identity index and counts source
resolutions without activating a card. Detail routing belongs in the presented
destination, and direct-play routing in the action, so browsing should resolve
zero sources. `source-menu-version-presentation` builds 1,024 production version
rows per sample on either platform and compares every title and supplemental
fact with the original output.

The tvOS-only `native-poster-composition` converts twelve generated 2160x3240
extended-range images into native poster surfaces. Each sample changes the
presentation dimming to require twelve cold compositions despite the shared
bitmap cache; all twelve real output callbacks must complete. It records total
and main-thread compositions and synchronous request latency separately from
whole-workload wall time and CPU. Moving work off-main is not eliminating its
CPU or temporary memory cost. Generated wide-gamut images exaggerate retained
memory, and the bounded parallel workers can increase peak working memory.
Warm first-paint reuse, pixel equivalence, cancellation and focus ownership are
separate hosted correctness controls, not substitutes for completed cold work.

The matrix uses 500 library items per provider and 1,000 cached IPTV channels
when enabled. Startup/discovery happens before measurement; each warm sample
performs ten unchanged refresh/capture cycles. It distinguishes feature
interaction and provider-count scaling without introducing real network noise.
Its providers are doubles labeled Plex/Jellyfin, not real Plex, Jellyfin, Emby,
SMB and IPTV transports running together. A cheap settled refresh does not
exonerate initial discovery, playlist replacement, guide fan-out or slow servers.
Catalogue revision callbacks and ledger capture acknowledgements mirror the
production sync composition, so warm samples exercise its unchanged-state path.
Assertions require the initial export to run, subsequent unchanged exports to
be reused, and an actual source edit to invalidate that reuse after measurement.
It does **not** log into iCloud, run CKSyncEngine delivery, simulate CloudKit
push timing, fetch a provider's server, or mount the Live TV guide UI.
“Live TV on” here means cached source/channel data participates, not a claim
that every Live TV feature has been exercised. Use paired cases to attribute
cost, not just the all-enabled versus all-disabled extremes.

There is intentionally no combinatorial cross-product of every app setting.
Add the specific suspected dimension (profile count, library size, pending sync
changes, artwork state, active/retained guide, playback, slow/offline provider)
and its positive controls when evidence calls for it. Keep cold startup, warm
steady state, and changed-data workloads separate. Preserve equal first-class
Plex/Jellyfin coverage when an optimization reaches provider behavior.

## Evidence contract

Runs live in ignored `.build/performance/runs/<id>/`. `result.json` contains:

- exact Git HEAD and hashes of current source/test/config/tool inputs, including
  staged, unstaged and untracked files; concurrent source changes fail the run;
- platform, simulator type/runtime build, SDK/Xcode, host OS/hardware,
  optimization flags, runner fingerprint, all test-fixture fingerprints,
  timestamps and host-load samples;
- each scenario's **one discarded warmup and five measured samples**, wall/CPU
  milliseconds, process resident bytes/delta, and actual workload counters.

Raw command logs, build/test `.xcresult` bundles, summaries, generated schemes
and exported JSON attachments remain beside the result. A clean driver exit,
exact expected test count, zero skips/failures, and complete unique finite
measurement attachments are all required. An interrupted or partial matrix is
failed evidence, not a smaller passing suite. Invalid/missing results fail closed.

Comparison requires matching scenarios, fixture fingerprints and environment;
source code may differ because that is the experiment. Keep baselines tied to
the corresponding machine/runtime. Hosted CI machines are useful for
deterministic counters and correctness, but their absolute timings should not
be compared against a developer Mac. No full suite runs or schedules are
automatically enabled by installing this tooling.

Measurements cover the test process, including any framework work it triggers.
`persistenceCalls` counts entry into the ledger's guarded persistence closure,
not total filesystem operations; `inventoryUpdates` counts SQLite row updates,
not physical writes. An unchanged Share scan still stamps retained inventory
with its new scan identifier so final pruning does not delete valid entries.
Those stamps are neither fresh file discovery nor one network request per item.
The Share fixture uses an immediate in-memory directory lister; `catalog-import`
uses preconstructed IPTV records and does not include M3U download or parsing.
Do not turn these counters into a claim about total device I/O.
They do not measure total device CPU, allocation count, GPU time, energy use,
presented-frame hitches or memory-pressure limits. Do not describe a sleeping
idle window's wall time as work; its comparison gates CPU only.

## Adding a scenario

Reuse existing production fixtures and helpers first. Add an opt-in XCTest
method that calls `PerformanceProbe.requireEnabled()` **before setup**, then
`PerformanceProbe.measure(self, scenario: ...)` around the bounded workload.
Supply observed counters and meaningful positive controls; never constant
“success” counters as a substitute for checking outcomes. Ordinary test runs
skip these probes. The probe also refuses physical execution.

Package suites depend on the test-only `TestSupportPerformance` target; hosted
suites compile that same source directly, preserving their single umbrella
package-product linkage. Register the selector, fixture file, description and
required counter keys in `tools/performance.py`. Keep identifiers and units
stable; bump the report schema if their meaning changes. Extend
`tools/tests/test_performance.py` for evidence or comparison changes.

## Hardware checkpoint

Simulator evidence can establish reduced work and guard algorithms, not certify
Apple TV smoothness. Decoder/HDR behavior, GPU limits, actual thermal/memory
pressure and hardware frame pacing require a separately agreed physical check.
Batch that check after a meaningful set of improvements; use scripted input and
bounded traces where supported rather than asking a person to judge every edit.
Local performance work does not authorize distribution or new telemetry uploads.
