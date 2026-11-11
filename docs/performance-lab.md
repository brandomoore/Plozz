# Simulator performance lab

Use this for the agent-driven optimization loop without installing on an Apple
TV, iPhone, or iPad. It complements [physical profiling](performance-debugging.md),
not a replacement for device-specific evidence. No cloud account, real media
server, credential, or external model service is required.
The separately authorized `home-jellyfin-live` investigation below is the
exception; no suite, including `all`, selects it automatically.

## Agent entry point

From the active checkout, inspect the machine-readable inventory:

```sh
python3 tools/performance.py list
```

Use a simulator you own. Select an explicit platform and UUID; an iPad is an
`iOS` simulator. The runner verifies platform, runtime build, and device type
before booting, never selects a different simulator or discovers physical devices.
The runner inherits `DEVELOPER_DIR`. If the selected toolchain cannot launch
hosted tests, select a compatible installed Xcode for the lane rather than
changing the global selection or resetting shared developer services. Keep the
same toolchain for both sides of a comparison.

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

### Authorized real Jellyfin Home measurement

Select `--scenario home-jellyfin-live` only with permission to query a dedicated
non-admin internal account. Set `PLOZZ_JELLYFIN_HOME_BROKER` to a short-lived
`http://127.0.0.1:<port>/<unguessable-path>` endpoint owned by the test lane.
The trusted broker verifies that account's identity and non-admin policy,
authenticates using credentials read into memory, and returns JSON fields
`baseURL`, `serverID`, `userID`, `username`, `deviceID`, and `token`.
Never put credentials in the URL, arguments, scheme, repository, or reports.
Stop the broker and log out its owned server session in `finally`.

The test uses the production layout preparation and Home aggregator with real
Jellyfin transport. Each sample starts fresh provider/layout state, concurrently
discovers navigation libraries, loads Home, then refreshes Home with the same
provider. It reports requests, duplicates, decoded response bytes, and time to
first nonempty content row and all requested data. It does not render Home,
download artwork, time login, restart the server, or measure scroll smoothness.
“Cold” means fresh client state, not cold server caches. Only numerical summaries
are attached; authenticated payloads and media identities stay in memory.

Use the same server, viewer, dataset, runtime, toolchain, and workload for both
sides. Server/network variability can outweigh small latency changes; request
counts and deterministic concurrency regressions are separate evidence. A stock
Jellyfin result does not reproduce an API-compatible bridge or a remote VPS.

For actual tvOS Home rendering and native remote navigation, use the same
authorized broker with `profile --workload jellyfin-home --platform tvOS
--sim-id <owned UUID>`. The fixture waits for the profiler and UI driver before
starting Home; login is setup, not part of the load timing. It mounts production
`HomeView`, its normal progressive load, and real server artwork, with concurrent
navigation-library discovery. External metadata, trailers, and discovery are
disabled. It does not mount the complete account/profile/sidebar app shell.

The driver verifies a focusable hero, finds a real horizontally navigable row,
performs three bounded native navigation cycles, and returns to the hero.
Saved numeric counters include metadata requests,
row/item counts, mounted artwork, first-data/all-data timing, and display-link
callback gaps during loading and navigation. Data timing is not first-pixel timing;
callback gaps are simulator display-link delivery intervals, not proof of
main-thread stalls, presented FPS, or physical-device hitch counts.
Metadata request counts exclude artwork downloads.
Artwork bytes use the normal bounded cache; compare repeated, warmed-byte-cache
runs and retain the recorded starting disk-cache size rather than purging caches.
Raw traces and XCTest evidence can contain private media: keep them local and
publish only sanitized aggregates.

## Baseline → attribution → candidate → regression

### Custom Home rows with multiple sources

Select `home-single-collection-row`, `home-multi-source-row`,
`home-overlapping-source-browse`, and `home-multi-source-presentation` on either
platform. The first preserves the original one-collection workload. The preview
scenario uses 2, 8, and 32 sources, each advertising 100,000 items with 1 ms
synthetic request latency. The overlap scenario drains eight 200-item sources
into 200 titles and verifies all eight playback references on every title.
The presentation scenario mounts the production row with 20 merged titles and
640 metadata credits, then completes 24 hosting-graph updates. Follow-up
assertions verify that actual metadata changes reach the cards.

Measured with Xcode 27.2, optimized Debug, one warmup and five retained samples:

| Workload | tvOS 27.0 median wall / CPU | iPhone simulator, iOS 26.2 median wall / CPU | Completed work |
| --- | --- | --- | --- |
| One collection | 1.629 / 1.857 ms | 2.107 / 1.529 ms | 20 cards, 11 requests |
| 2/8/32-source previews combined | 32.752 / 3.627 ms | 31.157 / 2.789 ms | 63 cards, 78 fetched records, 42 requests, maximum concurrency 3 |
| Eight overlapping sources, complete browse | 307.756 / 308.689 ms | 468.378 / 466.146 ms | 1,600 records, 200 titles, 104 requests |
| Mounted merged-row updates | 3.591 / 3.945 ms | 15.666 / 32.392 ms | All 24 updates, 20 cards; unchanged TV card inputs reused |

The original tvOS single-collection baseline was 1.014 ms wall / 1.214 ms CPU
with the same 20 cards and 11 requests. The extra cursor/dispatch machinery
therefore has a small measurable cost, not a single-source speedup. An early
multi-source implementation took about 24.5 seconds and 629 requests for the
overlap workload; batched merging and adaptive page sizes removed repeated
accumulated-record work. The final overlap median resident-memory increase was
about 6.1 MiB on TV and 5.8 MiB on iOS; these are per-sample RSS deltas, not
peak memory or leak measurements.

The pager limits source requests to three concurrently, stages cursor updates
until cancellation checks pass, and bounds sparse scans per advance. A sparse
page may intentionally contain fewer cards while remaining pageable. Tests
cover scan-boundary retention, cancellation, concurrent advances, partial
failure/retry, uneven pages, shared preview requests, viewer/library scope,
legacy persistence, and native-provider routing contracts.

These are synthetic provider-contract and mounted-row measurements, not real
server latency, artwork downloads, scroll FPS, or physical-device results.
The UI timing excludes initial mounting and the metadata-change assertions.
Local evidence is retained under `.build/performance/runs/`: baseline
`b5dd691affbf411bb78377e798705c7e`, TV
`dd6442d8f49b44a9a9ec225c9594316e`, and iOS
`93d79c88fdaa4f228d436e5a72d3cc9b`. Compare the unchanged baseline workload
directly: additional fixture coverage changes the whole-suite fingerprint,
and host load varied between runs.

### Related loading while scrolling

`related-cached-scroll` and `related-cold-scroll` mount the production Related row
in a detail-like vertical scroll fixture on iOS/iPadOS and tvOS. Each sample
resolves 24 public recommendations against two synthetic Plex/Silo accounts,
with twelve owned titles in the identity index. Search uses the production
cross-account fan-out with 150-500 ms synthetic responses; indexed native fetches
take 40 ms. Cold recommendations add 350 ms. Local generated artwork removes
internet-image variance. Every sample must produce the exact twelve native
identities, curated titles and posters, and complete 100 verified scroll positions.
One warmup and five retained samples use optimized Debug builds.

These are controlled latency experiments, not timings against Plex/Silo servers.
The fixture uses the real row, not the complete detail page or a native gesture/
remote driver. First/full-row counters measure the SwiftUI view observing the
published entries, not composited pixels or completed artwork. The 16-ms scroll
loop's maximum main-actor wake-up gap is not presented FPS or a device hitch count.
The fixture reserves a row footprint, so it does not test detail-page insertion
geometry.

The index-backed lookup and early-stop change produced these median complete-row
times with identical workloads and Xcode 27.2 (iOS/iPadOS 26.2, tvOS 27.0):

| Simulator | Cached before / after | Cold before / after |
| --- | ---: | ---: |
| iPad Pro 13-inch M5 | 1,324 / 95 ms | 1,684 / 456 ms |
| iPhone 17 Pro | 1,324 / 95 ms | 1,673 / 456 ms |
| Apple TV 4K | 2,336 / 1,490 ms | 2,790 / 1,529 ms |

All samples retained twelve results. Library work fell from 48 searches to
twelve native item fetches, with no search requests. Mobile publication dropped
from three batches to one; TV cached median dropped from three to two and cold
from three to one. Final scroll-window process CPU medians were 152 / 149 ms
(iPad cached), 119 / 104 ms (iPhone cached), and 179 / 202 ms (TV cached).
Cold iPad scroll CPU rose from 141 to 161 ms, while cold TV fell from 255 to
188 ms. This is not a uniform CPU improvement or proof of zero scrolling overhead.

The initial candidate's generic comparison was within budget on iPhone and TV;
iPad cached total CPU was inconclusive due to variability, including a repeat.
Additional correctness tests and a cold-index lookahead regression were then
added. The final comparison command rejected the changed whole-Tests fingerprint;
no guard was bypassed and no final automated budget pass is claimed. The table
above summarizes the final repeated workload manually: its exact performance
test file, environment and scenarios were verified unchanged on all three
simulators. Initial TV cached full-row median was 768 ms versus the final
1,490 ms, illustrating the simulator's rendering variability.

TV retained roughly 710-ms maximum wake-up gaps on both sides. A separate bounded
main-thread sample showed substantial RenderBox `SurfacePool::wait_image_queue`
sleeping; it does not attribute those waits to the loader. These simulator results
therefore do not prove smooth physical-TV scrolling or universally immediate
appearance. Slow/cold recommendation services and cold/stale library indexes can
still require network work; the fallback remains progressive.

Baseline/candidate evidence remains under `.build/performance/runs/`:
`3e6f4ca18f98411cbe9ae11ecd61581f` / `f277e0aa501948c1927b24f73d72f59c`
(iPad), `5fb2076114604749bfe882c744a69f7c` /
`c4837e7d8b4c4125ae8d437ad4aee72b` (iPhone), and
`a12155a5de114a589e39dd14020c1ef3` / `be42ce31c18347eb9db52d685e19fe56`
(TV). Initial compatible candidates were `9e856e5b01394ce08053881e64b85438`,
`b9a4f350fa804859a59039e8b7ec0025`, and `1a4a5d0b743c4a7495f654774a9b50cc`,
respectively.

#### Account-batched follow-up

The current fixture adds production runtime batching, overlapping native IDs,
`related-mixed-servers-scroll` (two Plex accounts, Jellyfin, Emby, Silo and a
share), and `related-detail-open-scroll` (the production detail model, a 250-ms
primary request, and 350-ms cold recommendations). The cached/cold pair now uses
Plex/Jellyfin batch-capable fixtures. Silo/share fixtures deliberately do not
advertise batching. These revised workloads have their own frozen baselines;
do not compare their CPU costs directly with the earlier fixture.

The complete-row medians below compare the preceding individual-fetch loader
with account batching and earlier public recommendation preparation:

| Simulator | Cached before / after | Cold before / after | Seeded detail open before / after |
| --- | ---: | ---: | ---: |
| iPad | 101 / 56 ms | 454 / 415 ms | 709 / 418 ms |
| iPhone | 95 / 55 ms | 458 / 410 ms | 706 / 411 ms |
| Apple TV | 1,487 / 1,474 ms | 1,538 / 1,511 ms | 1,904 / 1,507 ms |

Two-account library requests fell from twelve individual reads to two batches;
peak native concurrency fell from six to two. The six-account mixed case fell
from twelve to eight requests (four batches plus four individual reads), retained
the six-request concurrency bound, and preserved all twelve account-qualified
native cards. Its complete-row latency stayed essentially unchanged: iPad
100 / 102 ms, iPhone 96 / 101 ms, TV 1,498 / 1,470 ms. Non-batch servers still
need bounded individual requests; fewer total requests does not guarantee a
faster final card.

The final generic comparison was within budget on TV, inconclusive on iPad,
and flagged iPhone detail-open CPU (128 / 173 ms). A retained repeat of the
unchanged iPhone candidate did not reproduce that regression (90 ms), but its
cached CPU comparison remained inconclusive. Shared-host load and scroll-window
CPU varied substantially: final detail-open scroll CPU was iPad 144 / 187 ms,
iPhone 116 / 159 ms (80 ms on repeat), and TV 263 / 222 ms. Consequently these
results establish request reduction and controlled row-latency improvement,
not zero scrolling overhead. TV's roughly 720-ms main-actor wake-up gaps remain.
No physical-device smoothness or live-server latency claim is made.

Separately, a bounded read-only check on real Plex, Jellyfin and Emby servers
compared each batch response with individual reads of three movies and three
series per provider. All eighteen cards retained the same native identity,
title, artwork, provider IDs and watch state. This verifies endpoint semantics,
not live app rendering or production latency; no watch-history changes were made.

All comparisons accepted identical environment, scenario and whole-test
fingerprints; additional correctness tests and a source-switch cancellation
ownership guard were added afterward. Baseline /
final candidate run IDs are `42f5249893bd44fe87b730309d848452` /
`ef1238885910427eb0b15bb3273cd416` (iPad),
`efd5989f1b2447068161417060bfcede` /
`f661eb5c88ea42499ae92514550e4110` (iPhone), and
`c6c383ff3dba4944b66e2c676aa19341` /
`15f61ec030f74145aa37ca43319164f7` (TV). The iPhone confirmation is
`626580e31db64328ba12f35c594410c0`. Initial candidates and all comparison verdicts
are retained under `.build/performance/`; no failed/inconclusive comparison was
discarded or overridden.

### Disc graphics

`disc-java-flush` exercises the production native Java graphics bridge with 200
960x540 updates per sample, including 20 pixel-verified color changes and 180
unchanged redraws. It measures synchronous copying/composition work, not Java
execution, playback, presentation FPS or input latency. Separate graphics tests
cover transparent clears, plane order, plane replacement and late callbacks after
Stop. The same optimized iPad Simulator workload measured median producer CPU
time of 132.1 ms before unchanged-frame reuse and 23.0 ms afterward; this is not
a physical-device or all-disc performance claim.

### Song recognition

`song-recognition-disabled`, `song-recognition-tap-only`, and
`song-recognition-enabled` play the same
35-second synthetic 1080p30 H.264/AAC file through the production Plozzigen
adapter on either platform. The disabled case installs no tap; tap-only drains
the production tap without matching; enabled uses the production controller,
source-clock pacer, presentation expiry, and ShazamKit streaming matcher against
a real local custom catalog. Catalog preparation is identical for all cases.
Playback reaches eight seconds before sampling. Each three-second
window must advance playback by at least 2.3 seconds; enabled windows must consume
more than 120,000 fresh audio frames, with no source gap above 250 ms and no
feed lead above 51 ms (the production tolerance is 50 ms). Tap-only has the same
continuity requirement but is deliberately unpaced. Enabled recognition must
pass production's two-sighting confirmation before source time 20 seconds,
not merely produce a raw match. There is one discarded warmup and five retained
windows; steady cases must keep exactly one tap installation, or zero when off.
`song-recognition-tap-paced` drains through the production source-clock pacer
without ShazamKit matching, with the same frame, continuity and lead requirements
as enabled recognition. Prefer this over eager tap-only for matched-timing CPU
attribution: eager draining consumes decoded-ahead audio, especially after seeks.

`song-recognition-lifecycle` uses one discarded and five retained 25-second
cycles. Each seeks to the start, plays for 12 seconds, pauses for one second,
then resumes with a fresh recognizer for 12 seconds. It requires fresh confirmed
reports every cycle, more than 600,000 audio frames and 22 seconds of video
progress, no feed work during pause, and zero weakly tracked `SHSession`
instances after each stop. The roughly 150-second exercise includes decoder
lead after each tap installation; it is not a full-movie soak or an allocation
trace. `confirmedSongs` counts accepted/renewed reports, not distinct titles.

All cases record display-link callback count/gaps and engine drop telemetry.
`hasDropTelemetry` distinguishes an unavailable counter from a measured zero.
Display-link delivery is not presented video FPS; these cases mount video,
not the complete player controls or song artwork.

```sh
python3 tools/performance.py run --platform iOS --sim-id "$PLOZZ_IOS_SIM_ID" \
  --scenario song-recognition-disabled song-recognition-tap-only \
             song-recognition-enabled song-recognition-lifecycle
```

The fixture uses the existing `glow-hd.mp4` video without re-encoding. Its
original synthetic audio is generated and muxed as follows:

```sh
ffmpeg -f lavfi \
  -i 'aevalsrc=0.15*sin(2*PI*(170*t+7*t*t))+0.12*sin(2*PI*(430*t+19*t*t))+0.10*sin(2*PI*(910*t+31*t*t)):s=48000:d=35' \
  -c:a aac -b:a 192k song-performance.m4a
ffmpeg -i glow-hd.mp4 -i song-performance.m4a \
  -map 0:v:0 -map 1:a:0 -c copy -shortest song-performance.mkv
```

An initial, weaker on/off experiment before/after removing the unbounded forwarding
queue and hardening recognition lifetime produced these app-process CPU medians
(milliseconds per three-second window):

| Simulator | Baseline off | Baseline on | Candidate off | Candidate on |
| --- | ---: | ---: | ---: | ---: |
| iPad Pro 13-inch M5, iOS 26.2 | 500 | 549 | 450 | 540 |
| Apple TV 4K third generation, tvOS 26.2 | 585 | 585 | 491 | 525 |

Candidate enabled median absolute deviations were 39 ms on iPad and 33 ms on TV.
Both cases continued advancing by about three seconds per window; enabled
windows processed 143,360–147,456 fresh frames and produced one to three matches.
The lower disabled medians also show substantial between-run variability:
these observations do **not** establish a CPU speedup or zero overhead.
Candidate resident snapshots were 562/631 MiB off/on on iPad and 365/362 MiB
on TV. Framework caching, allocation history and case order prevent treating
these snapshots as isolated feature memory costs or a leak verdict.

The performance test and media hashes were unchanged. The generic comparison
command refused these runs because its fixture fingerprint also includes
changed correctness/UI tests; no automated budget pass is claimed or guard
bypassed. Raw evidence remains in local performance runs
`4ba21f5cc10c4379ac03955c6a92300c` / `ffc796ba9202472f98832beda3da1a86`
(iPad baseline/candidate) and
`0ab247f7360343d9b7d624143e7f6389` / `b15df76bd03b4999a498aa339a08c406`
(TV baseline/candidate).

The subsequent three-way attribution baseline, before source pacing, measured
off/tap-only/full CPU medians of 564/560/592 ms on iPad and 548/549/597 ms on TV.
After timing and expiry changes, the stricter workload above produced:

| Simulator | Off CPU / MAD | Tap-only CPU / MAD | Full CPU / MAD |
| --- | ---: | ---: | ---: |
| iPad Pro 13-inch M5, iOS 26.2 | 479 / 74 | 584 / 8 | 428 / 109 |
| Apple TV 4K third generation, tvOS 26.2 | 540 / 11 | 624 / 50 | 552 / 61 |

Values are milliseconds per three-second window; MAD is median absolute
deviation. Full recognition being cheaper than tap-only in this sample is a
warning about order/history and variability, not evidence that matching saves
CPU. Warmup, pacing, lifecycle coverage and instrumentation changed between
these experiments, so they are not a controlled speedup comparison. They do
not identify a converter/dispatch bottleneck or justify speculative resampling,
batching or duty cycling.

Both platforms processed 143,360–144,384 frames per full-recognition window,
reported a maximum feed lead of 49 ms and no source gaps, and confirmed the
synthetic cue. Steady full-recognition display callbacks had maximum gaps of
17 ms on iPad and 18 ms on TV. Engine drop telemetry was available and reported
zero drops in all retained cases. Lifecycle windows advanced video by
23.33–23.49 seconds and consumed 914,432–929,792 frames, with zero paused feed
and zero live tracked sessions after each stop. Maximum lifecycle callback
gaps reached 64 ms on iPad and 49 ms on TV; these must not be described as
perfect frame pacing.

Resident memory still rose across the five retained lifecycle samples:
591–623 MiB on iPad and 508–534 MiB on TV. Released `SHSession` wrappers do not
prove that framework caches, engine allocations or service-process resources
are bounded. The short run does not establish a leak or a leak-free plateau,
and cross-case resident deltas are not isolated feature allocations.
Retained three-way baselines are
`0f0c0f15e6c7456bb3043cb9e30c0427` (iPad) and
`c846d4c56c9f47799caaef139c32c46a` (TV); current four-case evidence is
`d62c3086d2c44e859dd0a36b32a515e6` (iPad) and
`0e5e6103950d48ecb9ef00dfcb56d746` (TV).
Older counter schemas are incompatible with the current report validator;
historical numbers above come from their original retained samples, not a
forced comparison pass.

CPU totals cover the app process, not separate Shazam service processes.
These recognition runs exercise software video decoding and actual local fingerprint
matching, not hardware decoding, the native cached-segment audio reader,
Apple's network music catalog, real-song accuracy, device energy/thermals,
full-movie memory growth or presented-frame pacing. Separately, lifecycle
tests cover tap removal during pause, errors and cancellation, bounded retries,
discontinuities, pause-aware expiry without matcher output, source-clock pacing,
and rejection of superseded-session results. Native player
screenshots use seeded metadata and are not recognition-performance evidence.

#### Isolated ten-minute controls and complete-player cost

The explicit-only `song-recognition-soak-disabled`, `-soak-tap-only` and
`-soak-enabled` cases each require a separate runner invocation and fresh test
host. They are excluded from suite selection. Each measurement window contains
four 25-second lifecycle cycles; one warmup plus five retained windows exercise
24 seek/pause/resume cycles over roughly ten minutes. Cancellation waits for both
workers and weakly tracked sessions before checking paused work, including the
tap-only worker that has no `SHSession`. After the playback scope ends, the
`plozz-song-memory-<mode>.json` attachment records RSS immediately and 30 seconds
later, plus weak engine/session counts and active workers.

```sh
for state in disabled tap-only enabled; do
  python3 tools/performance.py run --platform iOS --sim-id "$PLOZZ_IOS_SIM_ID" \
    --scenario "song-recognition-soak-$state" || break
done
```

Six isolated controls on the same iPad/TV simulators passed. Values below are
MiB of resident memory, not physical footprint or isolated feature allocations.
The retained range shows first-to-last samples, not a min/max range.

| Simulator | Mode | Retained RSS, first to last | RSS 30 s after teardown | Local run |
| --- | --- | ---: | ---: | --- |
| TV | Off | 476.6 to 493.6 | 463.4 | `9a5e2e4ee83248a0b837b5ff56362b31` |
| TV | Tap-only | 449.8 to 475.2 | 444.9 | `c0b80fc939f6431c901fada6a3df5da3` |
| TV | Full | 475.4 to 517.6 | 484.1 | `a038012d5e3f439d85551fc761778597` |
| iPad | Off | 650.9 to 681.7 | 645.5 | `f89023aaf961483588fb6a751c22a869` |
| iPad | Tap-only | 642.8 to 666.3 | 630.0 | `9a95f1ef1a2344d4b8efd44a89378948` |
| iPad | Full | 677.9 to 718.9 | 682.5 | `bfec37e7e0614eb780b68a5f43a4335b` |

All six ended with zero tracked engines, sessions and workers. Growth also
exists with recognition disabled; its cause is not established by RSS.
Slowing growth and released wrappers do not prove a plateau or exclude retained
framework/native allocations. These repeated lifecycle controls are not
uninterrupted movie playback.

`song-card-hidden` and `song-card-visible` mount the complete production controls
over advancing native video with Info open and the song slot available.
Recognition is disabled; each three-second window submits 12 repeated seeded
reports. Visible artwork must decode from the local fixture server and pass a
pixel check before timing. These measure settled presentation, not cold artwork
loading or fingerprint matching. CPU median/MAD was 519/8 ms hidden versus
493/8 ms visible on TV (`e09d33e9c5e243d8bd0d72d3d0af247d`) and 449/48 versus
464/59 ms on iPad (`fa8455aedba64ee487e3b2d1385f069f`). Neither establishes a
steady-state card penalty or a speedup.

The later uninstrumented iPad off/paced-tap/full run
`95506d6a7b274035a651d9b3c180feba` measured 623/33, 740/66 and 727/16 ms
CPU median/MAD per three-second window. This supports retaining pacing as the
control, not claiming matching is free or cheaper than draining.

A bounded TV Time Profiler capture of run `fbb4be3a0a2f443594094cfcf59e344b`
exported 26,301 running samples from `time-profile`. The raw `time-sample`
table additionally contains 19 blocked stackshot rows; those are not CPU work.
Leaf binaries were dominated by video decoding. Within the approximately
26.65-second full-recognition test interval, 6,763 ms of sampled CPU included
3,589 ms with `AetherLibavcodec` leaves, 111 ms in stacks containing
`matchStreamingBuffer`, 73 ms containing `AudioTapPCMConverter.convert`,
and 5 ms containing `SongAudioPacer`. These inclusive sampled stack weights
are not exclusive timers or a complete recognition-cost account; async work,
framework symbols and external services limit attribution. They do not identify
a recognition bottleneck warranting batching, resampling or weaker matching.
Do not compare profiler-instrumented timing against uninstrumented budgets.

The trace retained a warning about one table without a known input source;
the running CPU table and relevant symbols were available. Correlate phase
boundaries with timestamped host logs: this Xcode export's test-detail
`startTime` corresponded to completion, not the observed start. The capture
only partially covered the first card case. Trace and parsed attribution are
retained locally under `.build/song-layout-preview/cpu-attribution-2/`.

The native cached-segment audio-tap path remains unmeasured: the simulator
reported VideoToolbox rejecting the fixture and selected software decoding.
Direct native video in the card workload does not exercise that separate tap.
No unsupported route was forced and no physical-device result is claimed.

#### Following resident growth outside recognition

The soak attachment now includes `memorySnapshots` before playback, after
warmup, after each measurement window, immediately after teardown and 30 seconds
later. Direct `TASK_VM_INFO` readings separate resident size, physical footprint,
internal/external memory, compressed memory and reusable pages.
`malloc_zone_statistics` additionally reports allocation bytes, reserved capacity
and block totals. These are process-wide diagnostics, not per-feature accounting.
The engine's existing `rssMB` log is **resident size**, not physical footprint.

Recognition-disabled controls on both platforms showed the distinction:

| Simulator | RSS | Physical footprint | Reusable pages | Allocator-reported live bytes |
| --- | ---: | ---: | ---: | ---: |
| TV | 408 to 463 | 177 to 151 | 47 to 127 | 278 to 279 |
| iPad | 530 to 548 | 301 to 295 | 95 to 120 | 154 to 154 |

Values are MiB, first to last retained measurement. RSS rose while footprint and
reported live bytes did not grow with it. Compression and reusable pages changed
substantially; RSS alone would incorrectly suggest equivalent growth in memory
charged to the process. After teardown, reported live bytes fell to 14.8 MiB
on TV and 23.4 MiB on iPad, with zero weakly tracked engines/sessions/workers.

Only after those measurements and the 30-second wait, the isolated soak invokes
`malloc_zone_pressure_relief(nil, 0)` once and records `afterHeapPressureRelief`.
This is a test-only attribution experiment, **not production cleanup or a proposed
leak fix**. Footprint changed from 79.6 to 36.0 MiB on TV and 213.8 to 172.7 MiB
on iPad while reported live allocation bytes stayed unchanged and reusable pages
increased. Resident size barely changed. This identifies reclaimable allocator
pages as a substantial part of the retained memory, rather than retained playback
objects. The API's returned byte count is preserved separately; it is not the
observed footprint delta.

Retained controls: `be70a32815974b118cb7787c984ea0be` (TV) and
`b6cf1759b8d34a8b9629d8c12b93523f` (iPad). An earlier TV run without reclamation,
`5846a0df272b49c9b2df45f08081ba4c`, also showed roughly flat reported live bytes
through playback and a sharp drop after stop. Temporary verbose zone dumps were
removed after attribution. Their block counts/layout readings were internally
inconsistent on these simulator runtimes, including unsigned underflow after
reclamation; neither aggregate block totals nor those dumps establish an object
leak. External `vmmap`/`heap` failed to read DYLD information, and an Allocations
recording failed to finalize; no allocation-stack or retaining-owner claim is
based on those failed captures.

The complete-player hidden/visible cases also weakly track `PlayerViewModel` and
`NativeVideoEngine`, then require both to release within five seconds after the
player scope and window are torn down. Both sequential cases passed on both
platforms. This covers actual controls/artwork and native-player ownership in
addition to the isolated engine workload; it is not a full-app navigation,
account/provider-cache or background-sync leak audit. No production memory
change was justified by these controls, and small residual allocations,
uninterrupted movies and physical-device behavior remain separate questions.

#### Broader simulator memory audit

`cards-lifecycle-soak` runs 180 mount/unmount cycles of the production media-row
fixture in a fresh test process: 30 discarded warmup cycles, then five windows
of 30 cycles. Every hosting controller and backing view must release. It is
explicit-only and cannot share a run with another scenario. The shorter
`cards-lifecycle` still runs 18 cycles.

`mobile-home-lifecycle` performs 120 profile switches through the mobile app
model and production tab-shell Home factory, including 20 warmup switches.
Every outgoing Home, settings, and download model must release within five
seconds. Each window awaits tracker scoping and allows one second for queued
work. The accounts are empty fixtures: this is profile-model retirement, not
populated Home/detail navigation or a live-provider workload.

The memory audit uses direct process snapshots alongside weak lifetimes, not
RSS alone. First-to-last retained windows, in MiB:

| Workload | Physical footprint | Reported live malloc bytes |
| --- | ---: | ---: |
| TV, 180 row-host cycles | 93.6 to 102.1 | 32.0 to 24.7 |
| iPhone, 180 row-host cycles | 213.4 to 214.7 | 19.0 to 19.4 |
| iPhone, 120 profile switches | 180.3 to 181.5 | 60.4 to 57.4 |
| iPhone, local preference batches | 223.2 to 223.2 | 48.3 to 49.3 |
| TV, unchanged 10,000-record ledger | 19.5 to 19.5 | 6.36 to 6.38 |

No tracked navigation/profile owners survived. Row-host footprint approached
a plateau: the final 30 cycles added about 0.03 MiB on TV and 0.05 MiB on phone.
The tightly packed local-sync workload's reported live bytes fell to 47.9 MiB
after a one-second run-loop drain, below its first retained sample. Its 144
batches applied 288 preferences without account invalidations, index resets,
or download-model replacements. These are bounded observations, not proof that
all framework caches or every allocation are leak-free.

Retained runs: `3440bb2924254b9bb0610ecc254bcc3a` (TV row soak),
`ff69767cb22c46b6a2c850675cac4f89` (phone row soak),
`b6f7c89f97e94aacb76acf46a8c06729` (profile ownership),
`8d52b70621224b04a9d7878ba93c7ce4` (local sync/drain), and
`b09efce6f91c4a7aade9e0964bf14767` (unchanged ledger).

Focused cache/lifetime regressions also exercise:

- 512 positive/negative metadata results across provider/credential namespaces,
  enforcing a shared 64-entry test budget and clearing all credential entries;
- 64 Plex-used playlist snapshots and 32 Jellyfin collection snapshots, checking
  their eight-/four-key retention boundaries and reloading the evicted neighbor;
- 64 distinct small decoded images, with no remaining flights/waiters and weak
  release of the cache and all images, plus existing cancellation/deadline cases;
- sync-status error debouncing and 128 cancellations without retaining its owner.

The initial five-module run passed those cases, but was not wholly green:
4,900 passed, ten opt-in cases skipped, and an unmodified
`MetadataTextScalingTests` font-metric assertion reported 13.5 instead of 14.
Final cache-boundary verification passed CoreModels (3,064, five opt-in skips)
and ProviderJellyfin (484, three opt-in skips) separately. A multi-bundle Xcode
package-graph assertion produced an incomplete result; it is not passing
evidence. The iPad host-launch attempt also stalled in CoreSimulator before
tests began and was cancelled; the completed mobile measurements are iPhone
simulator results.

No production memory-management change or forced reclamation was justified.
Cache entry limits do not bound the bytes in very large library snapshots, and
NSCache's configured decoded-image cost limit is not a measured hard ceiling.
Live CloudKit delivery/cancellation, large real libraries, full detail-page
navigation, long sessions, and physical-device memory pressure remain outside
this audit.

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

`mobile-profile-library-selection` mounts the production mobile Libraries page
for a new profile with twenty synthetic servers and 120 libraries. Each sample
performs four native switch changes at 400 ms intervals and twelve library
visibility changes through the production model at 30 ms intervals, requiring
the final account/library choices and discovered inventory to remain correct.
It counts provider constructions, library requests, and the maximum scheduling
gap of a 2 ms main-actor heartbeat. The separate rapid-switch regression checks
immediate persistence, retained library choices, and isolation after switching
profiles without waiting for each switch animation.

On the same iPhone 17 Pro / iOS 26.2 simulator workload, baseline run
`4f640e9e798f4016a152d0618e1223b2` and candidate
`6f2cadd6d0284bcba79c038108c1a3c8` reduced provider constructions per sample from
78 to 2, median app-process CPU from 791.870 to 442.337 ms, and the median
per-sample maximum main-actor gap from 59.967 to 33.520 ms. Five retained samples
followed one warmup. Membership edits now retain unrelated providers, mobile
switches no longer queue delayed writes, and full identity scans wait for setup
completion. Library-name discovery still refreshes the selected sources; this
is not per-account result caching. Fixed input pacing dominates wall time, and
heartbeat gaps are not tap latency or presented-frame timing. This fixture has
no real share/server traffic and does not establish smoothness on a physical
device or in the full onboarding flow.

`mobile-profile-library-shell` closes that coverage gap by mounting the real
mobile root and new-profile setup cover around the same twenty-server,
120-library selection workload. Synthetic Home requests take 150 ms; no real
network or share scanning is involved. It counts Home feed and library-name
requests separately. The isolated Libraries-page scenario above missed Home
fan-out and native tab reconstruction behind the cover, so its improvement did
not establish that the full app was responsive.

On the same iPhone 17 Pro / iOS 26.2 simulator, matched baseline
`370aaf8455f54371a589bfdaf838f75f` and candidate
`27b420be6a054a77a9f58d7b7beefea7` used one warmup and five retained samples:

| Metric | Baseline median | Candidate median |
| --- | ---: | ---: |
| App-process CPU | 3742.311 ms | 583.862 ms |
| Wall time | 4625.830 ms | 1998.593 ms |
| Home feed requests | 314 | 0 |
| Library-name requests | 251 | 78 |
| Per-sample maximum main-actor scheduling gap | 493.829 ms | 40.869 ms |

Candidate maximum scheduling gaps ranged from 37.820 to 55.877 ms. Home loading
is now explicitly suspended while setup/Settings owns the screen, replaced Home
models are invalidated immediately, and unfinished setup does not construct
hidden tabs. Merely suspending requests left a 155.086 ms median maximum gap in
an intermediate candidate; interaction stack sampling identified the covered
tab catalogue as additional work. The final comparison excludes profiling
overhead. Its roughly 1960 ms fixed input cadence dominates candidate wall time.
Heartbeat gaps still are not touch latency or presented-frame timing, and this
synthetic simulator result does not establish physical-device smoothness.

After adding setup/Settings resumption and model-retirement correctness controls,
final-source confirmation run `7b605fc421e04e189e6ab26bb5edf761` again recorded
zero Home requests and 78 library-name requests in every retained sample.
Maximum scheduling gaps ranged from 43.456 to 60.019 ms; median CPU was
614.833 ms. The added correctness tests changed the fixture fingerprint, so this
is a confirmation run, not another automated matched-baseline comparison.

`mobile-profile-picker-entrance` mounts the production sixteen-profile touch
picker in an iPad-sized window. It verifies the heading appears before avatars,
a visible stagger, and substantially settled avatars within 1.5 seconds (450 ms
for the heading, then one second for the cascade, after the starting frame). CPU measurements include
hosting, native presentation, rendered captures, and heading recognition.
This is repeated fresh-view presentation, not a cold process launch, connected
startup workload, GPU measurement, or physical-device frame-pacing verdict.

`mobile-home-loading-scroll` replaces eight production skeleton rails with
20-item media rails while UIKit animates the production Home vertical scroll
view. It requires all rows to finish, the final scroll destination to be reached,
and no page-height change. It uses synthetic items without remote artwork:
this is loading-layout and app-process CPU evidence, not provider/network,
image-decoding, full Home startup, or presented-frame/FPS evidence.
`HomeLoadingLayoutTests` separately checks empty-row removal, insertion, content
insets, library/featured placeholders, and existing heading geometry. Its row-slot
matrix compares reserved height with actual loading and populated content within
0.5 points across phone/tablet widths, card shapes/styles, captions, and large
text. Failure/retry transitions must retain that height. Separate Continue
Watching, featured, and Live TV cases cover their distinct geometry; native
animated scrolling must reach its target without offset reversal while rows
change between content and errors. This is UIKit animation, not physical
drag/deceleration evidence.

`mobile-home-multi-server-loading` mounts the production mobile Home page and
model with twenty synthetic providers, forty server rows and 800 items. Provider
responses arrive progressively while eight animated vertical scroll targets are
sent; a ninth target verifies navigation after all rows finish. Every row must
settle without error and retain all its items. The two-millisecond heartbeat
reports main-actor scheduling gaps, not touch latency or presented frames. This
includes model publication and eager page layout, but not the complete tab shell,
remote artwork, real network transport, share scanning or physical-device pacing.

For the forty-row workload, limiting mobile loading-rail shimmer to the visible
viewport retained all 800 items, 100 provider requests and nine scroll targets.
Matched iPhone 17 Pro simulator runs `bc41d4e554f34579abbf528147c073b5` and
`3ff439011813430384a2e6e494b7f11c` reduced median app-process CPU from 3856.652
to 2717.529 ms and wall time from 8042.028 to 2932.224 ms. The median of each
sample's maximum main-actor scheduling gap fell from 905.030 to 214.146 ms;
the candidate range was 202.327–219.082 ms, not hitch-free rendering.
Resident memory was essentially unchanged. A separate bounded process sample
attributed the baseline to SwiftUI graph/render work and RenderBox/Core Animation
surface commits, not expensive provider callbacks. That instrumented run is not
included in timing comparisons. Later animation/Reduce Motion correctness tests
are separate from this matched fixture pair. Physical-device behavior and real
share/background workloads remain outside this scenario.

`mobile-home-multi-server-startup-scroll` keeps the same twenty-provider,
forty-row workload loading throughout 24 animated full-page scroll targets.
Responses are staggered, artwork uses a warmed synthetic local cache, and all
800 items and 100 requests must finish before the sample succeeds. Separate
scroll-window CPU, wall time and heartbeat gaps exclude mounting and final
scroll verification. `mobile-home-multi-server-scroll` is the negative control:
it traverses the same page only after content finishes loading. Neither mounts
the complete root shell or reproduces real share scans, network image decoding,
slow-provider failures, or physical-device presented-frame timing.

Matched startup-scroll runs `4019d336b4b041708f291bb8c258f96c` and
`b6cd29350be84d0e9de813b972c764fc` retained the same completed work and 24
scroll targets during loading. Lazy horizontal placeholders and a stable
library-row rendering boundary reduced median total CPU from 6103.226 to
5220.285 ms; scroll-window CPU fell from 5317.490 to 4527.785 ms. The median of
per-sample maximum main-actor gaps fell from 267.068 to 97.887 ms, not to zero.
An intermediate plain row extraction increased CPU and was discarded; the
retained boundary compares complete row inputs rather than changing data
loading or ignoring provider results. Geometry/settings regressions are
separate correctness runs, not additional timing samples.
Final-source confirmation `bb474979c865483a8f77da9e32ee2aab` completed all three
twenty-server scenarios. Startup-scroll maximum gaps ranged from 93.202 to
192.052 ms, versus 11.573 to 15.915 ms for settled scrolling; this remains a
startup improvement, not evidence that every loading hitch has been eliminated.

Stable-row confirmation run `a26271e20b02410aad2ff407b6502c28` completed the
loading-layout, startup-scroll, and settled-scroll scenarios after removing
custom scroll-position compensation. All five loading-layout samples reported
zero page-height change. Every twenty-server sample retained forty completed
rows, 800 items, and 100 requests; startup samples issued all 24 targets during
loading. Startup maximum scheduling gaps ranged from 97.301 to 158.016 ms;
settled-scroll gaps ranged from 13.506 to 15.033 ms. Median startup CPU was
5556.280 ms. These are confirmation measurements, not proof of hitch-free
scrolling or a matched speedup: new regression fixtures changed the fingerprint
relative to pre-change run `4abfd4070ca84049bbf574b9125278f4`.
Hosted correctness run `ac1c7b8bb3ca44d6aba11c9b541dcfce` passed seventeen
selected tests, including reservation before any provider response and
content/failure geometry. Shared-core run `c8d439cf89e04c43aa90fb55846a0ff0`
passed twenty-two selected tvOS simulator tests for planning, authorization,
empty/failure presentation, ordering, and progressive publication. Neither run
skipped tests; neither represents the full suite or physical-device coverage.

`mobile-home-startup-diagnostics` repeats the startup-scroll workload with the
production, consent-gated Home observer enabled. Both it and the disabled control
now explicitly supply an active scene to their manually hosted window; the
bare hosting controller did not supply the app's active-scene environment.
Consequently, do not treat older startup-scroll measurements as a matched
baseline for these fixtures.

Run `b5c51eb7c62d43b4b59f5195e23db572` passed fifty focused correctness cases
and five measured workloads, without skips. In the same-binary Home controls,
median total CPU was 6546.955 ms disabled and 6505.209 ms enabled; scroll-window
CPU was 5643.647 and 5630.512 ms. Maximum scheduling gaps overlapped
(130.536–174.723 ms disabled, 119.730–199.264 ms enabled). Every retained sample
completed forty rows, 800 items, 100 requests and 25 scroll targets. Enabled
samples retained 83–88 observer ticks, including both scrolling and loading,
plus Home publication evidence. These controls show no increase in median CPU
for this run, not a performance improvement or proof of hitch-free hardware.

Process residency rose across repeated fixtures even with observation disabled;
the later enabled run's absolute resident size is not an isolated observer-memory
comparison. Retention and cancellation are checked separately: fixed history
capacities, network flooding, owner/consent replacement, inactive/hidden/removed
Home, invalid measurements, strict redaction and manual attachment export.
The full diagnostic snapshot workload serialized 156 records (32,097 bytes)
per snapshot, with a median 159.103 ms CPU for 100 serializations. The observer
adds no network requests or disk writes; see the
[sampling limits and interpretation](performance-debugging.md).

`mobile-home-rail-prefetch` updates the real mobile Continue Watching rail 24
times with the same 180 metadata-rich episodes across twelve synthetic account
identities. Artwork is preloaded into the test cache and online providers are
disabled. It counts series-source construction while preserving every item and
waiting for each hosting-graph update. It isolates repeated layout/prefetch-key
work, not twelve connected servers, profile-transition frame pacing or hardware
scrolling. `watchlist-artwork-rehydration` separately exercises the production
Plex/Jellyfin credential-restoration path, checking every title and cast image.

### Unchanged multi-server identity verification

A confirmed 30.093-second physical iPhone Home-scrolling trace showed about
27.307 CPU seconds on the main thread and 116.531 CPU seconds across the app.
Main-thread samples were dominated by SwiftUI/AttributeGraph updates; background
stacks included identity snapshot construction, title-component labeling and
Home reenrichment. The reproduction included a roughly 1.993-second hang.
Stable page height in the preceding diagnostic report did not prevent stutter.
These are captured costs, not proof that one subsystem explains every hitch.

`identity-unchanged-servers` restores 4,000 movie memberships across twenty
synthetic Plex/Jellyfin accounts, then verifies every account through the real
identity-index runtime. All forty library/catalog requests must finish and the
twenty-source union must remain available. It excludes rendering, network I/O,
Silo detail enrichment and filesystem scanning.

Matched iPhone 17 Pro simulator runs `2567af589b924de4910ec7f6d82336b7` and
`0ce600e0ad46494dbc927b12ea24e105` used one discarded warmup and five retained
samples. Median app-process CPU fell from 713.587 to 249.827 ms; wall time fell
from 646.702 to 191.864 ms. Publications fell from 21 to one, with all twenty
accounts and forty requests retained. The candidate still restores immediately,
verifies each server, advances freshness and persists once per wave. Identical
account rebuilds now retain the cached snapshot; revision checks suppress
duplicate/out-of-order notifications without comparing the full index on MainActor.
Real membership, metadata and account-removal changes remain progressive.

Median resident size was 362,758,144 bytes before and 334,512,128 afterward;
allocation history makes this informational, not an isolated memory saving.
The tradeoff is actor-side equality over the completed account bucket instead
of rebuilding the entire cross-server graph and invalidating its consumers.
Cancellation still preserves last-known membership and rejects superseded
publication. Additional correctness cases cover all 4,000 memberships, freshness,
metadata-only changes, empty results, account pruning and reset/live lookup.
They were added after the matched pair. This is measured redundant-work removal,
not evidence that the physical iPhone's remaining scrolling stutter is eliminated.
The old account-count publication guard also suppressed confirmed removals when
an account became empty. Revision ordering permits those updates; restore/race
fixtures use a failed library lookup to model an unavailable server rather than
a successful, authoritative empty inventory.

Confirmation run `1105779dd73d40e38742d6164bf35b60` passed 52 core cases and the
mobile startup-scroll workload; all forty rows, 800 items and 100 requests
completed. Maximum scheduling gaps remained 139.585-163.227 ms in that synthetic
Home workload, which does not include real identity scanning. Final tvOS run
`84afde8aceeb4c1d8b0b153e003b8f90` passed 78 selected identity, lifecycle and
reenrichment cases. iOS run `0323007ac3044f5b9b9dac238df722f6` passed the six
final refresh cases, including confirmed-empty inventory. None skipped tests.
No new physical-device run or installation is included in this confirmation.

`HomeSettingsReturnTests` mounts the real mobile root with twenty synthetic
servers, opens its Settings sheet for two seconds, then dismisses it without
changing preferences. Response gates distinguish a completed forty-row Home
from an unfinished Home with two loaded rows. Both cases retain the same
profile/account-scoped model and pause Home requests while Settings is visible.
The completed case must not refetch feeds; the unfinished case must retain its
cards throughout the resumed request window, then finish all forty rows and
800 items. Cloud sync is disabled and restored by this unsigned-host fixture;
an active scene otherwise invokes production CloudKit foreground work.

Baseline `3c2b4ceb5afd49a4a943d7ca0828880a` preserved completed Home but replaced
both already-loaded partial rows with placeholders. The model still held the
cards: resumption marked the rows loading, and presentation chose skeletons.
Library and collection progress also needed to retain previously published
sections until their replacement requests settled. Candidate
`3246b411e2eb4d8fba23cd14a68dc982` recorded zero placeholder regressions in both
cases and passed all eight selected mobile tests, including startup scrolling
and Settings/profile ownership. Shared tvOS run
`f2cc44425ec64d70a184a57e0765ed45` passed 69 cases, covering cold-cache freshness,
cancellation, changed visibility, live global/library/collection retention for
synthetic Jellyfin and Plex providers, and authoritative empty replacements.
No tests skipped. These are content-continuity and completed-work checks, not
physical-device frame-pacing evidence; incomplete loads still restart their
cancelled aggregation rather than checkpointing individual provider requests.

The startup-scroll fixture also has `mobile-home-one-server-startup-scroll`
and `mobile-home-three-server-startup-scroll` controls. All three use the same
page, per-server content, response delays, warm artwork and 24 input targets.
A response gate opens when the page is mounted, so fast providers are not
artificially slowed to fill the scrolling window. First-row and all-row times
are observed by the main-actor heartbeat independently of the input loop.
The one-server page fits the viewport: its scrollable distance is zero, so it
measures loading/presentation overhead, not a long one-server scrolling page.
The three- and twenty-server pages traverse 1173 and 9860 points, respectively.

Six bounded process samples in `4333b0a502754dd499a31748b431102c` were verified
against the owned simulator PID and timestamped loading-window boundaries.
Their complete capture intervals exclude fixture construction and the next
sample's setup. SwiftUI transaction updates and AttributeGraph dominate the
non-waiting main-thread stacks; provider aggregation does not. These are stack
samples, including waits, not CPU milliseconds. The earlier Instruments attempt
`af2621228c354e249d68b1802e1737b8` did not finalize and is not attribution evidence.

Mobile row slots now keep exact eager sizing but use native lazy layout for
their contents. The sizing view receives only stable presentation inputs,
not the row's media payload. The measured height is also the lazy child's
layout proposal; otherwise landscape captions can shrink inside the slot.
This avoids constructing and updating every offscreen rail as responses arrive,
without estimating page heights or adjusting scroll offsets.

Final matched control `0a2d9aa98ba64a0bbe859c96730131bb` uses the original
renderer with the final fixtures. Candidate `ccf3f8dd664f4c2fb458d7d121603822`
uses identical fixtures, scenario order and runner settings. The original
pre-change baseline `3aaeca701e804bd28c66aa9a7f46fd75` preceded the added
geometry regressions; the later control avoids comparing different fixture
fingerprints. Comparison `b6b2d487c721400e8c11f6ba5e832e89` is within budget.
Each value below is the median of five retained samples after one warmup:

| Servers | Total app CPU, ms | Maximum UI scheduling gap, ms | All rows ready, ms |
| --- | --- | --- | --- |
| 1 | 1054.562 to 1002.919 | 24.410 to 25.938 | 335.038 to 335.080 |
| 3 | 2098.941 to 2121.619 | 30.235 to 30.481 | 757.729 to 750.238 |
| 20 | 6199.501 to 4883.714 | 121.443 to 58.299 | 9967.883 to 9890.176 |

Twenty-server scroll-window CPU fell from 5313.135 to 4274.084 ms. All forty
rows, 800 items and 100 tracked provider requests still finish. The faster input
loop ends with 38 rather than forty rows ready, then awaits the remaining two;
this is not dropped content. Resident snapshots were 996.7 versus 941.6 MiB,
not allocation or leak measurements. No provider concurrency, data-request
ordering, persistence or cancellation policy changed. Artwork work can now
start later, when an offscreen rail approaches the viewport; these warm-artwork
fixtures do not quantify real network/image I/O.

The candidate's twenty-server maximum gaps ranged from 56.887 to 74.175 ms.
One one-server sample had a 279.830 ms scheduling outlier before its first
response; it remains in the evidence. A separate final-source confirmation
reported one-server maxima of 20.7–33.8 ms. Small-server median readiness and
CPU remain comparable, but these results do not prove zero hitches or identical
tail latency under every host load.

Final-source confirmation `4a3e0ab953b04c5cb26aecfbd99b8072` passed seventeen
selected hosted tests without skips: four performance scenarios plus thirteen
geometry, deferred-mounting and Settings-continuity regressions. The new
forty-row case verifies every footprint exists immediately, distant rail content
does not mount when its data arrives, and native navigation mounts that content
without changing page height. The shape/caption/large-text matrix reads current
rendered bounds on retry, not a cached geometry-change callback from the previous
error view. Settled twenty-server scrolling completed with maximum gaps of
42.6–45.6 ms; this is confirmation, not a matched settled-scroll speedup.
Deferred construction still costs work when rows approach the viewport.
No new physical-device capture or installation is included.

`mobile-video-glow` measures the light inline video preview in 2.3-second
windows against the existing 160-by-90 continuity fixture. Require the same
surface and advancing playback; it isolates preview overhead, not HD decoding.
`mobile-video-glow-hd` and `mobile-video-glow-hd-disabled` use the same
1920-by-1080, 30 fps synthetic video with and without the color glow. The enabled
case must complete new samples, capped at five per window; the disabled case
must have no sampling task. These report app-process CPU and resident memory,
not GPU/render-server cost or physical-device energy and frame pacing.

The `active-picture-1-enabled`, `active-picture-1-disabled`,
`active-picture-4-enabled`, and `active-picture-4-disabled` scenarios use the same
1080p30 `glow-hd.mp4`, stream-copied to finite loopback HLS, with one or four
visible Aether-backed native players. HLS exercises AVPlayer even on simulators
that correctly reject hardware H.264 and route ordinary files to software.
Players pause during setup and start together from zero. Each window
requires advancing playback; enabled windows require new presentation-timestamp
samples at no more than 2 Hz per player, and disabling must detach native output
taps. The four-player case checks aggregate admission stays at or below four.
These are app-process CPU/resident-memory comparisons, not GPU, physical-device
energy, HDR, or four simultaneous 4K decoder benchmarks.
The `active-picture-hls` fixtures are generated with FFmpeg `-c copy -f hls
-hls_time 2 -hls_list_size 0 -hls_playlist_type vod -hls_segment_type fmp4` from
`active-picture.mp4` and `glow-hd.mp4`; no video is re-encoded. Native SDR output
materialization is included in the comparison, not bounded by the CPU sampler's
2 Hz limit. Independent subtitle outputs are preserved when the video tap stops.
Native analysis requests 320x180 output while retaining the original display
canvas separately. This reduces the requested analysis surface, not necessarily
AVFoundation's internal decode/render allocations. In an isolated tvOS simulator
four-player pair, enabled analysis added approximately 16 MiB resident memory;
CPU medians were 935 versus 952 ms per 2.3-second window, within the measured
dispersion. These are one controlled SDR comparison, not a hardware or HDR
performance guarantee.

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

`player-card-first-visits` prioritizes the first Info, Chapters and Cast opening
in a fresh production-controls hierarchy for every sample, including the
discarded warmup. It uses twenty local chapters and cast members, with no artwork
URLs, network requests or video decoding. It checks actual native tab focus,
rejects intermediate wrong-tab focus, and requires focusable content inside the
card. The separate hosted
`testProductionCardContentAndNativeEntryOnFirstVisits` checks rendered text and
native entry into each card with both normal and reduced glass; an empty or
obscured card must not count as a faster presentation.

Each first opening records its largest 2 ms main-actor heartbeat gap. Chapters
and Cast additionally record the synchronous native focus-update duration; that
is not input-to-presented-frame latency. CPU covers the full hierarchy setup,
first openings and teardown; fixed settling intervals dominate wall time.
Framework, shader and process caches remain warm between samples, so this is a
first visit per playback hierarchy, not repeated cold app launches or proof of
second-generation Apple TV performance. Prefer this workload over repeated tab
round trips when assessing first-use responsiveness.

`player-continue-watching-controls` mounts fresh production controls with a
cached, metadata-rich 180-item Home snapshot spanning twelve synthetic account
identities. It reveals transport controls and makes four native focus visits
(Continue Watching, Chapters, Continue Watching, Info), requiring populated,
focusable card content and stable native focus. `player-continue-watching-disabled`
uses the same snapshot with the preference disabled and visits Chapters and Info.
Compare their transport-reveal counters, not total CPU as though they performed
the same number of tab visits.

Controls-frame readiness is polled every 20 ms; this is not input-to-presented-frame
latency. A 2 ms main-actor heartbeat records the largest reveal/navigation gap.
The report also counts Home snapshot reads, provider child requests, native
focus-update duration, process CPU and resident memory. There is no video decoder,
real server, remote artwork or full Home aggregation in this workload. One discarded
warmup precedes five measured fresh hierarchies. Framework caches stay warm.
The separate `testContinueWatchingPendingArtworkDoesNotBlockNativeNavigation`
uses actual artwork requests to an owned loopback server delayed for ten seconds,
verifying that no artwork starts just to reveal transport and that native tab
navigation completes while the images remain pending.

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

`player-controls-cold-reveal` creates a fresh production TV controls hierarchy
for every sample, requests its first reveal without a settling delay, and
completes three show/hide cycles. It includes local synopsis metadata and track
options but no artwork requests or video decoding. First/last main-actor heartbeat
gaps distinguish initial layout work from settled repeats; they are not rendered
frame timings. The process and framework caches are warm after the discarded
warmup, so this is cold view construction, not cold app launch.
`player-controls-first-card` adds the first Info-card opening and verifies its
visible bounds and focus readiness. Compare both when deferring optional content:
less transport-entry work can increase first-card initialization cost without
reducing total CPU. Hosted lifecycle, OCR, focus and fade tests separately
protect the fixed card stage, first content, retained state and native materials.

`player-controls-hidden-clock` advances the mounted TV transport's playback and
buffered positions 32 times at the production 250 ms cadence after hiding it.
`player-controls-hidden-static` observes the same settled hierarchy without
clock mutations; `player-controls-visible-clock` repeats the advancing workload
with controls visible. Each eight-second sample verifies the completed updates
and timeline collision-region visibility. These isolate clock-driven UI work
without video decoding, network traffic, or thumbnail extraction. They measure
app-process CPU, not second-generation Apple TV GPU cost or rendered frame pacing.

`player-controls-reveal` mounts the production TV transport with sixteen audio
tracks and thirty-two subtitle tracks, then shows and hides it four times per
sample. `player-controls-reveal-contended` repeats the same interaction with a
controlled 180 ms synchronous preference read through the real system-audio
backend's reader seam. Both require four completed reads and visible timeline
geometry on every reveal. They report main-thread read counts and the largest
2 ms main-actor heartbeat gap separately from app CPU.

These isolate the controls' preference synchronization, not remux decoding,
network throughput, GPU presentation or second-generation Apple TV performance.
The separate `PlayerControlsRevealRenderingHostedTests` retains hidden,
intermediate and fully visible screenshots while a preference read is still
blocked, so removing the fade cannot count as the fix. Run the existing native
audio-menu and controls-rendering regressions alongside it to preserve focus,
confirmed settings, hidden/background polling and both glass/fallback materials.

## Native Home navigation attribution

For focus/scroll lag rather than isolated work counts, run the production Home
fixture with real `XCUIRemote` directional input:

```sh
python3 tools/performance.py profile --platform tvOS --sim-id "$PLOZZ_SIM_ID"
python3 tools/performance.py profile --platform tvOS --sim-id "$PLOZZ_SIM_ID" --workload detail-return
python3 tools/performance.py profile --platform tvOS --sim-id "$PLOZZ_SIM_ID" --workload horizontal-navigation
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

The `horizontal-navigation` workload traverses the custom top bar with real
library pages available: fifteen Right presses to library ten and fifteen Left presses
back to Home, repeated three times without per-key accessibility polling.
Each endpoint must have actual native focus, while the open page remains Home.
Only Select opens a different page. It retains the transition journal
and three round-trip durations, which include UI-driver overhead and are not
input latency or FPS. The fixture creates isolated library models/settings;
it does not measure connected-server latency. Keep this exact input cadence for
before/after attribution. Captures from the former focus-preview behavior include
page construction and are not equivalent page-work benchmarks. Hosted focus checks
separately verify that rapid and settled focus never change or rebuild the open page.

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

### Jellyfin Home recommendation reuse

`home-recommendation-navigation` runs production `JellyfinProvider.homeHubs`
and `homeRowPage` decoding/mapping with three synthetic shelves and 5-ms HTTP
latency. Each sample starts with a fresh client/scope. It requests limits
20/8/20/20, then verifies two shelves' 40-item windows ending at 40, 70, and
140. The 240-item counter means six checked windows, not complete traversal of
280 distinct items. Exact ordered IDs and next offsets are asserted.

One warmup and five measured samples on the same tvOS simulator, toolchain,
optimized build settings, fixture, and measurement harness produced:

| Metric | Uncached | Exact-request reuse |
| --- | ---: | ---: |
| HTTP requests | 10 | 5 |
| Response bytes | 84,328 | 41,324 |
| Verified window items | 240 | 240 |
| Median wall time | 76.85 ms | 39.18 ms |
| Median CPU time | 15.94 ms | 8.44 ms |
| Median resident snapshot | 148.19 MiB | 144.78 MiB |

Baseline evidence is `f89be5b623d9499dbd23f16f6870f159`; candidate evidence is
`81d72504dd3e4e59b32d53be00d28c72` under `.build/performance/runs/`.
These are descriptive same-workload measurements, not an automatic comparison
verdict: `compare` rejects the broader fixture fingerprint because separate
regression-test files were added or edited. The workload, `PerformanceProbe`,
runner hashes, and complete environment identity were independently verified
unchanged. Resident snapshots are not isolated cache cost or peak memory.

Five read-only trials against one internal Jellyfin server through the actual
provider and `HomeContentPageLoader.Session` measured a 4.21-second median cold
discovery versus 43.21 ms total for three subsequent scoped consumers. All three
consumers preserved the captured ordered titles without another HTTP request.
Refreshing the scope made a fresh authenticated request in every trial. Separate
live Plex, Emby, and combined-provider browsing checks preserve their behavior;
these timings are not measurements of those servers, rendered frames, or devices.

Earlier direct-transport experiments tested 75 trials/180 recommendation or
similarity requests. Exact-limit reuse preserved results; speculative larger
limits changed title membership and were rejected. Smaller payloads alone did
not materially improve the cold request. A two-category progressive response
was faster, but adds traffic and is not implemented. The first uncached full
recommendation request remains server-limited.

Upstream references informed the choice, not copied implementation:
[Jellyfin Web's freshness](https://github.com/jellyfin/jellyfin-web/blob/b71bb29ed68c8ec46e47a4e5557e0cc81c91e32b/src/utils/query/queryClient.ts#L9-L13),
[Android TV's per-seed composition](https://github.com/jellyfin/jellyfin-androidtv/blob/dae2c8c06911734e9e1d2abf5fc1e737067fcfb6/app/src/main/java/org/jellyfin/androidtv/ui/browsing/SuggestedMoviesFragment.kt#L25-L50),
and [Swiftfin's generation fencing](https://github.com/jellyfin/Swiftfin/blob/0978922b923dac390a4b5a7a961a7fd06cef296b/Shared/Objects/PagingLibrary/PagingLibraryViewModel.swift#L314-L374).
Their compositions and account/cache boundaries are not interchangeable with
Plozz's exact server-authored shelves.

### Scenario inventory

| Suite | Production path and limits |
| --- | --- |
| `core` | Unchanged sync persistence (10,000 records, 1,000 checks), warm incremental Share scanning (1,000 films), fresh SQLite IPTV import (10,000 generated records). The sync/Share fixtures also verify an actual edit is not suppressed. |
| `ui` | Shared `MediaRowView`/poster presentation with generated local artwork, settled idle, programmatic scrolling, repeated host/view teardown. Shared card scenarios run on tvOS, iPhone and iPad simulators and are **not the entire Home screen**. The tvOS-only `home-artwork-layout` scenarios exercise production Showcase artwork invalidation and duplicate reports across eight populated rows, with direct nested-host fitting duration/counts, sizing/placement counters and layout/focus controls. The `-cold` variant mounts a fresh view graph with warm artwork; it does not simulate every cold cache or a complete navigation session. |
| `matrix` | Full 16-case factorial: 1/4 resolved fixture-provider accounts × Plozz automatic channels off/on × cached Live TV data off/on × local cloud-sync processing off/on. Uses account resolution, `LiveTVLibraryRuntime`, source/portable sync bridges, and ledger persistence, with isolated defaults, in-memory credentials, local catalogues and provider doubles. |
| `diagnostics` | 10,000 operation attempts with recording disabled/enabled, plus 100 bounded snapshot encodes. Measures recorder and event-time serialization overhead without starting Sentry or creating uploads. |
| `network` | `catalog-cached-refresh`: 1,000-channel loopback M3U import with a 100-ms header delay, then an expired-catalog refresh held while three cached reads complete. Verifies one refresh and actual replacement visibility. Cold/cached foreground timings are separate counters; whole-cycle wall time includes setup, controlled waiting and settling. No external playlist or stream links are fetched. |

`silo-identity-modern`, `silo-identity-legacy`, and `silo-identity-mixed` in the
`network` suite load 200 series through the native Silo catalog, then run shared
identity enrichment alongside a 20-card native Home request. The synthetic HTTP
client adds 75 ms per request. Modern cards declare all known external IDs;
legacy cards expose only an encoded anchor; mixed pages contain 40 legacy cards.
Every sample must finish all 200 IMDb/TMDB/TVDB ownership matches and preserve
the exact Home order. Counters separate catalog, detail and Home requests and
peak concurrency. These measure completed indexing with competing Home work,
not Home first-pixel timing, real-server rate limits, DNS or physical devices.
Refusal/cooldown behavior is covered separately by correctness tests.

`live-tv-schedule-sync` uses the real automatic planner for 4,000 films and five
distinct channels, then changes only genre/studio spelling. It measures retained
snapshot records while checking that published broadcasts are preserved.
`live-tv-schedule-capture` captures 12,000 items, advances the published horizon
five times, then changes the inputs; full encoding count must fall without
suppressing that final change. Neither scenario measures CloudKit delivery.
`guide-large-batches` downloads a generated 23.8 MB, 48,000-programme XMLTV file
for two 2,000-channel batches. Request/byte reductions must preserve all 32,000
requested rows; parse count is separate. It now includes encrypted indexing of
all 6,000 candidate channels, with separate cold-first-batch and warm-second-batch
timings. Generation identity verifies one completed import across both queries.
The older fixture parsed twice without persistence; comparing total time includes
the new full-catalog write cost, not just a warm-cache speedup. It uses loopback,
not a real provider, and does not measure rendered scrolling or physical devices.

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

### Many-share scan pressure

Run `--scenario multi-share-scanning` on either simulator platform. Twenty
production catalog/scanner lifecycles each index 24 folders with eight files,
using synthetic transport sessions with 30-ms directory latency. Every sample
must finish all 20 scans, 500 directory listings, and 3,840 assets while bounded
cached reads and main-actor scheduling probes continue. It uses no credentials,
external metadata, real SMB/WebDAV server, artwork rendering, or app-shell
navigation. It reproduces scan fan-out, not a physical-device freeze.

With Xcode 27.2 and iOS/tvOS 26.2, the unbounded coordinator reached **80 concurrent
listings** on both platforms. A two-scan shared budget reduced that to **8** in
every retained sample, with identical completed work:

| Simulator | Scan-cycle median, before / after | App CPU median, before / after |
| --- | --- | --- |
| iPhone 17 Pro | 597 / 2,598 ms | 2,261 / 1,802 ms |
| Apple TV 4K third generation | 622 / 2,592 ms | 2,436 / 1,810 ms |

This is intentional background throughput reduction, not a faster full scan.
The generic comparison correctly flags the longer wall time as a regression;
its threshold was not relaxed. Median per-window maximum cached-read latency
fell from 6.8 to 1.4 ms on iPhone and 5.4 to 1.8 ms on TV, but one candidate
iPhone window reached 271 ms. No consistent worst-case foreground-latency
improvement is established. Main-actor probe maxima stayed below 1.1 ms;
the fixture does not establish scrolling FPS, presented-frame timing, or
responsiveness of the reported real profile. Resident snapshots were broadly
unchanged and are not peak allocation measurements.

Retained baseline/candidate runs are
`2a05f812ff7d4f939cfe916a737b6e1a` / `6a756515ae754b3687500f972d1101a8`
(iPhone) and
`8a810882dda345c0999dd3b837a40983` / `4169cd4543244dc78d1b893f56822f05`
(TV). Correctness tests additionally hold scan I/O and teardown open to verify
queueing, cached reads, playback priority, profile cancellation/resumption,
shared browsing pacing, and capacity retention until transport drain completes.

## Evidence contract

Runs live in ignored `.build/performance/runs/<id>/`. `result.json` contains:

- exact Git HEAD and hashes of current source/test/config/tool inputs, including
  staged, unstaged and untracked files; concurrent source changes fail the run;
- platform, simulator type/runtime build, SDK/Xcode, host OS/hardware,
  optimization flags, runner fingerprint, all test-fixture fingerprints,
  timestamps and host-load samples;
- each scenario's **one discarded warmup and five measured samples**, wall/CPU
  milliseconds, process resident bytes/delta, and actual workload counters.

New samples also include a `memory` dictionary with physical footprint,
resident/internal/external/compressed/reusable bytes, and reported malloc
in-use/reserved bytes and block counts. Capture happens after the timed window;
these process-wide diagnostics are not additional comparison-budget metrics.
Older reports without the dictionary remain readable; a present dictionary
must be complete and contain non-negative integers. Block totals are not live
object counts. Selected lifecycle/sync cases also retain
`plozz-memory-after-one-second-*.json` attachments after an untimed run-loop
drain while the fixture remains owned; that is not full-app teardown or forced
heap reclamation.

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

`seek-generated-80ms` and `seek-generated-180ms` exercise the production scrub
coordinator at all eight remote scan speeds in both directions. Each sample
delivers 384 inputs at 33-ms intervals through a paced synthetic extractor and
requires every final target to arrive. Motion-frame, starvation, cancellation,
concurrency, blank-publication, publication-gap and settle-latency counters
distinguish a responsive preview from one that only appears after input stops.
The synthetic delay is controlled fixture latency, not a decoder benchmark;
these scenarios do not establish Plex-network or physical-device performance.
Both require zero starved stages, zero motion cancellations, one in-flight
extraction, no blank publications, and publication/settle gaps below 500 ms.
This budget allows two 180-ms extractions plus scheduling overhead; the
two-second thumbnail grid limits visible frame changes at the slowest speed.

`seek-plex-bif` uses a real loopback HTTP server with 100-ms response latency
and a 3,601-frame, 320-pixel BIF fixture. Cold and warm passes cover both
directions at every speed, verify the final JPEG's pixel identity, require
frames during every moving stage, and permit only one index download.
This is controlled HTTP/JPEG coverage, not the reporter's Plex server.

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
