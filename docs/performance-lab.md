# Simulator performance lab

Use this for the agent-driven optimization loop without installing on an Apple
TV, iPhone, or iPad. It complements [physical profiling](performance-debugging.md),
not a replacement for device-specific evidence. No cloud account, real media
server, credential, or external model service is required.
Live-server workloads require separate authorization and explicit scenario
selection; no suite, including `all`, selects them automatically.

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
provider. It reports logical HTTP calls, duplicates, decoded response bytes per
caller, and time to first nonempty content row and all requested data. Coalesced
readers still count as separate calls; these counters are not wire-transfer counts.
Real loopback transport regressions separately verify transfer sharing and
authentication, redirect and cancellation isolation. The workload does not render Home,
download artwork, time login, restart the server, or measure scroll smoothness.
“Cold” means fresh provider/layout state, not a fresh process, a new shared
transport pool or cold server caches. Only numerical summaries
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

For **first sign-in frames**, use the standalone tvOS `PlozzFocusHost` instead
of the navigation driver. Use a fresh process for each command. Start external
`simctl io ... recordVideo` and wait for “Recording started” **before** launching
`account` or `profile`. With the authorized loopback broker URLs in the environment:

```sh
host=com.thatcube.Plozz.FocusHost
SIMCTL_CHILD_PLOZZ_JELLYFIN_ONBOARDING_BROKER="$PLOZZ_JELLYFIN_ONBOARDING_BROKER" \
  xcrun simctl launch --terminate-running-process "$SIM" "$host" --first-frame-account

export SIMCTL_CHILD_PLOZZ_JELLYFIN_HOME_BROKER="$PLOZZ_JELLYFIN_HOME_BROKER"
xcrun simctl launch --terminate-running-process "$SIM" "$host" --first-frame-seed
# Wait for seededUs in the seed PID's report. Keep this same broker/session alive.
xcrun simctl launch --terminate-running-process "$SIM" "$host" --first-frame-profile
```

Read `Library/Caches/first-frame-<launch PID>.json` in the host's data
container. Reject `failure` or missing required anchors. `authSuccessUs` starts
at real password-service success; verify the first **library selection** pixels.
For the returning viewer, `gateUs` starts at profile selection; verify shell,
populated Home, and (where present) `contentFocusUs` separately. The seed saves
profile configuration, not a token; the cold process restores the authorized
credential from the broker in memory before normal `RootView` bootstrap.
The yellow strip's first frame matches `referenceTargetUs` approximately;
use the movie's actual frame **PTS**, not DTS, assumed FPS or callback time.
The remaining bits mark gate, auth/authorization, next callback, content and
focus. They can coalesce. Read the screen **outside** the strip for first pixels.
To attach a profiler before the gate, add `--first-frame-hold` and touch
`Library/Caches/first-frame-<PID>.go` once ready. Diagnostics are already armed.

### Showcase: requests to prepare a row of series (#472)

Run `showcase-enrichment-jellyfin`, `showcase-enrichment-emby` and
`showcase-enrichment-plex` together with `run --platform tvOS --sim-id <UUID>
--scenario ...`. Each exercises the production row prefetch, metadata enricher
and provider mapping against in-memory HTTP responses. The 16 series each have
two seasons. Counts cover one complete preparation, not an entire Home load.

| Requests per provider | Before | After |
|---|---:|---:|
| Series detail | 16 | 16 |
| Season lists | 16 | 0 |
| Episode lists | 32 | 0 |
| Refocusing prepared cards | 0 | 0 |
| Explicit Play (resolves the expected episode) | 3 | 3 |
| Unpinned carousel enrichment | 4 | 4 |

With five retained samples on each side, median workload CPU was 3.97 → 1.75 ms
for Jellyfin, 4.24 → 2.26 ms for Emby, and 3.58 → 2.18 ms for Plex. These are
client CPU and provider-call measurements, not live server CPU, startup latency
or scrolling FPS. The optimization avoids computing a play target the
presentation would discard; it does not cache requests across users or loads.

**Live Jellyfin control:** select `showcase-series-live-jellyfin` with a
dedicated `PLOZZ_LIVE_HOME_BROKER` serving `/jellyfin`. This takes one real
series from the viewer's library and runs the previous pinning behavior against
the fixed behavior in the same binary. It alternates order, disables the HTTP
response cache, bounds each pass to 24 read requests, and checks that the two
presentations are equal. Setup and library selection are outside the timed
region. In five retained pairs, client reads were **3 → 1**, decoded response
bytes **18,505 → 2,038**, and median elapsed time **152 → 51 ms**. This measures
preparing that series, not the time to launch the app.

**First pixels and scrolling (tvOS simulator, real servers):**

| From → visible result | Baseline | Candidate |
|---|---:|---:|
| Jellyfin password success → first library-selection pixels | 149 ms | 182 ms |
| Returning profile selection → first Home shell pixels | 409 ms | 4,533 ms |
| Returning profile selection → first rail artwork | 1,397 ms | 4,938 ms |
| Returning profile selection → focus in populated Home | 3,972 ms | 5,074 ms |

These are paired single captures, not medians. Three further candidate captures
reached the first shell pixels at **6.50, 0.59 and 0.69 s**. In the slow one,
profile authorization finished at 77 ms. Preselection process samples did not
isolate the cause of the delay before Home appeared. The lower series-enrichment
cost is **not** evidence of a faster first frame.

**Returning-profile crossover:** six fresh processes per build, same signed-in
Jellyfin viewer, simulator, optimized harness and prelaunch video. Only the two
Showcase production files differed between binaries. Builds ran in balanced
`ABBABAABABBA` order. All 12 launches showed the following milestones,
measured from profile selection (median, with full range):

| What the recording showed | Before Showcase change | After Showcase change |
|---|---:|---:|
| First Home shell pixels | 462 ms (453–503) | 493 ms (450–535) |
| First rail artwork | 798 ms (751–1,596) | 840 ms (786–865) |
| Focus inside populated Home | 938 ms (836–1,596) | 938 ms (885–1,022) |

The original 409 ms started **2.28 s after the launch command** and measured
faint sidebar pixels, not usable Home. Timed from the launch command instead,
the crossover medians were **2.772 → 2.767 s** for shell pixels and
**3.262 → 3.213 s** for focus in populated Home. These include the fixture's
automated selection of the returning profile. The crossover did not reproduce the
multi-second stalls; it does not explain them. In a separate same-viewer
baseline experiment, the first shell took 536 and 535 ms without a local Home
snapshot, versus 569 and 483 ms on the corresponding warm relaunches. Diagnostic
runs verified that both the miss and the successful read/decode happened
*before* profile selection. The original run did not record cache hits. Server
and OS caches were not flushed; only one cache timing run had a focus witness.

On the separate carousel navigation workload (no production hero enrichment),
both Jellyfin runs completed 34 directional presses with 30 focus changes.
The validating relay forwarded 23 → 22 metadata GETs, including 3 → 2 exact
repeats, **all before the first Down**. Both runs forwarded 18 artwork GETs
after first Down, none repeated. Maximum navigation display-link gap was
40 → 33 ms; the initial artwork cache differed, so do not claim a scrolling
speedup. The actual Jellyfin application and console logs confirmed session
lifecycle but did not record successful request paths. On Plex, native logs
identified 38 artwork completions (3 repeated targets) and no metadata
completions after first Down. Emby completed the navigation workload; its
native log showed five disconnected artwork requests, not a complete access
trail. These are not measurements of server CPU or physical display FPS.

### Plex: one fewer library-list request per Home refresh (#472)

Match Server layout and Home content both need the viewer's library sections.
Home now uses the layout's fresh, successful read once instead of requesting the
same list again. Navigation still reads independently, as do future refreshes.
There is no time-based cache; a newer inventory or access denial supersedes the
earlier response even if Home is still waiting for promoted rows.

The same real Plex viewer ran the carousel traversal four times per build:
three fresh processes on a simulator with warm artwork and one on a new
simulator without app data. Native Plex logs counted completed GETs for the
viewer, not requests inferred from the UI. All responses were HTTP 200.

| Per traversal | Before | After |
|---|---:|---:|
| `/library/sections` reads | 3 | 2 |
| Section response bytes | 2,799–2,805 | 1,870–1,876 |
| Total metadata reads (unique targets) | 17 (15) | 16 (15) |
| Metadata completions after first Down | 0 | 0 |
| Libraries / items / focus changes | 3 / 74 / 30 | 3 / 74 / 30 |

All eight runs completed 34 directional presses with no navigation display-link
gap over 50 ms. In the fresh-simulator pair, artwork completions during scrolling
went **29 → 40**, while their total response bytes went **2.91 → 1.61 MB**;
none were repeated targets. Warm runs had no artwork completions after first
Down. Artwork demand varied; the reliable saving here is the single metadata
request, not a change in scrolling speed or overall artwork traffic.

The Jellyfin control forwarded 22 metadata GETs on each build (two repeated
targets, all before first Down). Jellyfin and Emby both retained their item
counts (83 and 66), with 30 focus changes and no discovery, layout or row
failures in either build.

### Dense Home: scrolling while server rows arrive (#472)

On `d7c639d1a`, iPhone 17 Pro simulator (iOS 26.2), run
`mobile-home-one-server-startup-scroll`, `mobile-home-multi-server-startup-scroll`
and `mobile-home-multi-server-scroll` together. Run
`bcfcd0bbb127422f9280fc0f2a6246d1` passed with one warmup and five retained
samples per scenario. Figures below are medians, from release of the simulated
provider responses, **not** from sign-in or first pixels:

| Mobile Home | First populated row | All rows ready | Counted provider calls |
|---|---:|---:|---:|
| 1 source, 2 rows, 40 cards | 343 ms | 350 ms | 5 |
| 20 sources, 40 rows, 800 cards | 623 ms | 9.90 s | 100 |

With 40 rows, the median longest main-actor scheduling gap was **85 ms during
loading** (80–95 ms) versus **49 ms after loading** (46–53 ms) over the same
24 animated scroll targets. The two-row control fit on screen and is **not**
a scrolling baseline. Each provider deliberately staggers its response times;
row count, source count and latency all change between configurations. The
fixtures use cached artwork and make no requests to a real server. These
measurements show contention on the loaded page, not server CPU or display FPS.

**tvOS, holding server count fixed:** four alternating launches of the same
optimized production `RootView` used one loopback Jellyfin fixture, the same
40 libraries, and 20 distinct movies and posters per library. Only the number
of enabled server rows changed. The featured hero was disabled, but the
saved default row style remained Showcase, not classic carousel. Prelaunch video and
native focus measured returning-profile selection independently of data loading.

| tvOS simulator (two recorded runs per configuration) | 3 rows / 60 cards | 40 rows / 800 cards |
|---|---:|---:|
| Selection to first distinct Home sidebar in recording | 0.85–1.27 s | 10.19–11.79 s |
| Selection to focus in Home content | 1.30–1.80 s | 10.18–11.80 s |
| Peak sampled app resident memory | 432–438 MiB | 937–957 MiB |
| Requests reaching loopback, selection through completion report | 113–164 | 1,364–1,979 |

All 40 dense row requests succeeded exactly once. In the two dense runs, **917
of 918** and **1,157 of 1,157** artwork reads had distinct path/query keys:
most of that traffic was not retrying the same image request. Single-item
detail did repeat: **382 reads for 270 distinct keys**, and **758 for 640**.
By first native content focus the origin had already received 108 and 146
artwork reads respectively, although only 13 and 14 of the 40 row queries
had started. No traffic reached a real Jellyfin server.
Gaps of up to 1.7 s between recorded frames limit the
precision of first-pixel timing. Full dense Home loads took 151–153 s with
recording, versus 23 s in a separately paced, unrecorded navigation run; these
are not hardware load-time estimates. In that run the same six verified focus
moves took 11.47 s while rows were arriving and 3.65 s once settled, including
XCTest overhead. Focus subsequently reached row nine. This isolates a repeatable
row-count problem, not the cause of the earlier intermittent small-Home stalls.

**What other clients defer.** Jellyfin Android TV [starts a query-backed rail's
initial request when adding it](https://github.com/jellyfin/jellyfin-androidtv/blob/45c52925661ff51427cea46ebabcd3de656276cc/app/src/main/java/org/jellyfin/androidtv/ui/home/HomeFragmentBrowseRowDefRow.kt#L27-L44),
but binds cards through [reusable presenters](https://github.com/jellyfin/jellyfin-androidtv/blob/45c52925661ff51427cea46ebabcd3de656276cc/app/src/main/java/org/jellyfin/androidtv/ui/presentation/CardPresenter.kt#L84-L95).
Jellyfin Web likewise [resumes every Home section](https://github.com/jellyfin/jellyfin-web/blob/fa7831bd1fd72e61b3133d2234832201d6dc803e/src/components/homesections/homesections.js#L130-L140),
then [registers the returned cards' images for lazy loading](https://github.com/jellyfin/jellyfin-web/blob/fa7831bd1fd72e61b3133d2234832201d6dc803e/src/elements/emby-itemscontainer/emby-itemscontainer.js#L423-L446)
with a [viewport margin of 50%](https://github.com/jellyfin/jellyfin-web/blob/fa7831bd1fd72e61b3133d2234832201d6dc803e/src/components/lazyLoader/lazyLoaderIntersectionObserver.js#L7-L21).
Neither requires a vertical scroll to fetch every kind of row metadata. For
Plozz, count row queries separately from poster and detail reads: deferring
the latter can leave all 40 rows indexed without making the viewer wait for
800 cards to be prepared.

#### Does limiting the classic carousel to the first four rows help?

**No clear startup win; worse rapid navigation.** An optimized tvOS simulator
host ran the full returning-profile picker and Home, using a local
Jellyfin-shaped origin with 40 shelves of 20 distinct movies and one additional
resumable movie for the carousel hero. The comparison kept the dataset, hero,
provider and enabled rows fixed. All versions completed 40 successful, unique
shelf reads (24,520 compressed body bytes), publishing 41 nonempty rows and
801 entries including Continue Watching. The four-row experiment deferred row
**views**, not row data. A second experiment simply wrapped each row in one
`VStack` without limiting the number of views.

| From profile selection (two recorded starts per version) | Original carousel | Four-row limit | Single wrapper, no limit |
|---|---:|---:|---:|
| First recognizable shelf 1 artwork | 913–990 ms | 894–899 ms | 849–909 ms |
| First visible bright Resume action | 994–1,230 ms | 988–1,000 ms | 1,029–1,066 ms |
| Image requests received by visible Resume | 17–18 | 17–35 | 19–36 |

Recording began before process launch. Original launch-command to visible Resume
was 3.25–3.53 s including the chooser and test gate; this was not initial
password sign-in. Native focus and video pixels were observed separately.
Two starts per version with fresh profiles/ports but shared OS caches do not
establish a small timing difference. This fixture explicitly selects carousel;
it does not invalidate the slower dense Home measurements above.

To collide scrolling with unfinished work, a separate run delayed shelf reads
from shelf 4 onward. The remote sent eight Downs about 220 ms apart, then
eight Ups. With no intentional dwell after XCTest verified focused Resume,
17–18 shelves had finished before the first press. Original Home reached shelf 8
and returned to Resume in both trials: on shelves 2–8, native focus took
11–37 ms from input; the first recognizable posters took 137–279 ms, including
scroll animation. The four-row limit **missed the third Down twice**, reaching
only shelf 7; first posters on shelves it did reach took 163–471 ms. The
wrapper-only version reached shelf 8 and returned, with first posters in
95–192 ms in its one immediate trial.

After **10 s without input**, every version had all 40 shelves' titles and
none had requested a poster for shelves 2–40. Original and wrapper each had
requested 20 distinct shelf-1 posters; the four-row version had requested 7.
Subsequent first visits to shelves 2–8 showed recognizable posters after
151–188 ms (original), 114–187 ms (wrapper), or 289–358 ms (four-row).
Brief placeholders were visible; the pixel test did **not** require every
poster or even the focused poster to be painted. No traffic reached a real
server. Keep classic Home unchanged: neither the four-row limit nor preloading
all posters is justified by these trials.

#### Isolating the dense Showcase layout

The original dense fixture changed `HeroSettings.default.isEnabled`, not the
saved style. On tvOS, switching off the featured hero does not turn Showcase
rows into classic carousel rows. To isolate the layout, a follow-up used the
**same binary, enabled hero and 40 × 20 dataset**, changing only the saved
style in Showcase → carousel → Showcase order. The object of measurement was
returning-profile selection to native Home content focus, not a display callback.

| Unrecorded simulator starts | Carousel | Showcase |
|---|---:|---:|
| Selection to first native Home content focus | 1.05 s | 27.12 / 93.27 s |
| Image GETs completed by that focus | 32 | 692 / 623 |
| Single-item detail GETs completed by that focus | 2 | 178 / 198 |

Across each full load the local origin received all 40 shelf queries exactly
once and Home published 41 nonempty rows / 801 entries. Timings varied widely;
this isolates a slow layout, not a specific CPU hot spot or a hardware estimate.
In a separate prelaunch recording the original Showcase's first shelf artwork
appeared at about 9.3 s, and the bright Resume action at about 23.9 s.

**Rejected experiment:** limiting speculative detail and artwork work to nearby
shelves (including card appearance-triggered prefetch) reduced response bodies
received through two seconds after completion from **6.94–7.43 MB to
0.63–0.67 MB**. Exact-key duplicate requests fell from 150–151 to 18–24;
no shelf queries or content were lost. But fast navigation after a 10 s dwell
left shelf 7 gray on the descent: recognizable artwork appeared only on the way
back, about 2.24 s after its Down, versus 185 ms on the original. Eight Ups
returned to Resume on the original, but not on the candidate, including in an
unrecorded repeat. The change was **not adopted**. These are HTTP receipts on
a loopback Jellyfin-shaped origin, not live-server CPU measurements.

**Where the time went.** In one profiled launch per style, the picker took
about 1.5 s in both. From selection to first native Home focus, Showcase took
38.02 s elapsed but only 8.25 s of main-thread CPU; carousel took 1.07 s
elapsed and 0.86 s of main-thread CPU. In Showcase, 3,238 of 4,155 main-thread
samples were waiting inside RenderBox display during a Core Animation
transaction. Image-queue surface waits and buffer registration accounted for
3,049 of those samples; neither signature appeared in the carousel control.
This identifies a wait, not the layer responsible for it.

Removing only the Showcase viewport fade mask did **not** isolate the cause.
In run order, selection to native focus took **84.4 s original → 67.7 s
without mask → 53.4 s original → 40.0 s without mask → 21.1 s original**.
Both apparent gains disappeared against the next original run; RenderBox
display waits still accounted for 84% and 76% of samples without the mask.
All five runs fetched each of 40 shelves once and published 801 entries.
These unrecorded trials did not time first pixels. Keep the existing fade.

#### Preparing more Showcase shelves while the viewer stays on the hero

A simulator prototype kept each row's native owner and measured size, but
attached the first four shelves first and added more while idle or approaching
them. The viewer did not have to scroll to fetch row data or prepare later views.
In five alternating recorded starts, first shelf artwork moved from **8.85–11.05 s
to 1.99–2.09 s** after profile selection, and first native Home focus from
**17.96–19.19 s to 5.92–8.82 s**. In the 10-second dwell trial, all 41 row views
were attached before the first Down. Some extra rows were attached before the
first visible Resume button; this was not a strict first-frame gate.

Staging also introduced unnecessary reads. A poster on shelf 16, for example,
was decoded at 3.59 s, evicted at 7.20 s, then explicitly prefetched at 8.12 s
when its row was attached. This was the same URL **and** decode variant. The
origin sent `Cache-Control: no-store`; there was no reusable encoded response.
In all 30 sampled repeats where a preceding insert and eviction could be
unambiguously attributed, the second caller was the row's explicit prefetch.
This does not attribute every repeated request to eviction.

A correction initiated speculative prefetch on real card focus rather than
buffered card appearance for deferred poster rows only. Visible cards could
still load directly; neither row fetching nor cache policy changed. Six matched
recorded launches, one per configuration and input pattern:

| 10 s on hero before first Down | Original | Staged | Staged + corrected prefetch |
|---|---:|---:|---:|
| Selection to visible highlighted Resume | 32.91 s | 6.82 s | 5.57 s |
| Repeated artwork GETs through navigation report | 2 | 446 | 30 |
| Total response bodies through report | 6.13 MB | 12.81 MB | 5.11 MB |
| Shelf reached after eight Downs | 8 | 8 | 8 |

With immediate input, repeated artwork GETs were **10 / 339 / 23** and total
bodies **6.83 / 11.65 / 4.99 MB**, respectively. But eight Downs reached only
shelf **6 / 7 / 7**. All six runs fetched each of 40 shelves once, published
41 nonempty rows / 801 entries, and returned to Resume. These are local HTTP
receipts, not estimates of server CPU or production traffic. The correction
isolates a real prefetch cost, not a fix for the missed early navigation.

#### Final featured Showcase: startup and rapid navigation

The second Down really reached the app. Row 1 already owned native focus, but
SwiftUI was still propagating the change that re-enabled the other rows. UIKit
found no eligible destination until the next press. The final implementation
releases the first-entry reservation at the row host when UIKit commits focus;
it does not wait for an animation or replay the input. The staging policy also
prepares the nearest eligible shelf above focus if it becomes ready or the
order changes, without spending its lookahead on disabled recovery controls.

Final comparison: same optimized Apple TV simulator host, full returning-profile
picker, local Jellyfin-shaped origin and 40 shelves of 20 distinct movies plus
Continue Watching. Video was armed before launch. The driver verified a
visible highlighted Resume button before pressing Down, either immediately
or after a 10 s dwell. Times run **from profile selection**, not password sign-in.
One original and one final start per input pattern:

| Immediate / dwell runs, respectively | Original | Final |
|---|---:|---:|
| First recognizable shelf 1 artwork | 13.76 / 39.45 s | 1.93 / 2.54 s |
| First native Home content focus | 23.68 / 48.68 s | 5.45 / 6.20 s |
| First recorded highlighted Resume | 24.11 / 49.55 s | 5.64 / 6.47 s |
| Completed HTTP response bodies through navigation report | 6.36 / 6.94 MB | 4.83 / 4.99 MB |
| Repeated artwork GETs through report | 3 / 1 | 6 / 29 |

Every run reached shelf 8 in order, returned to Resume in eight Ups, fetched
each shelf exactly once and published 41 nonempty rows / 801 entries. The
final version used fewer total bytes, **not fewer repeated artwork reads**
than the original. Recognizable shelf 2 artwork followed Down 2 by 729 / 691 ms;
accepting focus is not the same as painting a poster. In a separate controlled
case, one Up reached a newly enabled Retry above focus with idle preparation
disabled. Neither simulator times nor local HTTP body bytes measure physical
Apple TV performance or real-server CPU.

The real Jellyfin and Plex viewers authenticated and loaded Home, but the
adjacent-row navigation assertion failed on **both original and final**.
The native-sidebar one-card-row check also skipped to the same wrong card
in both versions. Those checks remain unresolved, not passes. Native Jellyfin
logs showed session lifecycle rather than successful GET paths; a bounded
Plex log slice was not isolated to this client.

#### Review follow-up: wait for a usable target, skip shelves already attached

The comparison here is against `7fd4ad1f7`, **not** the unstaged Home above.
It used the same 40-shelf simulator fixture, recording before launch, with one
returning-profile launch per build and input pattern. All four runs reached shelf
2 on Down 2, continued to shelf 8, returned to Resume, and fetched every shelf once.

| Metric | Immediate (before → after) | 10 s dwell (before → after) |
|---|---:|---:|
| Profile selection → first shelf artwork | 2.07 → 2.22 s | 2.31 → 2.26 s |
| Profile selection → visibly highlighted Resume | 6.15 → 5.20 s | 4.07 → 5.62 s |
| Down 2 → shelf 2 native focus | 35 → 29 ms | 568 → 446 ms |
| Artwork GETs through navigation report | 624 → 704 | 684 → 704 |
| Of those, repeated artwork GETs | 12 → 30 | 32 → 32 |

These runs establish navigation correctness, not a consistent startup speedup.
Most additional reads were distinct URLs; the immediate run also made 18 more
repeats. Counts stop at the navigation report, not after the server settles.
They do not establish eventual traffic, real-server CPU, or scrolling frame rate.

The checked-in `ShowcaseNavigationTests/testRapidDownTwiceFromFeaturedHeroFocusesSecondShelf`
tests the native handoff independently of timing luck. It waits for the painted
Resume action and withholds the first shelf's SwiftUI focus report. Nothing is
polled between the two remote presses; the expected result is a native shelf 1
→ shelf 2 transition and final focus on shelf 2. Disconnecting just the native
row-entry callback made this assertion fail; restoring it made the test pass.

#### What the 40-shelf Home requested before the viewer could navigate

On `83774fd4c`, the synthetic origin logged **224 and 240** movie-detail GETs
started by first native Home focus in the immediate and dwell launches above.
Only **128 and 136** were distinct request keys: **96 and 104 repeats** occurred
before the viewer pressed Down. One attempt aborted in the immediate sample.
These counts exclude artwork, shelf membership, and the featured title. Each of
the 40 base shelves was fetched once. Starting an HTTP request is not evidence
that a frame was delayed or a server CPU core was busy.

The Showcase detail prefetcher selected 16 titles per shelf and keyed its task
on the items in *all* shelves; publishing another shelf could cancel and repeat
pending work. Focus also needs a path to recover if it lands on a title owned
by a speculative request that is then cancelled.

Direct, same-viewer checks on populated Recently Added movie shelves also
showed why **skipping every detail fetch** is not equivalent to controlling
prefetch. On Jellyfin, four shelf records matched detail for title, year,
overview, certification and artwork references, but lacked genres and taglines.
Requesting those two fields on the shelf added 5,598 bytes across 20 items
without changing membership or order; fetching the four full records cost
59,475 bytes. On Plex, the four records already matched the detail descriptions
and artwork references but not all genres; the four full responses totaled
76,292 bytes.

On Emby and Silo, each sample covered three movies and three series. Emby's
six detail reads totaled 71,252 bytes; five added certification and genres,
and four added taglines. Asking the shelves for genres and taglines added
7,599 bytes, but only one of six records then matched detail on all nine
fields checked. Silo's six detail reads totaled 89,785 bytes. All six added
ratings and cast, and all six had a different logo reference; image bytes
were not compared. These were API probes, not app traffic savings. They do
not establish that a wider shelf response would help all shelves or providers.

#### Warming neighboring details and posters under heavy load

The candidate prepares full details for plausible next cards and only starts
directional poster warming after a horizontal move within a staged shelf.
Base shelf requests, displayed posters, and idle attachment still run without
scrolling. We compared it to `83774fd4c` using the same optimized tvOS host,
returning profile, 40-shelf Jellyfin-shaped origin and remote driver. Video
and diagnostics were armed before launch. Each build had three immediate and
three 10-second dwell runs; the builds were tested in groups, not interleaved.

| Median, baseline → candidate | Immediate input | 10 s dwell |
|---|---:|---:|
| Launch → first recognizable Home shell | 8.16 → 8.95 s | 8.21 → 7.48 s |
| Profile selection → first recognizable Home shell | 2.07 → 1.79 s | 2.03 → 1.77 s |
| Profile selection → first shelf artwork | 2.07 → 2.08 s | 2.03 → 2.25 s |
| Profile selection → visibly highlighted Resume | 5.38 → 6.10 s | 5.57 → 5.56 s |
| Down 2 → shelf 2 native focus | 39 → 36 ms | 510 → 458 ms |
| Down 2 → shelf 2 recognizable artwork | 771 → 774 ms | 837 → 776 ms |
| Movie-detail GETs completed by first native Home focus | 220 → 5 | 216 → 4 |
| Exact repeats among those GETs | 96 → 1 | 92 → 0 |
| All non-art metadata requests at the settled endpoint | 844 → 91 | 844 → 85 |
| Artwork GETs at the settled endpoint | 680 → 568 | 682 → 568 |
| Exact repeats among those artwork GETs | 30 → 4 | 30 → 4 |

The settled endpoint is eight seconds after verified return to Resume and full
row publication, not eight seconds after launch. A metadata-only control (one
start per input pattern) had 4 / 6 movie-detail reads at first focus, but still
695 / 704 settled artwork GETs. In every timed run, all 40 shelf responses
arrived once, 41 rows / 801 entries were published, eight Downs reached shelf 8
in order, and eight Ups restored Resume. A separate remote test verified
horizontal warming and reversal on both eager and deferred shelves. A sparse
list fixture also rendered the correct full synopsis after vertical entry,
four Rights and three Lefts.

This reduced traffic, **not consistently time to usable Home**. There were
still 434 artwork GETs (3.00 MB) on unvisited shelves 10–40 in every group;
the log cannot distinguish display from prefetch callers. Largest observed
navigation frame gaps were 1,150 → 888 ms immediate and 715 → 677 ms after
dwell, not evidence of smooth hardware scrolling. In separate startup-through-
return process samples, main-thread CPU was 18.44 s over 24.52 s elapsed
before and 15.27 s over 21.36 s after (one sample per build). SwiftUI/UIKit
sizing and layout dominated; `FocusHeroMotionSurface.sizeThatFits` was the
nearest app frame in 479 / 358 stack observations. This points to reducing
redundant row measurements, not running UIKit layout on a background queue.
These are simulator and loopback origin measurements, not live server CPU,
password-sign-in timing, or physical Apple TV performance.

## Baseline → attribution → candidate → regression

### tvOS: rapid vertical IPTV guide travel

The `PlozzFocusHost` fallback exercises the production top bar, guide and
local video preview together. Build `PlozzHomeFixtureTests` for the owned
tvOS simulator with Debug `SWIFT_OPTIMIZATION_LEVEL=-O`. If XCTest cannot
connect, install that host on the same simulator and launch it under the same
build lease with these arguments:

```sh
xcrun simctl launch --stdout="$RUN/travel.out" --stderr="$RUN/travel.err" \
  "$PLOZZ_SIM_ID" com.thatcube.Plozz.FocusHost \
  --large-native-navigation-fixture --guide-travel --category-live-preview --category-search-guide-first
```

Bound the run to 90 seconds and terminate the host afterward. Accept only
`GUIDE_TRAVEL PASS` with six complete records. Discard warmup `rep=0`.
Each pass requests rows 1–12, then 11–0, with a 120 ms dwell after each
request. The probe checks the actual `UIFocusSystem.focusedItem` identity
and cell bounds after every dwell. It also checks the same ready player
layer, local MP4 item and advancing media clock. `gapsUs` contains successive
`CADisplayLink.timestamp` differences in microseconds; compute nearest-rank
p95 **per pass**, then take the median. `cpu` is process CPU seconds.

Optimized Debug, Xcode 27.0 beta (27A5194q), tvOS 27.0, Apple TV 4K
1080p simulator; same sidebar work in both builds. The fixture mounted 29
destinations plus profile, imported 240 channels × 48 half-hour programmes,
and played the bundled `live-continuity.mp4` through `CategoryPreviewPlayer`.

| Five measured passes; 120 verified moves per build | Before | After |
|---|---:|---:|
| Median p95 display-link gap | 54.97 ms | 38.87 ms |
| Median worst gap per pass | 69.61 ms | 54.41 ms |
| Gaps >50 ms / total sampled intervals | 58 / 675 | 7 / 758 |
| Median process CPU / 24 moves | 2.512 s | 1.888 s |
| Median elapsed / 24 moves, including dwells | 3.198 s | 3.130 s |

A separate main-thread sample implicated SwiftUI layout and graph updates as
row hosts moved. Changing progress shading alone barely moved p95 (53.82 ms)
and was discarded. Instead, while browsing vertically at the timeline's
leading edge, mount the visible programmes and one offscreen candidate, not
two additional screens of controls. Horizontal browsing, VoiceOver and focus
handoffs retain the wider window. This compares **programmatic native focus
travel**, including target lookup and cell reveal, not remote-event latency,
presented-frame hitches, network playback, or physical Apple TV performance.
Local source patches, binary UUIDs, raw runs and screenshots: `.build/guide-travel-lab/`.

For a **remote-driven visual control**, replace `--category-search-guide-first`
with `--guide-remote-arrival`. This leaves the travel loop off, starts in
categories and omits listings on alternating rows. Press Right to enter the
guide, Left to the station, Left again to reveal categories, then Right to
collapse (reverse the horizontal directions in RTL). Track the unscheduled
channel **name relative to its station**, not only the row's final bounds.
Add `--guide-tab-first` to start with the actual Live TV tab focused and test
one Down into the page.

For the Now pointer, also pass `--guide-progress-edges`: row 2 has no
listings, row 3 has an active programme starting between ticks, and row 5
is between listings. In each recorded frame compare the triangle's center
with the shading boundary in those rows, away from text and rounded corners.
Check both sidebar directions, then scroll past Now and back at a fixed width.

On the 6475 follow-up, the 1080p recording showed up to 200 px of extra name
travel on reveal: a fixed-width label was centered in a resizing native
button. Letting it fill the proposal held the measured spacing constant in
both directions through 408 px of travel, also on the mirrored RTL capture,
without changing the 280 ms transition. With Reduce Motion on in simulator
Settings, only the two endpoints appeared in the recording. The fixture used
its text station plate, not downloaded provider artwork.

This was **not a vertical performance fix**. Repeating the all-scheduled travel control above
gave 39.61 → 38.30 ms median p95 and 8/737 → 10/735 intervals over 50 ms.
A separate main-thread sample showed AttributeGraph updates and hosting-view
layout, including glass layout; it does not isolate a particular control as
the cause. A row sizing/focus experiment did not materially improve p95 and
was discarded.

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

### Authorized real music transitions

`music-plex-live`, `music-jellyfin-live`, and `music-subsonic-live` are explicit-only
hosted workloads; neither `ui` nor `all` selects them. Use a dedicated, non-admin internal identity
with playback authorization. `PLOZZ_MUSIC_BROKER` must be a short-lived, owned
loopback HTTP endpoint with an unguessable path. It returns an array of
`provider`, `baseURL`, `serverID`, `userID`, `username`, and `token` configurations.
Subsonic configurations supply `password` instead of `token`, exercising Plozz's
real salted-token sign-in. That workload also checks artists, albums, songs,
genres, playlists, decodable authenticated artwork, and a favorite toggle/restore
before the same playback transitions. Use an identity authorized for test-history
writes.
Read credentials into memory, never arguments or files; stop the broker and
revoke its owned authentication sessions in `finally`.

The workload selects six tracks from a bounded twelve-track query in the first
visible music library. It uses production provider resolution, authenticated
resource resolution and `AudioPlaybackController`, with muted native output.
One warmup and five samples each cover cold start, next, previous, arbitrary
selection, a new queue, and rapid superseding selections. Every transition
requires the intended ready item, an advancing playback clock, and another
half-second of sustained playback. Counters separate outgoing-player stop,
progress reset, readiness, resolution and confirmed playback. Dataset hashes
permit comparison without publishing media identities. Cold means fresh client
playback state, not cold server caches. These are simulator transport results,
not acoustic output, physical-device, AirPlay or long-duration listening proof.

The local-mobile handoff change removed an eight-second next-item prebuffer wait
that was intended to protect the HomePod route. With identical tracks and
optimized Debug settings, the direct native XCTest runs measured these medians
(milliseconds, five retained samples after one warmup):

| Provider / simulator | Cold start | Next | Previous | Arbitrary selection | New queue | Rapid selection |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Jellyfin / phone before | 587 | 710 | 8,853 | 8,539 | 8,833 | 8,626 |
| Jellyfin / phone after | 549 | 360 | 590 | 535 | 545 | 663 |
| Plex / phone before | 390 | 726 | 8,817 | 8,451 | 8,506 | 8,503 |
| Plex / phone after | 396 | 368 | 640 | 539 | 567 | 591 |
| Jellyfin / tablet after | 523 | 350 | 573 | 567 | 528 | 638 |
| Plex / tablet after | 429 | 375 | 642 | 588 | 558 | 591 |

Both final simulator runs completed all 72 transitions including warmups. The
slowest retained transition was 762 ms; confirmation includes at least 200 ms of
advancing playback. Arbitrary selections previously left the outgoing audio and
progress active for approximately eight seconds. Deterministic delayed-resolver
tests now require both to retire synchronously, including failure and cancellation.
An earlier candidate run had a 3,254-ms Plex outlier, of which 2,796 ms was stream
resolution: removing the client wait does not remove server/network variability.
The first simulator/process warmup is excluded from the table, not a guarantee
of subsecond first-ever launch.

The standard Xcode test driver stalled before launch on this host; the results
above came from bounded direct XCTest execution of the same optimized host,
not a completed performance-runner xcresult comparison. Local evidence retains
source hashes, dataset hashes, completed-test counts and every timing sample.
The implementation adds no URL cache or extra provider requests. It keeps the
current/next queue pipeline, uses the native buffer policy for local mobile
output, and exits cancelled waits promptly rather than spinning. tvOS and
explicit mobile AirPlay retain their route-preserving buffering policy.

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

For touch scrolling, run `HomeScrollGestureTests` in `PlozziOSInteractionTests`
on a phone and a full-width tablet. The hosted programmatic-scroll controls
above use a **390 × 844 compact window even on an iPad simulator**. The UI
tests instead assert the native window width and size class, drive a finger
drag, and require the page to coast farther than the finger moved. The settled
case repeats the same traversal; the during-publication case relaunches for
each swipe, starts with four complete shelves, and requires more to publish
during native motion. It checks document height, painted posters, all 40
shelves / 800 titles, and 100 fixture provider reads. This is a hero-disabled
Home with locally seeded poster responses, not sign-in timing or live traffic.

Check which metrics the simulator actually exported. On iOS 26.2 with
Xcode 27.1, the dragging/deceleration interval had a duration but neither it
nor `XCTHitchMetric(application:)` returned hitch measurements, even with a
verified 350 ms main-thread stall during motion. Do not treat a missing metric
as zero, shorter coast time as smoother scrolling, or a passing gesture test
as evidence of a frame-pacing improvement.

On the `ea15c2325` baseline, full-width simulator recordings showed the
difference the duration metric missed: the median longest gap between visible
poster movements during a swipe was 408 ms on iPad and 222 ms on iPhone while
the remaining shelves loaded, versus 35 ms on both once loaded. A trial that
reused unfiltered shelf arrays yielded 307 / 255 ms during loading and 30 /
33 ms after loading, respectively. It was not retained as a scrolling fix.
These are three loading and five settled swipes per build/device, tracking
original video timestamps between 5% and 85% of travel. The injected stall
was distinguishable in recordings on both devices. These are simulator video
gaps, not physical display hitch ratios or proof of the same cause on hardware.

A separate experiment traced a burst of unchanged headings updating to the
Edit action that Home passes to each shelf. Giving that action stable identity
cut heading evaluations on an instrumented iPhone swipe from 1,512 to 36.
In uninstrumented comparisons against `ea15c2325`, the median longest visible
pause during publication went from 330 to 249 ms on iPad but from 210 to
236 ms on iPhone (six fresh-process swipes per arm and device). Settled values
were 27.5 to 28.3 ms and 34.2 to 35.0 ms, respectively (ten swipes each).
Reducing layout work was real; it did not demonstrate smoother iPhone scrolling.
Across three further instrumented iPhone swipes on that candidate, 27 of 30
rail-body evaluations during the visible pauses were more than one viewport
away. No distant card appeared, started artwork resolution, or bound a bitmap.
The instrumented distant rail builders and card bodies used only 1.4–1.9 ms
of main-thread CPU during 218–300 ms pauses. This does not account for
framework layout, commit, or compositing; it is not evidence to delay loading
offscreen shelves.

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
The native tap borrows the original format and size; a worker converts a private
copy to at most 320x180. Applying that size/format requirement to AVPlayer itself
can change displayed colors. The private buffer bound does not cap AVFoundation's
internal decode/render allocations or the original frame retained during analysis.

At `c8230507a` (engine `055860a`), Xcode 27.1 and an iOS 27.1 iPhone simulator
measured the single-player pair below. Each case discarded one warmup and retained
five 2.3-second windows. CPU figures are medians of app-process CPU milliseconds
per elapsed second, not wall-clock processing delays.

| Comparison | Analysis off | Analysis on | Extra CPU ms/s | Resident snapshot difference |
| --- | ---: | ---: | ---: | ---: |
| Off then on, same test process | 146.3 | 192.8 | 46.5 | +3.9 MiB |
| Fresh processes, on then off | 93.0 | 115.3 | 22.3 | +8.5 MiB |

Enabled windows completed four or five fresh samples each; disabled windows
completed none, and both retained advancing playback. The observed CPU difference
is about 2.2-4.6 percentage points of one core. Physical-footprint snapshot
differences were much smaller (-0.42/+0.19 MiB); resident snapshots include shared
and externally backed pages and are not allocation or peak-memory measurements.
Host load was high and variable, so these two comparisons are not a precise
device budget. They exclude startup, GPU/render-server cost, 4K/HDR conversion
and physical-device energy. They also do not attribute CPU cost between native
output materialization, private conversion and the bounded pixel scan.

Evidence is in `.build/performance/runs/4473a06724cc4e77810db2b220a10cb2`
(paired), `1553f84e12cf4fbbb5bbf43f105873d1` (isolated enabled), and
`f16d4d272b694863b4d93c161594da37` (isolated disabled).

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

### Saved custom-row queries and preview parity

`home-saved-row-queries` completes two 10,000-title sources through
`HomeContentPager`, verifies the descending result, reuses that inventory for
four ascending sort fields, and waits for a watched-state mutation to finish.
Every sample verifies all 20,000 items, no warm refetch, and at most three
concurrent source requests; all retained samples used 334 requests. This is synthetic
provider work, not real-server latency.

Isolated scenario runs, one warmup and five retained optimized samples per
platform, produced these medians:

| Metric | TV before | TV after | iPhone before | iPhone after |
| --- | ---: | ---: | ---: | ---: |
| Complete cold load | 1,006 ms | 586 ms | 1,099 ms | 624 ms |
| Four warm queries, total | 1,855 ms | 844 ms | 1,909 ms | 797 ms |
| Completed watch mutation | 450 ms | 226 ms | 473 ms | 209 ms |
| Whole workload wall time | 4,134 ms | 2,032 ms | 4,324 ms | 1,980 ms |
| Whole workload CPU time | 4,150 ms | 2,018 ms | 4,337 ms | 1,999 ms |
| Resident snapshot | 324.94 MiB | 376.81 MiB | 465.50 MiB | 423.22 MiB |
| Physical-footprint snapshot | 21.19 MiB | 21.16 MiB | 114.67 MiB | 115.80 MiB |

Baseline run IDs are `4f373adfc67c4fa58ace057ddb1e0ce6` (TV) and
`05651a29a9424ddab6df14960f9266ef` (iPhone). Isolated final candidates are
`908a1fc892264ef8ab8d33d7fd08f9b7` and `f2a59cc309c040d2946e68df7b22e210`.
Evidence lives under `.build/performance/runs/`. Comparisons are descriptive:
the fixture fingerprint changed to await the now-asynchronous mutation and
assert its result, alongside added regression cases. Both measurements include
completed mutation work, not just task submission. The data, sample protocol,
toolchain and per-platform simulator identity are unchanged. Resident snapshots
include reusable allocator pages; neither memory column is a peak-memory or
leak measurement. Complete source inventories still cost memory and network I/O.

The implementation skips unused filter records, normalizes names once, sorts
indices instead of large media values, and projects browse mutations off-main.
`home-rapid-row-queries` separately replaces/cancels four queries over 20,000
mixed movie/show and watched/resumable titles, verifies complete filtered results,
applies a mutation, and samples main-actor wake-up gaps. Five samples on each
platform had maximum gaps of 9.22 ms (TV) and 11.84 ms (iPhone), below the
workload's 100-ms regression ceiling. Runs `cf6c208adc684bb089c6dd31792a25e4`
and `58940988729c48b588c3c26b8216c586` retain that evidence. These gaps are
simulator scheduling observations, not physical-device frame timing.

Hosted `testCustomRowPreviewMatchesHomeGeometry` compares the actual Home row
against the editor's shared presentation across poster/landscape/featured,
framed/borderless, standard/compact density, and browse/no-browse headings.
It checks row height and rendered heading/title bounds on both platforms.
Editor loading, partial failure, query filtering and TV focus retain separate
hosted checks. No physical deployment is needed for these workloads.

#### Real-server saved-query acceptance

The explicit `home-live-{jellyfin,emby,plex,silo,combined}-queries` scenarios
use production providers against authorized live servers, not fixture data.
Run `a8ae80e732054058ac25803a894ec92a` passed all five scenarios with no skips,
one warmup and five retained optimized iPhone-simulator samples per scenario.
Each sample fully loads movie/TV libraries and, for Plex/Jellyfin/Emby, two
populated collections and two playlists. Combined uses all three providers.

| Source | Unique items | Source pages | Fresh inventory, median | Eight warm sorts, total median |
| --- | ---: | ---: | ---: | ---: |
| Jellyfin | 1,523 | 31 | 5,916 ms | 35.23 ms |
| Emby | 1,830 | 36 | 1,640 ms | 45.45 ms |
| Plex | 1,815 | 35 | 15,760 ms | 44.40 ms |
| Silo | 1,826 | 32 | 2,262 ms | 46.44 ms |
| Combined | 1,918 | 102 | 15,893 ms | 53.70 ms |

These are observed current-path timings, not a live-server before/after speedup.
Fresh means a new client/provider/pager; server caches are not cleared.
Discovery precedes the fresh-inventory timer. Warm sorts cover Name, Date Added,
Release Date and Runtime in both directions and perform no additional source-page
fetches. Media/watch filters, preview/grid agreement and cancelled-query
replacement also pass. Real metadata must include differing dates, years and
durations, so a missing-field fallback cannot masquerade as sorting coverage.
This caught Emby's omitted release fields: explicitly requesting `ProductionYear`
and `PremiereDate` restored release sorting instead of silently falling back to
names. The provider regression also covers explicit field-list overrides.

Warm projection is small at these library sizes, but complete first inventories
still take seconds, especially Plex and combined rows. This does **not** establish
an instant first sorted preview or physical-device UI smoothness. Median
per-sample maximum main-actor wake-up gaps were 3.5–5.0 ms; those are simulator
scheduling observations, not frame measurements. Results do not cover every server
version, network condition, provider, or larger library.

#### Selective networking and Jellyfin scheduling comparison

The non-UI adaptation of [#457](https://github.com/brandomoore/Plozz/pull/457)
was measured against main at `086c8d5365cb6e208638832f17dd919bf5d82aab`.
It retains shared foreground connection pools, independently cancellable
overlapping GETs, lightweight collection-existence queries, and four-slot
refilling collection/recency work. Stateful GETs, including Plex mutations and
authentication challenges, remain independent. Discovery cookie stores stay
isolated; finite Next Up paging retains the requested prefix and unlimited
requests remain exhaustive. No presentation changes are included.

The same optimized iPhone simulator, Xcode 27.1, live internal server accounts,
scenario order, one warmup and five retained samples were used in each run:
baseline `5ce17a52d9054235a819ece1aa806ece`, initial candidate
`4d885bb04cfe40f185c0ee3f4794e134`, and corrected candidate
`e5272f4a4a4d4df7b48e445b24237c28`. The correction prevents sharing state-changing
GETs; these live scenarios only read server data.

| Complete workload | Main median | Initial candidate | Corrected candidate | Corrected change |
| --- | ---: | ---: | ---: | ---: |
| Jellyfin Home load and refresh | 2,974 ms | 3,041 ms | 3,006 ms | +1.1% |
| Jellyfin saved-query acceptance | 3,538 ms | 3,689 ms | 3,473 ms | -1.8% |
| Plex saved-query acceptance | 5,640 ms | 5,573 ms | 5,697 ms | +1.0% |

| Workload | CPU median, main / initial / corrected | Physical footprint, main / corrected | RSS, main / corrected |
| --- | ---: | ---: | ---: |
| Jellyfin Home | 211 / 222 / 161 ms | 121.4 / 122.8 MiB | 256.5 / 258.1 MiB |
| Jellyfin queries | 718 / 744 / 659 ms | 170.2 / 172.5 MiB | 429.1 / 473.2 MiB |
| Plex queries | 921 / 918 / 884 ms | 180.3 / 180.2 MiB | 535.8 / 562.8 MiB |

There is **no demonstrated overall speedup** in these workloads. Machine load
varied substantially, server caches were not reset, and the two candidate runs
do not establish a stable CPU improvement. Eight warm sorts were slower in the
corrected run: Jellyfin 32.98 to 36.71 ms, Plex 40.24 to 47.29 ms. Their query
implementation is unchanged; these observations do not identify a cause.
Higher RSS is mostly accompanied by higher reusable memory, while physical
footprint is close to baseline; neither snapshot proves long-term retention.

All samples preserve 71 Home items, six libraries and four rows; Jellyfin queries
retain 1,526 items across 14 pages, Plex 1,820 across 16, with unchanged
date/year/runtime coverage and six sources each. Home still makes 20 cold and
19 refresh logical calls with zero duplicate calls. Collection probing removes
670 decoded response bytes per Home pass, not an entire request. Thus this live
case does not demonstrate a coalescing benefit. Separate controlled regressions
prove that overlapping identical reads use one transfer, cancellation remains
independent, interleaved writes are not dropped, and the four-slot windows refill
without changing membership or authoritative recency.

The strict comparator refuses these runs because added correctness tests change
the whole-Tests fingerprint. Scenario definitions, environments and the selected
live workload/probe sources are unchanged; the tables are descriptive evidence,
not a fingerprint-matched lab pass. The measured Home path loads data, not artwork
or rendered screens, and does not establish physical-device responsiveness.
The retained changes provide bounded work and explicit transport ownership, not
a claimed user-visible speed improvement at these library sizes.

#### Multi-server transport and Home scale acceptance

The November 17, 2026 follow-up tests the selective architecture above at
1, 3, 10 and 20 accounts, without importing presentation changes. HTTP sharing
now **defaults off**: audited Jellyfin/Emby and Plex Home/library reads opt
in at their request definitions. Authentication, mutations, playback actions,
item detail and unreviewed integrations remain independent. This makes future omissions
cost an extra read rather than suppressing an action; it is not a cache.

The first comparisons below describe the pre-main-review candidate
`4e75e8082`, which still shared item-detail reads. The **Pre-main freshness
correction** below supersedes that candidate's transfer counts and records
the final policy and its new measurements.

`MultiServerNetworkPerformanceTests` uses production Home aggregation, provider
mapping, address resolution and URLSession transport against independent
loopback origins. Navigation library discovery and two foreground detail readers
per healthy account overlap the Home load. Each ordinary origin has one movie
library, eight collection directories, 20 latest and 20 resume items, and 5 ms
response latency. These are deliberately collection-heavy controls, not a claim
that a typical single-server household has nine libraries.

- `home-network-{one,three,ten,twenty}` changes account count, retaining that
  per-account work.
- `home-network-large` keeps 20 accounts but raises collection directories to
  24 per account and movie overviews to 16 KiB: 500 libraries and about 14 MB
  of delivered response bodies.
- `home-network-adverse` adds 300 ms to every response from the first account
  and stops the last origin before loading, producing real connection refusal.
  The remaining 19 accounts must still contribute all their data.
- A normal regression cancels a 20-account load during two-second responses,
  requires prompt completion, and checks that cancellation stops admission
  before all accounts start.

Reproduce with an explicitly owned simulator:

```bash
python3 tools/performance.py run --platform iOS --sim-id "$PLOZZ_SIM_ID" \
  --scenario home-network-one home-network-three home-network-ten \
  home-network-twenty home-network-large home-network-adverse
```

The same six scenarios support `--platform tvOS`. Hosted loading controls are
`mobile-home-{one,three,ten}-server-startup-scroll` and
`mobile-home-multi-server-startup-scroll` (20 servers). Use the existing
`home-live-combined-queries` broker route for authorized real Plex, Jellyfin and
Emby data; it is a separate workload, not 20 real remote servers.

**Matched iPhone observations.** Pinned-main source
`086c8d5365cb6e208638832f17dd919bf5d82aab` was restored temporarily under a build
lease, then the candidate restored on exit. Control receipt source hashes were
checked against main, not inferred from the checkout's unchanged branch HEAD.
Both sides used Xcode 27.1, the same iPhone 17 Pro/iOS 26.2 simulator, optimized
build flags, selected workload/probe sources, one warmup and five retained
samples. Network receipts are `1c9a476b3c6b4c848600e15611bbb3b1` (main) and
`93394c1ff7cf4e97bf233f4f6933ab8d` (pre-review opt-in candidate).

| Controlled workload | Whole wall median, main / candidate | CPU median, main / candidate | Physical requests, main / candidate |
| --- | ---: | ---: | ---: |
| 1 server | 108.1 / 52.7 ms | 60.0 / 52.3 ms | 15 / 14 |
| 3 servers | 146.4 / 99.4 ms | 171.4 / 151.8 ms | 45 / 42 |
| 10 servers | 403.2 / 315.7 ms | 565.3 / 533.1 ms | 150 / 140 |
| 20 servers | 629.0 / 471.2 ms | 980.6 / 952.4 ms | 300 / 280 |
| 20, large responses/libraries | 1,328.1 / 983.7 ms | 1,831.4 / 1,652.3 ms | 620 / 600 |
| 20, slow plus unavailable | 2,831.9 / 1,000.4 ms | 906.4 / 810.6 ms | 285 / 266 |

The ordinary cases retain respectively 40/120/400/800 items and
9/27/90/180 libraries. The large case retains 800 items/500 libraries; adverse
retains 760 items/171 libraries and explicitly reports one failed account.
In that pre-review version, two overlapping detail readers use one transfer per
healthy account instead of two. Completed reads start a new transfer; cancellation and separate identities,
sessions, redirect policies and stateful GETs have real-transfer regressions.

At 20 servers, foreground details complete in 64.3 ms versus 87.6 ms, while
median peak active fixture handlers fall from 50 to 38. These are observed
handler counts, **not an app-global concurrency ceiling**: Home has separate
five-account lanes and collection discovery has a four-request per-provider
window. The results support keeping the refilling windows and safe sharing,
not adding another global scheduler.

First nonempty global content in this fixture is almost as late as all-content
completion: 458.4/458.7 ms for 20 healthy servers, 986.3/986.9 ms for adverse.
Global rows wait for account library discovery so music exclusion and ordering
remain correct; optional collection probes currently delay that discovery.
Server-specific rows have independent progressive publication. Separating
essential library classification from optional availability checks is a focused
future investigation, not justification to remove the filtering barrier.

Memory is not uniformly lower: median sampled physical footprint for the
20-server case is 237.8 versus 243.8 MiB. These are process samples containing
both clients and fixture servers, retained caches and allocator history, not
isolated per-account costs, exact peaks or leak evidence. CPU also includes
fixture construction/serving. Listeners send `Connection: close`, so this does
not measure connection-reuse benefits. Connection refusal is not a blackholed
server or sustained timeout test. Five samples do not establish p95 or
physical-device responsiveness.

**Real data and rendered Home.** Mixed live-query receipts
`2a3abd3a405b420cbbf736cbd00688de` / `17b63b0c79964082a2b736142e15374d`
retain 1,923 merged items, 18 sources and 46 pages, including identical
date/year/runtime coverage. Whole-workload medians are 14.774 / 15.048 seconds
(+1.9%), CPU 1.910 / 2.044 seconds, and cold inventory 6.707 / 7.049 seconds.
Eight warm sorts take 65.2 / 48.8 ms without refetching. This is **no demonstrated
overall real-server speedup**; caches were not reset and these sequential runs
do not establish a causal CPU change.

Hosted receipts `e74dbd640db84b8597a93af8bad828f4` /
`0739c1a1ca3c4c4682179e66d5bdac56` retain 2/6/20/40 rows,
40/120/400/800 items and 5/15/50/100 provider requests. Whole durations differ
by less than 0.4%; the prescribed scrolling cadence dominates them.
At 20 servers the candidate publishes its first row at 359 ms and all rows at
9.908 seconds; CPU is 4.897 versus 5.157 seconds. Median per-sample maximum
main-actor gaps are 78.2 versus 82.5 ms, not measured frame hitches.
The one-server fixture has zero vertical scroll distance: it is a loading
control, not evidence of scrolling performance.

The first hosted comparison showed a one-server CPU increase from 857 to
1,043 ms. A separate exact-fixture main/candidate repeat
(`676c5348b04e4218bf30f94547a9f40c` /
`ccc41fa2cd874d42806f9320c6aacfb8`) measured 806 / 751 ms with essentially
identical 9.929-second durations and passed the strict 15% comparator.
The initial increase did not reproduce; neither pair proves a UI improvement.
No presentation code was changed.

The larger main/candidate comparisons remain **descriptive**, not strict lab
passes: added correctness tests change the whole-Tests fingerprint, so the
comparator refuses them even though selected workloads and environment match.
The follow-up one-server pair retained identical complete fixtures and therefore
could use the strict comparator without altering receipts.

The pre-review candidate also completes all six network workloads on tvOS 26.2
(`2437b046e8184d63bd95080310d4af63`), retaining the same item, library, failure
and transfer counts; this is cross-platform acceptance, not a tvOS A/B speedup.
The six scoped correctness bundles pass 1,650 tests, with 36 skipped; enabled
performance/live runs above are separate evidence. These live and hosted
measurements were not repeated after the freshness correction below.

**Pre-main freshness correction.** Independent landing review found that item
detail also authorizes queued watch-state resets. A freshness check could join
an older pending detail response, miss newer server playback and permit a stale
reset. Jellyfin/Emby item detail and Plex single/batch metadata now explicitly
remain independent. Browse/discovery sharing is unchanged. There is no new
provider API or transport dependency on watch-state policy.

Three gated regressions use the real providers and URLSession transport with
`WatchStateReconciler`: hold an old response, record newer playback, then drain
the queued reset. Each requires a new transfer and no mutation before releasing
the old response. All three fail before the correction and pass afterward.
The four affected package bundles pass 1,638 tests with 36 skips; an independent
follow-up review closes the finding without further significant issues.

Final iPhone network receipt `e266dd800f834059bd4097b4ba979463` uses the same six
workloads, Xcode 27.1/iOS 26.2, one warmup and five measured samples. The fixture
now additionally requires two physical detail transfers per healthy account.
Against the same historical main control:

| Controlled workload | Wall median, main / final | CPU median, main / final | Physical request median, main / final |
| --- | ---: | ---: | ---: |
| 1 server | 108.1 / 52.3 ms | 60.0 / 52.7 ms | 15 / 15 |
| 3 servers | 146.4 / 104.2 ms | 171.4 / 168.7 ms | 45 / 45 |
| 10 servers | 403.2 / 307.2 ms | 565.3 / 542.7 ms | 150 / 159 |
| 20 servers | 629.0 / 508.8 ms | 980.6 / 1,018.4 ms | 300 / 300 |
| 20, large responses/libraries | 1,328.1 / 1,027.1 ms | 1,831.4 / 1,734.7 ms | 620 / 620 |
| 20, slow plus unavailable | 2,831.9 / 1,006.3 ms | 906.4 / 848.8 ms | 285 / 285 |

All samples retain the same items, libraries and explicit failures as main.
The ten-server candidate makes 150-159 requests across its samples; the others
match main's counts. The detail-transfer reduction is deliberately removed:
these controls now support lower elapsed time, not fewer requests or uniformly
lower CPU. As above, added regression coverage changes fixture fingerprints,
so these are descriptive historical comparisons, not strict comparator passes
or proof of a general live-server speedup.

#### Bounded full-inventory fetching

Full library/collection/playlist inventories now request 200 items per page and
use bounded lookahead, with three source-page loads active across one pager.
Ordinary scrolling and Home-feed limits are unchanged. Returned offsets, not
the requested page size or total-count hint, determine traversal and completion.
Short pages invalidate noncontiguous lookahead; errors and cancellation leave
the inventory uncommitted. No stream, artwork, sort, or playback metadata is
removed to achieve the speedup.

The same five live scenarios compared sequential 60-item reads
(`a8ae80e732054058ac25803a894ec92a`), sequential 200-item reads
(`ea1ffde2901944029aabd0c59687e85e`), and the selected three-request traversal
(`112e8dcd3d50423197888712b75a2dc1`). Every run used one warmup and five retained
optimized iPhone-simulator samples per scenario:

| Source | 60-item inventory median | Sequential 200-item median | Selected median | Reduction vs 60 | Source pages, before / after |
| --- | ---: | ---: | ---: | ---: | ---: |
| Jellyfin | 5,916 ms | 3,706 ms | 1,909 ms | 68% | 31 / 13 |
| Emby | 1,640 ms | 913 ms | 530 ms | 68% | 36 / 14 |
| Plex | 15,760 ms | 14,419 ms | 10,232 ms | 35% | 35 / 14 |
| Silo | 2,262 ms | 1,671 ms | 1,000 ms | 56% | 32 / 10 |
| Combined | 15,893 ms | 15,237 ms | 10,577 ms | 33% | 102 / 41 |

Item and metadata counts are unchanged. The selected run also compares complete
ordered `MediaItem` arrays against sequential 60-item requests during the
unmeasured warmup, including presentation and playback metadata. All five
scenarios pass with no skips. Eight warm sorts total 33-55 ms (median per
scenario), without page refetches. The new warmup parity assertion and request
diagnostics change the fixture fingerprint; these are descriptive comparisons
of the same measured query operations, not a fingerprint-matched lab verdict.
Server caches are not cleared, discovery remains outside the inventory timer,
and measurements are not physical-device frame timing.

The latency improvement has a CPU/memory tradeoff:

| Source | Whole-workload CPU median, before / after | Physical-footprint snapshot median, before / after |
| --- | ---: | ---: |
| Jellyfin | 854 / 754 ms | 177 / 216 MiB |
| Emby | 1,076 / 911 ms | 177 / 215 MiB |
| Plex | 4,713 / 6,904 ms | 179 / 197 MiB |
| Silo | 1,402 / 1,348 ms | 178 / 195 MiB |
| Combined | 6,159 / 8,116 ms | 174 / 202 MiB |

CPU includes discovery and assertions, not just inventory loading. Footprints
are post-work snapshots, not peaks, isolated per-provider allocation costs, or
leak evidence. Parallel responses can increase decoding contention and live
buffers; complete inventories still require memory proportional to membership.
Server CPU and physical-device energy use were not measured.

A two-request cap (`23feeb41352943759d6a8d7b39de9704`) also passed all five
scenarios. It reduced Plex/combined whole-workload CPU to 5,504/6,450 ms, but
increased inventory medians to 11,788/11,903 ms; Jellyfin/Emby/Silo rose to
2,667/750/1,136 ms. Three requests were retained for the best measured first-load
latency across all five scenarios, with the CPU tradeoff above kept explicit.
A 500-item sequential sweep (`bd389a706dde4b20a74b21e32e40f472`) failed an Emby
response check, although a later instrumented Emby-only run passed; its cause
was not established and the failed sweep is excluded from speedup claims.

Regression coverage verifies preview-to-inventory continuation, server page
caps and changing strides, absent/estimated totals, visibility filtering,
the shared concurrency ceiling, duplicate playback sources, cancellation,
failed-page retries, malformed responses, and static/session loader limits.

#### Plex list/detail investigation: deferred enrichment not adopted

The opt-in `home-live-{plex,combined}-{eager,deferred}-inventory` experiments
compare full upfront metadata with lightweight Plex library lists followed by
bounded detail batches. These are **test-only prototypes**; production loading
still uses the full-metadata path above.

Primary-source research identified list/detail separation in
[Plezy's list requests](https://github.com/edde746/plezy/blob/847842c3d075b56d686409850e12fa1cca0b19d9/lib/services/plex_client.dart#L1132-L1156)
and [detail requests](https://github.com/edde746/plezy/blob/847842c3d075b56d686409850e12fa1cca0b19d9/lib/services/plex_client.dart#L1262-L1317),
[Plex for Kodi's explicit reload](https://github.com/plexinc/plex-for-kodi/blob/97191f248a20223bb93296789c010ff2204a9c76/lib/_included_packages/plexnet/plexobjects.py#L194-L247),
and [Python PlexAPI's partial objects](https://github.com/pushingkarmaorg/python-plexapi/blob/aa5bf6742eb806bbbebd2b65dee9fc47a81d92e1/plexapi/base.py#L650-L706).
These support investigating the approach, not adopting their UX or assuming
equivalent metadata. No third-party implementation was copied.

Bounded read-only HTTP probes against the internal Plex server returned the
same 200 movie identities in about 1.80 seconds with `includeElements=Stream`
versus 0.31 seconds without it. Decoded response sizes were 1,460,451 versus
501,666 bytes. The enriched response contained 3,334 streams; the lean response
contained none. `includeStreams=1`, including with `includeMedia=1`, did not
restore streams on this list endpoint. XML with stream enrichment took 1.82
seconds, so changing serialization was not a demonstrated shortcut.

The metadata endpoint returned matching complete `Media` arrays for those 200
records. A single batch took 1.88 seconds and 3,517,180 decoded bytes; four
50-item batches took 2.05-2.11 seconds sequentially or 1.04 seconds with three
workers. Those figures exclude the initial lean-list request and are transport
observations, not end-to-end app speedups.

The Swift experiment uses production providers, source paging, global merge,
query comparators, and metadata mapping. Both strategies discover the same
movie/TV libraries, two collections, and two playlists per provider. The
deferred candidate changes only Plex library lists; collection and playlist
representations remain unchanged. After sorting the complete membership, it
hydrates only the selected 20-card window, excluding series/season containers
that have no playable media in these library sources. Detail batches are capped
at 50 native IDs and three concurrent requests. All hydration finishes inside
the measured operation, rather than being submitted as unmeasured background
work.

Only the library records' technical metadata and versions are replaced.
List-specific artwork, watch state, identity, and sort fields are retained,
and shared merging reconstructs source/version references. The warmup compares
complete displayed `MediaItem` values against fresh eager reads for the first
20 cards, the next 180 cards, and all eight sorts. It also checks complete
ordered identity parity for every sort. Cached replay is checked in each sample.
This does not exercise rendered grids, watch mutations, profile switching,
failure recovery, all possible filters, or complete-library scrolling.

Run `21598e04db2e46d18dc2005bdbe6ea8a` passed all four cases, without skips:
Plex eager/deferred and combined eager/deferred (Plex, Jellyfin, Emby).
Each case used one warmup and five retained optimized iPhone-simulator samples.
The 1,815-item Plex and 1,918-item combined inventories and displayed metadata
passed the checks above. This is a within-run strategy comparison with the same
source fingerprint, not a comparison of the earlier inventory-only workload:

| Workload, median | Plex eager | Plex deferred | Combined eager | Combined deferred |
| --- | ---: | ---: | ---: | ---: |
| First 20 fully enriched cards | 11,114 ms | 2,192 ms | 11,092 ms | 4,749 ms |
| Next 180 fully enriched cards | 51 ms | 2,763 ms | 83 ms | 7,100 ms |
| Eight sort changes, fully enriched first windows | 38 ms | 2,009 ms | 46 ms | 5,226 ms |
| Slowest sort within a sample | 6 ms | 417 ms | 9 ms | 867 ms |
| Cached initial-window replay | 5 ms | 11 ms | 9 ms | 20 ms |
| Whole workload, including discovery | 11,413 ms | 7,189 ms | 20,321 ms | 25,649 ms |
| Whole-workload CPU | 6,776 ms | 2,805 ms | 7,850 ms | 11,932 ms |
| Instrumented HTTP requests, including discovery | 21 | 36 | 95 | 110 |
| Decoded HTTP response bytes, including discovery | 10,586,314 | 8,981,541 | 17,739,962 | 15,947,258 |
| Physical-footprint snapshot | 207 MiB | 190 MiB | 205 MiB | 191 MiB |

First-display timing excludes discovery, matching the earlier inventory timer;
request/byte totals and whole-workload CPU include it. Footprints are snapshots
in a shared test process, not isolated retained-memory or peak-allocation
measurements. Server caches were not cleared. Detail fetching and remerging
are both charged to the deferred path; their individual CPU costs were not
profiled. Instrumented request counts cover provider transport, not broker,
authentication, or separate address-verification traffic. The experiment's
deferred projection remerges the inventory after new metadata arrives; this
is part of this prototype's cost, not a lower bound for every deferred design.

An earlier 60-card-lookahead candidate
(`6a11f9ba3a4f491089f7b22aab5f7611`) completed the combined cases but its full
sweep failed on Plex request timeouts, first on a metadata batch and then on
library discovery. A subsequent bounded identity request succeeded; the timeout
cause was not established. Its completed combined cases took 4,999 ms for first
display, 7,177 ms for the next 180 cards, and 8,724 ms for eight sorts. Removing
speculative windows and unnecessary container hydration improved the candidate,
but did not eliminate its interaction regressions. Earlier rejected experiments
also exposed a reference-fixture locality mismatch and changed collection/playlist
metadata. None of those failed sweeps supplies the final table's results.

**Decision:** do not adopt this deferred strategy. Faster initial display moves
substantial work into scrolling and sorting. Plex-only total time and CPU improve,
and both workloads transfer fewer bytes, but both make more requests, and combined
total time and CPU regress. This does not meet the requirement for an improvement
across normal use. The existing warm-query behavior is retained. Any future
candidate must measure first display *and* subsequent interaction readiness with
complete metadata; a smaller inventory payload or another client's design is
not sufficient.

### Plex full-metadata decoding: avoid errors for absent fields

The production improvement keeps eager, complete metadata rather than adopting
the deferred prototype above. Plex's lenient scalar helpers previously tried
two or three throwing decodes even when the key was absent. Sparse audio,
video, and subtitle records multiply those unsuccessful attempts across the
library. Each helper now checks `contains` first; present fields follow exactly
the same conversion order. Requests, concurrency, pagination, merging, and
query publication are unchanged. The shared provider applies this on both
tvOS and iOS, including Home rows, previews, grids, and detail reads.

The same real-server `home-live-{plex,combined}-eager-inventory` workloads ran
in baseline/candidate/restored-baseline order, each with one warmup and five
retained optimized iPhone-simulator samples. All six case executions passed.
Fresh providers and pagers were created for each sample; server caches were
not cleared. Restoring the old decoder after the candidate reproduced its
CPU cost and slower initial load, reducing the likelihood that server cache
warming explains the improvement.

| Median | Baseline | Presence fast path | Restored baseline |
| --- | ---: | ---: | ---: |
| Plex first 20 fully enriched cards | 11,602 ms | 7,266 ms | 11,935 ms |
| Plex whole-workload CPU | 6,864 ms | 716 ms | 6,954 ms |
| Plex whole-workload elapsed | 11,940 ms | 7,606 ms | 12,270 ms |
| Combined first 20 fully enriched cards | 12,292 ms | 8,715 ms | 11,921 ms |
| Combined whole-workload CPU | 8,639 ms | 2,245 ms | 8,140 ms |
| Combined whole-workload elapsed | 21,058 ms | 17,327 ms | 21,051 ms |
| Plex next 180 cards | 47 ms | 46 ms | 55 ms |
| Combined next 180 cards | 96 ms | 80 ms | 90 ms |
| Plex eight sorts | 36 ms | 34 ms | 39 ms |
| Combined eight sorts | 53 ms | 42 ms | 52 ms |
| Plex slowest sort within a sample | 5.6 ms | 5.4 ms | 6.1 ms |
| Combined slowest sort within a sample | 10.8 ms | 8.7 ms | 9.6 ms |

First-display time excludes discovery; whole-workload CPU and elapsed time
include it. Both strategies retain all metadata before publication, so no
network requests are deferred into sorting or later card access. Instrumented
requests remained 21 for Plex and 95 for combined, with 1,815 and 1,918 unique
items respectively. Baseline/candidate response-byte medians were unchanged
at 10,586,327 and 17,739,975; the repeated Plex control differed by 154 bytes.
No payload-reduction claim is made. Memory snapshots varied between runs and
are not evidence of a retained-memory improvement.

The existing warmup checks full displayed `MediaItem` parity for the first 20,
next 180, and eight sorted first windows against fresh eager reads, plus complete
ordered identity parity for each sort. Cached replay is checked every sample.
The provider regression suite passed 456 tests without failures or skips,
including new absent/null/unsupported-field, scalar-conversion, and sparse
subtitle cases. This is real-server simulator evidence, not rendered-frame or
physical-device timing, and does not establish a lower bound for further work.

Evidence:

- Baseline: `65950557ea9d4850807cfbcdf1dd9160`.
- Candidate: `44982dad4b1649f99255453211219d33`.
- Restored baseline: `d95862f99c9341ec8ba0227b8dc06ba2`.
- The matched-fixture restored-control/candidate comparison
  `88efaddc843b4e528787affe2b35c51b` passed the runner's regression budgets.
- Provider tests: `.build/private-no-clean-tests/78f20b9938ce4c60ac0241b8c69c3b8a`.

### Rolling full-inventory requests and small library bootstrap

The next production change removes the three-page batch barrier without raising
the three-request ceiling. Requests refill as responses arrive, with at most six
pending-plus-buffered pages per source and three active sources. Responses are
consumed only in actual cursor order. A fresh library first requests one fully
enriched item to discover continuation/count earlier; remaining pages request
200 items. Changed strides drain the bounded speculative window and restart at
the actual offset. Observed terminal pages suppress unnecessary lookahead but
cannot truncate an authoritative continuation. Ordinary incremental browsing
and sequential 60-item Home feeds are unchanged.

The selected candidate (`34214c346e904e0db9a4824a7563925f`) and a subsequent
restored original-loader control (`67298fdc86c541ab93899ba11bcfd85b`) both retain
the preceding decoder optimization. Each uses one warmup and five retained
optimized iPhone-simulator samples against real servers:

| Median | Original loader | Rolling loader |
| --- | ---: | ---: |
| Plex first 20 fully enriched cards | 6,858 ms | 5,922 ms |
| Combined first 20 fully enriched cards | 8,331 ms | 7,624 ms |
| Plex next 180 cards | 57.6 ms | 62.3 ms |
| Combined next 180 cards | 91.8 ms | 83.9 ms |
| Plex eight sorts | 45.6 ms | 50.6 ms |
| Combined eight sorts | 51.7 ms | 46.8 ms |
| Plex whole-workload CPU | 665 ms | 719 ms |
| Combined whole-workload CPU | 1,978 ms | 1,929 ms |
| Plex instrumented requests | 21 | 24 |
| Combined instrumented requests | 95 | 101 |

This is not an improvement in every metric. Plex warm projections and CPU rose
slightly in this pair; no network work moved into those interactions. Plex
response bytes rose by 946 and combined by 1,065. The extra initial request
trades a small amount of HTTP work for earlier parallel loading. Buffer bounds
increase from three to six pages per source; complete inventories still occupy
memory proportional to library size. Snapshot memory is not a peak-memory or
leak measurement. Comparison `c49e23e148864bfd8cf63da20425d3d8` passed the
runner's wall/CPU regression budgets; first-display and query counters are
reported separately, not enforced by those budgets.

A separate five-provider saved-query sweep (`a0a73c2d88a34f9bbd4ba8b26752b4af`)
and subsequent restored original-loader control
(`8436fe196e2746559b70e46758761cdf`) passed all cases without skips:

| Source | Complete items | Original fresh inventory | Rolling fresh inventory | Original / rolling eight warm queries |
| --- | ---: | ---: | ---: | ---: |
| Jellyfin | 1,523 | 2,052 ms | 1,749 ms | 34.7 / 42.3 ms |
| Emby | 1,830 | 651 ms | 620 ms | 47.0 / 49.3 ms |
| Plex | 1,815 | 6,838 ms | 5,513 ms | 49.4 / 51.7 ms |
| Silo | 1,826 | 1,127 ms | 1,011 ms | 53.5 / 54.6 ms |
| Combined | 1,918 | 8,113 ms | 7,685 ms | 65.2 / 59.5 ms |

Every case verifies complete ordered `MediaItem` parity against sequential
60-item reads, eight sorts, media/watch filters, preview/grid query agreement,
cancelled-query replacement, and no warm page refetches. Source-page counts
change from 13/14/14/10/41 to 14/16/16/12/46 respectively. Whole-workload CPU
increases from 651/837/876/1,442/2,258 ms to 712/874/912/1,489/2,301 ms.
Comparison `b6a1c783870e40428a72cecb231299ca` passed wall/CPU budgets.
These are separate runs with fresh clients/pagers, not cleared server caches.
Discovery is excluded from fresh-inventory timing and included in workload
CPU/wall time. This is simulator/network evidence, not rendered-frame,
physical-device, concurrent-playback, or arbitrary-library-size evidence.

**Sub-three-second Plex loading was not achieved.** Six-request experiments
reached about 5.1 seconds with 200-item pages and 4.9 seconds with 100-item pages,
but increased server burst pressure and individual request durations; they are
not adopted without interactive-contention evidence. Smaller pages alone did
not improve three-worker transport throughput. Optional Stream flags retained
movie metadata but did not demonstrate a speedup; series requests still failed
and used the existing lean fallback. No production stream metadata was removed.
The test-only HTTP wrapper now retains bounded, secret-safe timing attachments
containing request category, page offset/limit, elapsed times, byte count, and
success status, not URLs, account identities, titles, tokens, or payloads.

Regression coverage includes rolling refill around delayed pages, capped and
changing strides, tiny libraries, missing/inaccurate totals, global concurrency,
full-item retention, cancellation, and retryable failures. CoreModelsTests and
FeatureHomeCoreTests passed 3,758 tests with 11 skips
(`fa04254110934e0a84646ad9274714a0`); the final bootstrap edge-case addition and
Home tests passed separately (`cd8c62325c854f858243263abfbb8ace`).

### Final live-inventory attribution

The bounded follow-up retained the rolling loader unchanged. With authorized
live-provider credentials, set `TEST_RUNNER_PLOZZ_LIVE_PAGE_ATTRIBUTION=1` when
running the saved-query scenarios. The test reads
`PLOZZ_LIVE_PAGE_ATTRIBUTION=1` and attaches three serial first-page observations
per source during the discarded warmup only. Sources are indexed in discovery
order: movie library, series library, two collections, and two playlists.
Attachments contain counts, bytes, and timings, never source IDs or payloads.
Repeated pages must preserve full ordered metadata.

The helper reuses existing request/decode diagnostics, combining their disjoint
fast and slow completion buffers and rejecting dropped or unfinished spans.
Request sums describe serial page calls, not parallel inventory wall time.
Residuals include mapping, pagination, scheduling, and instrumentation overhead;
they are not pure mapping CPU measurements. Millisecond diagnostics quantize
short operations. Plex uses its own decoder without the shared decode span, so
its decode count is zero and decoding remains in the residual, not absent.

Run `a5172fcd1a9e4deebd0de2f89c6d02db` used Xcode 27.1, the optimized iPhone
simulator lane, and real servers. All three saved-query scenarios passed without
skips, including complete metadata/order parity and warm-query checks. Median
first-page attribution for 200 movies:

| Provider | Page wall | HTTP request | Shared Swift decode | Remaining client work |
| --- | ---: | ---: | ---: | ---: |
| Jellyfin | 430 ms | 408 ms | 3 ms | 19 ms |
| Emby | 74 ms | 52 ms | 2 ms | 20 ms |
| Plex | 2,069 ms | 2,010 ms | Not separately instrumented | 52 ms, including decode |

Each column is a median of its own observations, so columns need not sum
exactly. These representative pages are not identical cross-provider
catalogs. The series libraries especially differ: Jellyfin's selected library
returned one series, whereas Emby and Plex returned 200. This is evidence about
these configured servers, not an inherent provider performance ranking.

A separate bounded, sequential transport probe used production-shaped movie
queries with gzip and retained no authenticated payloads. Median request-start
to response-header times were 483/91/1,875 ms for Jellyfin/Emby/Plex; body reads
were 15/6/24 ms. Compressed payloads were approximately 117/43/211 KB.
Header waiting includes connection/network overhead and server processing; it
does not identify a server database or CPU bottleneck. Decompression was under
one millisecond. Python JSON parsing in that probe is not Swift decode evidence.

Two count/no-count/no-count/count sequences per Jellyfin/Emby library preserved
the exact returned item arrays. Movie header medians with/without totals were
483/453 ms for Jellyfin and 91/60 ms for Emby, with overlapping, noisy samples.
This did not establish a worthwhile complete-inventory improvement. Removing
totals also requires a deliberate continuation-contract change, not simply
dropping a query parameter. Plex series pages confirmed the existing enriched
HTTP 500 followed by a successful lean request; the typically 14-18 ms failed
request was small relative to enriched movie response waiting.

The five retained complete-inventory samples in the app run had medians of
1.79 seconds for Jellyfin, 0.63 seconds for Emby, and 5.68 seconds for Plex.
These are fresh client inventories, not cleared server caches or physical-device
results, and the changed toolchain means this is not a before/after comparison
against the preceding runs. No additional production optimization is claimed.
This round stops here: request waiting dominates the remaining Plex cost, and
neither increased concurrency, deferred metadata, nor speculative pagination
changes are justified by this attribution. Sub-three-second complete Plex
inventory remains unmet; existing full metadata and warm interaction behavior
are preserved.

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

For metadata work during row layout, `home-series-artwork-identity` runs the
production `ContinueWatchingArtworkSource.identity` pipeline over 408 synthetic
movie/episode sources, four complete passes per sample. It covers classification,
series-ID promotion, metadata cache keys and provider aliases without networking
or rendering. Every sample verifies all 1,632 identities and their complete
174,592-byte output. It is not a frame-rate or whole-navigation benchmark.

A symbolicated physical tvOS hang reached this pipeline from `MediaRowView`
inside Showcase host fitting. Each namespace lookup rebuilt the entire normalized
provider-ID dictionary, including per-character strings for ordinary ASCII keys.
The lookup now selects the highest-priority valid alias directly; ASCII
normalization uses bytes while other spellings keep the original Unicode path.
Alias priority, whitespace handling and normalized-key collisions remain covered
by `ProviderIDNamespaceTests`. There is no cache to invalidate, truncated metadata,
new background task or change to native focus/layout ownership.

On an Apple TV 4K simulator running tvOS 26.2, optimized Debug, one warmup and
five samples, the final matched pair measured:

| Workload | Original median CPU | Optimized median CPU |
| --- | ---: | ---: |
| 1,632 artwork identities | 294.179 ms | 60.621 ms |
| Twelve settled artwork publications | 28.981 ms | 26.280 ms |
| Cold Showcase graph, warm images | 382.900 ms | 375.129 ms |
| Duplicate artwork reports | 5.140 ms | 4.832 ms |

Baseline `4a3474bf702e449f9d5c45dbeca32b66` and candidate
`230fc391efc047d6933f3112914339cc` have identical runner, fixtures, scenarios and
environment; comparison `6c2ea2bbb07443bfb4552cbc932a9a0c` was within budget.
Identity CPU fell about 79%, consistently reaching 60–63 ms across three
candidate runs versus 289–294 ms for original-code runs. An exploratory
lookup-only candidate measured 225 ms before the ASCII path was added.

Do not infer an artwork speedup from the small control differences. Earlier
comparisons flagged artwork CPU regressions, and an original-code A/A control
also flagged artwork/duplicate regressions
(`6bbd69ba038b458e84d1cdbc4a7caa0a`); shared-host load and outer layout counts
varied. All complete runs retained the same publication, row-fitting, card-input
and duplicate-suppression results. Synthetic native Home and horizontal navigation
profiles completed, but neither reproduces the complete live-server session.
The live endpoint rejected public API access before authentication, so this
evidence does not establish physical-device responsiveness or network improvement.

For Showcase gutter discovery, `home-focus-discovery` performs 24 actual native
focus changes across eight production rows of 75 cards, including horizontal
movement and row changes. It counts queried rows and native focus containers,
then checks title updates, focus retention and visible overscan artwork.
It does not measure network loading, screen frame rate or device hang duration.

A later symbolicated physical hang reached `UIFocusSystem.didUpdateNotification`
and `FocusHeroMotionSurface.Controller.updateRowEntryGuides`, inside UIKit's
focus-container traversal. All other rows previously searched their full
horizontal viewport on every move. Discovery now visits only the two possible
neighbor rows (one at the boundary), and guide setters skip unchanged values.
The same simulator/toolchain and optimized Debug settings above measured:

| 24 native focus moves | Original median | Adjacent-row median |
| --- | ---: | ---: |
| CPU | 131.878 ms | 63.006 ms |
| Wall time | 131.668 ms | 62.852 ms |
| Row scans | 168 | 42 |
| Container queries | 14,196 | 4,476 |

Baseline `a4f4c31b81914c9e94a8c6bc4dfd831c`, candidate
`1a82457dcdb943bf8c3a9ebaf0d9be70`, and comparison
`7e39ba6782e6414db84db8fd96f2b30b` preserve matching fixtures and environment.
The roughly 52% CPU reduction is specific to this workload, not a claim that
whole-app navigation or the physical hang duration improved by that amount.
Separate regression coverage verifies that discovery follows row reordering.

The same device diagnostics also captured synchronous `SecItemCopyMatching`
from automatic sign-in publication. Channel capture and account-verification
reads now run on a serial utility queue. `ProviderCredentialSyncTests` holds
state/ownership reads behind a gate while the main actor continues, verifies
unchanged owned output for Jellyfin and Plex, and rejects cancellation and
sign-in/authorization changes during the read. This proves executor placement
and stale-result rejection, not a simulated Keychain service latency improvement.
Neither change alters foreground-refresh timing or disables background features.
The final AppRuntime run passed 516 tests with 25 tests skipped and no
failures. Eight native Showcase remote controls passed, covering short rows
under all three navigation styles, both focus appearances, pinned return,
vertical reversals and delayed initial loading across background/foreground.
The hosted adjacency/reordering regression also passed. These remain simulator
results; the new changes have not yet been installed or verified on hardware.

For card-activation and menu stalls, `mobile-home-card-routing` updates 24 real
mobile Home cards against a four-source identity index and counts source
resolutions without activating a card. Detail routing belongs in the presented
destination, and direct-play routing in the action, so browsing should resolve
zero sources. `source-menu-version-presentation` builds 1,024 production version
rows per sample on either platform and compares every title and supplemental
fact with the original output.

`detail-selection-legacy` and `detail-selection-resolved` compare direct
composition of existing selection primitives with the shared resolver in the
same binary. Each sample completes 1,024 explicit account/version selections,
8,192 version entries, and 1,024 exact provider account/item/file handoffs.
The control is not a historical binary or whole-detail startup replay; automatic
selection and decoding are outside this workload. Initial TV medians were
91.991 / 92.023 ms wall and 91.993 / 92.023 ms CPU; mobile medians were
93.012 / 94.819 ms wall and 93.014 / 94.820 ms CPU. Both had zero median resident
delta. This supports a maintenance consolidation, not a selection speedup.
Runs: TV `583c51a43b9c4d26a7fde1c315b51337`, mobile
`952207f098be4b2093109509fd5874c6`.

### Single-input mobile library rows

The architecture pilot first exercised the existing reuse paths. TV metadata
updates rebuilt zero card inputs; artwork updates performed zero row-content
size/placement/fit calls or card-input builds. No TV sizing cache was added.
Mobile metadata row samples had card-input counts `[20, 0, 0, 0, 0]`; they were
not universally zero. Mobile publication completed eight refreshes, 24 synthetic
provider requests, eight save/publication callbacks, and zero observed state
notifications. Save callbacks are fixture counters, not measured disk writes.

A separate bounded process sample of mobile startup found nested derived
equality for `HomePresentationRow.Source`, `HomeLibrarySectionGroup.Row`, and
`LibrarySection`. Source inspection confirmed that the mobile library view
compared the row inside `presentation` and then compared `row` again.
The view now stores a choice and one complete row; browsing reconstructs the
presentation from those inputs. No metadata is omitted, no identity-only
shortcut or cache is introduced, and settings remain observable.

`mobile-home-library-row-comparison` measures 256 production-view comparisons
of independently decoded equal snapshots containing 75 items and 2,400 credits.
A positive control changes the final person's biography and requires inequality.
The matched baseline already used the narrowed inputs and final fixtures but
retained the original double comparison. The candidate changed only equality
to compare the choice and complete row once.

| iPhone 17 Pro / iOS 26.2, optimized simulator | Before median | After median |
| --- | ---: | ---: |
| 256 comparisons, wall | 47.330 ms | 23.844 ms |
| 256 comparisons, CPU | 47.380 ms | 23.853 ms |
| Twenty-provider startup scroll, wall | 10,726.093 ms | 10,758.859 ms |
| Twenty-provider startup scroll, CPU | 4,850.425 ms | 4,895.829 ms |

Baseline `f91582171a1d434cb13630abb590dc7e` and candidate
`eebdd8334429488eb2646c13c589929e` used the same simulator, Xcode 27.2,
SDK 27.2, fixtures and runner. Comparison
`4e82be435d094def840f73f4c014936a` was within the existing budget.
The isolated comparison cost fell about 50%; whole-startup speed did not
improve. Both completed 40 rows, 800 items, 100 requests, and 25 scroll targets,
24 while loading, with 38 rows completing while scrolling. Median per-sample
maximum main-actor wake-up gap was 58.315 / 67.460 ms; ranges were
52.166-70.284 / 56.497-75.086 ms. There is no demonstrated scheduling-gap,
FPS, or physical-device improvement.

Comparison samples had zero resident delta. Startup median resident snapshots
were 876,101,632 / 776,077,312 bytes, while median window deltas were
26,509,312 / 33,603,584 bytes. These variable process snapshots do not establish
reduced peak memory, retained memory, or leaks. No network, persistence, or
cancellation owner changed.

Attribution-only runs were TV navigation `fcd0074d13fc42cda5618de160c3ca90`
and mobile startup `483ada1d9b7f494a84748ba017567bb3`. The mobile 75-second,
5-ms process sample retained symbolized frames but ended without a binary-image
table after host exit. Inclusive stack observations include waiting, not CPU
milliseconds or frame latency. Its instrumented timings are not comparison
evidence. The raw sample and verified simulator/process identity are retained
with local session evidence; all benchmark results remain under the run IDs
above.

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
