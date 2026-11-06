# Playback Engine Architecture

Plozz uses two playback engines, automatically selected per-item based on
container, codecs, and subtitle requirements. The goal is maximum format coverage
with the best possible quality (Dolby Vision, spatial audio, full-timeline seek).

## Media-share Blu-ray folders

Recognized `BDMV` folders appear as one movie in indexed libraries and normal
folder browsing, rather than one movie per `.m2ts` clip. Recognition requires an
`index.bdmv` file and `PLAYLIST`/`STREAM` directories, matched case-insensitively.
The containing movie folder supplies the title and local metadata. A source
root inside `BDMV` is supported. Standalone transport-stream files and explicit
**Browse Files** navigation retain their ordinary behavior.

All share transports use the same discovery and playback path: SMB, SFTP, FTP,
FTPS, HTTP and HTTPS/WebDAV. Play builds a bounded, credential-free manifest
(at most 4,096 files), preserving each file's representation identity. Plozzigen
selects the main playlist and plays its ordered clips; it does not select the
largest stream or concatenate every file. Files open lazily through the existing
transport resolver. One admission lease spans playback, independent readers
share teardown ownership, and cancellation interrupts pending file opens.

Folder downloads, external-player handoff and index-file warming are unsupported;
the index is never treated as an original video. This adds no decryption or
multi-angle playback. Missing, changed or unsupported disc
contents follow the playback error path.

### Original disc navigation

The profile's **Disc playback** setting chooses **Play video** (the migration
default) or **Open disc menu**. The detail Play button follows that preference;
its hold menu offers the opposite action for this play only. Direct playback
does not create a navigation session and keeps its normal resume/watch behavior.

Menu navigation supports HDMV and a bundled BD-J interpreter in media-share BDMV folders.
`DiscNavigation` statically links pinned libbluray 1.5.0 without optional
decryption loaders. It drives original navigation and graphics while the existing
Plozzigen adapter plays the selected playlist or its bounded play items. Separate transport cursors
retain the same account, credential revision, file identity and root allowlist.
The normal app uses the production transport resolver, not the lab's HTTP relay.
BD-J uses the pinned OpenJDK Zero interpreter and libbluray's offscreen AWT.
Java graphics can open before any video is selected; authored playback then uses
the same playlist and renderer path as HDMV. Java callbacks copy and composite
their graphics before publishing on the main thread. Only one Java disc session
can own the process-wide JVM, including while an old session is closing.

Detail inspection recognizes 0100, 0200, 0240 and 0300 index layouts, including
declared BD-J top menus. Only an explicitly absent or unsupported menu is hidden.
Unfamiliar, damaged or temporarily unreadable metadata stays unknown,
not permanently unsupported. A conservative MovieObject inspection recognizes
the tested region-register/warning-loop pattern and selects A, B or C before
first play; other programs use the device-region fallback. Manual region retries
affect only the current session, not the profile preference.

Missing opening clips permit one top-menu attempt, respecting disc restrictions.
Opening a menu retains that intent through first-play language/region setup.
Once navigation exposes an interactive surface or leaves first play, it requests
the top menu when authored menu-call restrictions permit, rather than following
startup directly into a feature. Reaching the top menu consumes this request;
subsequent explicit choices are not redirected.
Startup and playlist transitions have bounded deadlines. Menu failures remain
visible with Retry, Play video, region retry and Close actions; they never trigger
automatic main-title playback, cross-source failover or server transcoding.
Directional input is ignored when there is no active authored menu.
Finite and infinite stills at the end of a playlist retain the rendered frame.
User pause suspends a finite still's timer; play resumes that timer rather than
bypassing the authored hold. Infinite stills wait for navigation input.
Playlists with stills between play items use individually opened clips and their
authored source-time intervals. Native playback establishes the actual consumer
timeline before seeking and starting, and AVPlayer's renderer-owned endpoint
holds the frame without a sampled-clock pause. Repeated clips retain separate
play-item identities. Software-rendered formats cannot yet use these intervals;
that limitation is reported instead of skipping the pause or playing outside it.
Stopping a session cancels its transport and waits up to five seconds for its
native navigation queue. If shutdown is still pending, the queue keeps its
native owner alive while the player can leave or start direct playback. This
deadline does not terminate Java threads or free objects beneath an active call.

For this initial integration, menu sessions deliberately do not update watched
or resume state: a menu's playlist clock does not identify a library movie,
especially on multi-feature discs. Direct playback retains normal tracking.
Authored primary audio/subtitle selections map playlist stream identities to
the engine's actual MPEG-TS PIDs, never its track-list order. Player selections
also update the disc VM and respect its operation restrictions. Missing,
ambiguous or separate-subpath tracks remain explicitly unavailable. When two
decoder representations share a PID (such as TrueHD and its AC-3 companion),
the already-active matching representation satisfies the disc selection.
Recovered track warnings clear independently of other track or navigation notices.
Disc choices drive the subtitle overlay without changing remembered series preferences.
The engine exposes menu state only for an active menu request; ordinary playback
must still apply its normal subtitle defaults and remembered track selections.
Arbitrary-disc compatibility and distribution readiness are not established.
Menu graphics cannot end an in-flight video-load state; authored video transitions
retain a loading indicator until their load completes. Returning from a disc menu
creates a fresh transport focus owner and re-arms the controls' idle timeout;
retired hosts cannot keep their previous focus/panel state or idle timer.
Disc menu / Disc videos lives in the existing transport button row on TV and
mobile, not in a separate floating action. It follows the row's focus and
visibility lifecycle, so it cannot take the video surface's initial focus.
The TV disc navigation surface uses a native Select button; directional input
only sends the corresponding disc arrow key, not an activation.
Mobile menu navigation centers its glass arrow/Select group separately from the
disc action and keeps the shell's single Close action. Select uses a circle.
Navigation controls retain their layout across temporary graphics clears and
disable input until the menu is visible again. Pending menu requests keep normal
transport chrome hidden, and disc transport does not reveal itself merely because
its view was recreated during a scene change.
Taps inside the aspect-fitted menu image are mapped
to disc pixels and sent as native pointer selection/activation; taps in the
letterbox area never activate a previously selected button. Arrow and Select
controls remain available for discs that do not implement pointer input.
Java graphics callbacks drain temporary Cocoa objects after each event, including
on long-lived Java drawing threads. Composition failures record the failing stage,
canvas dimensions, plane count and measured process footprint in the playback
trace; these diagnostics do not by themselves establish the allocation's cause.
BD-J networking and durable disc storage are disabled. libbluray still creates
temporary binding-unit and persistent-storage directories for disc applications;
their arbitrary writes do not yet have a complete quota. The JVM has bounded
heap, metaspace and direct-memory allocations; source resource inventories and
expanded JAR entries/bytes are bounded, and archive paths cannot escape their
mount. These limits are not process isolation: Java CPU use, thread creation and
uncooperative Xlet shutdown are not hard-bounded. Incomplete Java shutdown
quarantines the runtime until app restart rather than allowing surviving disc
threads to access a later session. A quarantined native disc and its callback,
graphics and transport owners are retained for in-flight JNI calls; its Java
admission slot is not released. The disc policy stays installed while those
threads remain. This deliberately retains resources until restart rather than
risk a use-after-free; it is not bounded termination. Bundled LGPL notices are
attribution, not a conclusion that App Store distribution requirements are met.
At the next runtime initialization, cache cleanup removes only marked,
UUID-named disc caches whose process-held lease can be acquired exclusively.
Active/quarantined process caches and unmarked legacy directories are retained.
The cleanup does not inspect or remove developer build caches.

Build the matching runtime before building an app or hosted test:
`tools/with-apple-build-lease.sh plozz/disc-runtime -- python3 tools/build-disc-runtime.py --sdk appletvsimulator`.
Use `appletvos`, `iphoneos` or `iphonesimulator` for the other destinations.
The builder verifies pinned downloads, checks each native library's platform,
retains licenses and records its build-input fingerprint. The app embed phase
rejects missing or stale receipts. Each native library is relinked into its own
signed `PlozzBDJ*.framework` under the app's `Frameworks` directory; native
dependencies and JVM library discovery use that layout. Even unsigned simulator
builds ad-hoc sign rewritten frameworks so arm64 loading does not use invalidated
linker signatures. Java modules, JARs, fonts and notices remain nonexecutable
resources in `DiscRuntime`. Assets remain under `.build`; do not commit generated
runtimes. `DiscRuntime/source-dependencies.json` records upstream archive URLs and
checksums, and `DiscRuntime/legal` retains the runtime, libbluray, ASM, libffi and
font notices. These files identify inputs, not a complete corresponding-source or
relinking offer.

The archive lane runs `tools/validate-disc-runtime.py --app <archived-app>` before
upload. It checks device architectures/platforms, framework dependencies,
extension version parity, executable placement, exact process-symbol imports,
runtime resource permissions and the signed bundle. Its process-symbol denylist
is a project guard, not a complete list of Apple's validation rules. It does not
establish physical-device execution without a debugger, safe termination of
arbitrary disc code, licensing compliance or approval under App Review's
downloaded-code rules. Those remain separate release gates. The corrected JVM
flags disable implicit null checks and reduce signal use; they do not eliminate
all runtime signal handlers. Offscreen disc graphics require
`java.awt.headless=false`.

The native **Play video** fallback opens the automatically selected feature.
**Disc videos** opens a native playlist list from the menu actions, menu failure
screen, or direct-play overlay. An independent native reader enumerates playlist
information without starting either disc VM, with limits of 1,024 playlists,
2 MiB per playlist and 16 MiB combined playlist metadata. Entries show playlist
identity, duration and chapter count; they do not guess feature or extra names.
Selection is bound to the exact source and playback attempt, stops the previous
navigation session, and restarts direct playback at the selected playlist.
Manually chosen playlists suppress library watch/resume reports, automatic next
episodes, library skip markers and subtitle downloads, and remembered series
track changes. Old library chapters, runtime and trickplay do not carry across.
Returning to **Play video** restores the ordinary feature path. These UI strings
remain subject to design approval and the normal reviewed localization gate.
The authored Java hosted test covers menu-only startup, both selected videos,
pause/resume, top-menu return, end-of-media callbacks and repeated sessions.
Run it alone with `TEST_RUNNER_PLOZZ_BDJ_SHUTDOWN_CHECK=1` to also exercise a
bounded interruption-resistant fixture thread and refusal of subsequent Java
sessions. That opt-in case intentionally quarantines its test process.
Private-disc acceptance on tvOS Simulator also covered an original Java language
selector, UHD feature playback and pause/resume, the original top menu, and its
Play action returning to the same feature with continued video progression.
That is evidence for the exercised disc and paths, not universal compatibility
or physical-device performance. Private disc contents are not included in CI.

On supported non-disc server items, the Play button's hold menu also offers
installed external players through **Play in**. This is a one-play override, not
a change to the saved external-player preference; it retains the selected source
and version and uses the existing authorization, launch and fallback path.

The hosted `testNativeHDMVFirstPlayAndTopMenuUseProductionTransport` uses original
synthetic navigation metadata generated by `fixture.create_hdmv_metadata` in
`tools/disc-menu-lab/fixture.py`, sharing the existing red/blue test clips. It
checks native playlist selection, rendered video and a top-menu transition;
it is not evidence of authored interactive graphics or commercial-disc support.
Companion hosted regressions cover a missing opening stream with backup CLPI
metadata, finite-still pause/resume, infinite-still menu transitions, and
two-way audio selection with deliberately reversed playlist track ordering.
Repeated-clip regressions cover an intermediate finite still, a final infinite
still, and a 42-millisecond second item. An explicitly configured private-disc
inspection also exercises original menu graphics and a held video frame through
the production transport and playback adapter; it is opt-in, not part of CI.
The multi-audio source is an original generated color/sine clip from
`tools/generate-bdmv-test-fixture.py`; `fixture.create_hdmv_metadata` produces
its alternate playlist and clip information when that clip is present.

Jellyfin/Emby, Plex and Silo remain server-managed libraries: Plozz consumes their
item identities and negotiated playback sources, not their underlying directory
trees. This change does not merge unrelated server-provided M2TS items or claim
to repair a server's own disc indexing.

`Fixtures/bluray-test-pattern` contains original generated color/sine clips and
synthetic MPLS playlists, with no copyrighted movie content. The main playlist
joins two eight-second clips; a longer unrelated clip catches largest-file
selection mistakes. Hosted WebDAV tests cover rendering, the 16-second timeline,
cross-clip seeking, second-clip resume and teardown, and assert that the unrelated
clip is not fetched. Regenerate into a **new** directory with:

```bash
python3 tools/generate-bdmv-test-fixture.py --output /tmp/plozz-new-bluray-fixture
```

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
than 256 KiB each (2 MiB total) for alternating disc-directory probes. This also
retains naturally grown 256 KiB metadata windows instead of rereading smaller
regions within them; it does not fetch additional bytes. Cache hits
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
adaptive reader, plus up to 2 MiB of probe cache. This is not a process/peak-memory
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

Known ordinary network-file containers (MP4/MOV, Matroska/WebM, MPEG-TS and AVI)
skip ISO/UDF signature reads through Aether's `discImageProbeEnabled` contract,
including independent readers and detail probes. ISO and unknown containers
retain disc recognition. This changes neither container/track analysis nor
transport identity, range, redirect or credential validation.

For known ordinary containers, a demand of at least 256 KiB within the final
4 MiB coalesces the remaining tail, still capped by the transport's preferred
request size. This avoids growing through several requests for a trailing MP4
index. Up to eight 256 KiB probe windows retain the header across that seek,
avoiding a second header download. Resuming at a cached ordinary-container
window's end continues the existing fourfold read growth, rather than inserting
another small request after the index seek. Random misses and independent readers
still start small. This can fetch bytes earlier than needed, but retains the
existing window limits and cancellation behavior. Small/disc probes keep their existing sizing policy.
The tradeoff is up to 4 MiB fetched for a partially consumed tail and up to
1.5 MiB more retained probe payload per reader than the original 64 KiB cache; cancellation,
clone independence and validated complete-window delivery remain unchanged.

WebDAV playback sources at least 256 KiB combine the mandatory range probe with
the initial 256 KiB media window. The full prefix is validated and retained by
the source lease, avoiding another header request; it adds at most 256 KiB per
source and can fetch unnecessary bytes when opening elsewhere. Small files and
GET-only identity discovery retain the two-byte probe. Accepted password
challenges are reused only inside the exact ephemeral account/revision/origin/
trust/role session; anonymous delivery remains separate. Origin revalidation,
complete-response validation and server authentication refusals remain enforced.

Detail-page WebDAV preparation retains one exact file, not a row, season or
collection of versions. Its provider locator path omits playback sidecar
discovery/materialization and watch-state work. It opens the ordinary
representation-bound source without taking playback admission. MP4/MOV and
Matroska/WebM retain up to 8 MiB from the beginning and 4 MiB from the end,
without overlapping those windows. ISO and other formats retain up to 4 MiB
from the beginning and do not blindly fetch a container tail.

ISO and nonzero resume positions additionally use Aether's bounded
`prepareSource` operation through a borrowed reader. It discovers disc extents
and timestamp origins through the engine, seeks to the actual presentation
position, and traverses two seconds of compressed video/audio coverage for
ordinary containers or four seconds for a disc's native HLS startup segment.
It neither creates a player nor decodes video. Packet-level coverage is not a
decoded-frame, complete-track-inventory or cache-residency guarantee. The
normal playback open remains authoritative; its stream analysis is unchanged.
Preparation alone limits analysis to 2 MiB and two media seconds without opening
decoders. Recognized discs with a declared title duration also warm the native
duration-estimation reads through the disc adapter, within the same budgets;
arbitrary container tails are not substituted for those reads.
If a DVD seek exposes only a late keyframe, preparation may seek at most two
seconds earlier once, reset its coverage evidence and retry the unchanged target
window. Packet/input/time budgets remain cumulative; Blu-ray seeking is unchanged.
Default audio selection during decoder-free preparation can differ from playback
selection. Preparation does not change the user's audio preferences or promise
coverage for the ultimately selected track.
Closing the borrowed reader drains its work without consuming the single-use
playback reservation.

The source cache retains at most 64 ranges and 40 MiB of payload (64 MiB for
ISO), including the opening and optional tail windows. Ordinary initial starts retain only their
opening/tail bytes. This is in addition to
the existing 256 KiB opening probe; these are source-level buffers, not decoder
or process-memory limits. Full caches do not evict or grow; publication freezes
the cache so subsequent playback reads cannot add to it. Native preparation
allows at most 28 MiB of reader input (48 MiB for ISO), 4,096 packets, 4 MiB per packet and
20 seconds (30 for ISO) inside the overall 30-second deadline. Reader input is not a
wire-byte cap: validated read-ahead can fetch unused bytes, while repeated
cached reads still count as input. Preparation read-ahead is capped at 4 MiB,
including clones. Incomplete native coverage fails preparation rather than
being labeled complete. No incomplete HTTP response becomes readable.

During playback, prepared-source demand reads preserve positive short cache
boundaries. They do not wait for an uncached remainder merely to fill a larger
adaptive window before delivering already-validated bytes to the demuxer.
HTTP(S) playback uses two independently validated response slots of at most
8 MiB each, shared across the reader and its clones, plus at most 2 MiB of small
probes. A complete response can be consumed while its successor is still loading;
partial HTTP bodies are never exposed. Other transports retain the normal
32 MiB steady-state read-ahead limit. Cancellation must drain a response before
its slot can be reused. These bounds exclude the source's prepared cache and
the engine's decoded-frame and packet buffers.
The engine's software consumer also services parked video on a bounded 20 ms
wait while its producer is blocked on source I/O. It does not lower the existing
125 ms video lead or 250 ms clock scheduling requirements, enlarge buffers or
treat a servicing deadline as end of stream.

Play must still obtain its ordinary provider request and playback admission.
Only an exact locator and current account/credential/trust/session match can
consume the preparation, after fresh DAV identity and size validation. The
delivery URL and conditional-read validator remain fixed; authorization or
representation failures are not hidden by reopening or serving stale success.
Unprepared and prepared startup are separate measurement populations. Preparation
time, whether the reservation was actually consumed, renderer readiness and
subsequent playback-clock advancement must be reported separately; a ready
callback alone is not a displayed-frame measurement, and clock advancement is
not proof that additional frames reached a physical display.
The hosted live benchmark checks a full minute of advancing playback immediately
after startup and again after seeking, so a quick first frame followed by a stall
does not pass.
Preparation does not guarantee a startup deadline: fresh provider metadata and
DAV revalidation remain on the Play path, and continued playback still needs
sufficient source throughput. Increasing preparation coverage cannot compensate
for an unavailable server or an arbitrarily delayed range response.

Share sidecar discovery lists the video's parent once and visits only advertised
`Subs`/`Subtitles` folders, using their actual casing. An unlistable parent retains
the legacy folder-name probes; ordinary optional-listing failures are logged,
while cancellation stops discovery. Own-folder exact-stem matching, dedicated
folder boundary matching and extras' exact-stem rule are unchanged.
For WebDAV, the same fresh, request-local parent listing also supplies the playback locator
when it contains exactly one matching physical path with a file size and strong
ETag or modification time. Missing, incomplete or ambiguous entries retain the
ordinary opening-stat fallback. This avoids a redundant metadata round trip,
not the final source-open/prepared-claim revalidation. Listings are never reused
across Play requests, and detail preparation still does no sidecar discovery.
Other share transports retain opening-stat metadata; their directory-listing and
file-stat representations need not carry the same precision or completeness.

The opt-in hosted `testExplicitLocalISOPlaybackWithLatency` uses a synthetic ISO
staged in the owned test host's caches directory, selected by
`PLOZZ_WEBDAV_LOCAL_ISO_FIXTURE` (a filename only). The optional
`PLOZZ_WEBDAV_LOCAL_START_POSITION` selects a nonnegative resume position.
Its loopback-only server reads bounded chunks from the file rather than retaining
the whole image. GET responses wait 250 ms before headers and 10 ms before each
64 KiB body chunk (6.25 MiB/s nominal per connection, before scheduling overhead).
The test requires the actual `localHLS` route and enough duration for both
minute-long continuity windows; software fallback does not satisfy this workload.
Request counts and sent body bytes expose extra I/O. This is a controlled
per-connection delivery model, not shared-link bandwidth or physical-device proof.
The companion `testExplicitLocalContainerPlaybackWithLatency` accepts an MP4 or
MKV filename through `PLOZZ_WEBDAV_LOCAL_CONTAINER_FIXTURE`, under the same
delivery schedule and continuity checks, without forcing a particular engine
route. The reported route remains part of the evidence. I/O snapshots at Play,
first render and teardown separate startup requests/bytes from later playback.
`playToFirstRenderedFrameSeconds` includes provider work before engine load;
`startupSeconds` additionally requires at least 0.5 seconds of clock advancement.
Set `PLOZZ_WEBDAV_AGGREGATE_BANDWIDTH=1` for concurrent-read comparisons.
One shared pacer then grants a body-chunk slot every 10 ms across all responses,
instead of granting that rate to each connection. A slot carries at most 64 KiB;
short metadata/final chunks conservatively consume a full slot. Header latency
remains per response. Keep this mode identical for baseline and candidate:
additional connections must not manufacture additional source bandwidth.

For an early-Play scenario, set `PLOZZ_WEBDAV_DETAIL_PREPARATION=1` and
`PLOZZ_WEBDAV_DETAIL_PLAY_DELAY_SECONDS` to `2` or `3`. The hosted benchmark
uses the production detail coordinator, including its 750 ms dwell, and invokes
the normal handoff without waiting for preparation to complete. Its timer starts
at that Play action, including cancellation/drain and ordinary provider work.
It reports readiness at Play and actual reservation consumption; an incomplete
preparation cannot be relabeled as a prepared start. Set
`PLOZZ_WEBDAV_REQUIRE_SUBTHREE_START=1` for an additional sub-three-second
assertion, including when Play falls back to a cold open. Matched baseline
comparisons need not enable that stretch target. This models the
already-resolved detail's lifecycle, not full UI navigation, artwork loading or
physical remote/touch input. Runs without the delay still wait for complete
preparation and must not be used as evidence for this early-Play scenario.
Both app shells retain a pending preparation ticket and request interruption of
optional warming at Play, preserving complete validated ranges without waiting
for the entire warmup. The hosted `PLOZZ_WEBDAV_EARLY_HANDOFF=1` mode exercises
that path; omitting it retains the older completed-reservation comparison.
Ticket registration is not readiness: the benchmark snapshots the
warmup outcome before handoff and reports the sealed outcome and actual
consumption after resolution. Interrupted warming must never be reported as
complete native coverage.
An explicit native preparation budget limit, end-of-source or unavailable seek
discards and drains the reservation before ordinary playback opens afresh.
Waiting for that reservation still reports incomplete preparation, never ready
coverage or a consumed source. Transport timeouts and actual read, authorization,
trust and representation failures remain failures; they are not hidden by this
optional-preparation fallback.
The range pipeline requires an
HTTP(S) transport identifier from the resolved source's pinned session at reader
creation, not a second account lookup. DEBUG benchmarks may set
`PLOZZ_WEBDAV_RANGE_PIPELINE=0` to compare the old reader; Release builds always
use the bounded pipeline for eligible sources. Compare this separately and together with early handoff,
using the same aggregate bandwidth cap rather than per-connection throughput.

Related upstream designs separate request sizing from buffered consumption:
[FFmpeg HTTP](https://github.com/FFmpeg/FFmpeg/blob/b7e835e06913e4374a4567003fe8c75cebfffb98/libavformat/http.c)
supports separate initial/steady request sizes and short-seek read-ahead;
[VLC prefetch](https://github.com/videolan/vlc/blob/11bcb6f56d59b43cf589556f426c7a5cbd460fdd/modules/stream_filter/prefetch.c)
uses a bounded producer/consumer buffer; and
[mpv demux](https://github.com/mpv-player/mpv/blob/dde0671072723c311df874a32dc4e48b5197ca62/demux/demux.c)
keeps bounded forward/backward packet caches.
[Kodi's HTTP reader](https://github.com/xbmc/xbmc/blob/af9ff93d022fedceaff6b5a256b3a8345f4263d5/xbmc/filesystem/CurlFile.cpp#L1482-L1508)
retains old read state across seeks. These are architectural references,
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
Matroska and DVD fixtures also open fresh engines at a nonzero start position,
checking that the first ready video position is near the requested resume point
before measuring continued progress. These are resume loads, not post-load seeks.

```sh
mkdir -p /tmp/plozz-disc-fixture/VIDEO_TS
ffmpeg -f lavfi -i 'testsrc2=size=320x240:rate=25' -t 10 -an \
  -c:v mpeg2video -g 12 -q:v 8 -f vob /tmp/plozz-disc-fixture/VIDEO_TS/VTS_01_1.VOB
hdiutil makehybrid -iso -udf -default-volume-name PLOZZ_DISC_FIXTURE \
  -o dvd-test-pattern.iso /tmp/plozz-disc-fixture
```

The separate live test is opt-in: pass JSON in the test process's
`PLOZZ_WEBDAV_PLAYBACK_JSON` environment variable, or set
`PLOZZ_WEBDAV_PLAYBACK_INPUT` to a private JSON file (or `cache:<filename>` in
the test host's cache directory) containing `baseURL`, `username`, `password`,
`relativePath`, and one to three `seekPositions` in seconds. Optional `startPosition`
defaults to zero; supply a finite nonnegative position for a fresh-engine resume
measurement. No server watch state is written. Use a credential-free
HTTPS base URL and a media file or decrypted ISO the tester is authorized to
access. For file input, use a tester-owned file with mode `0600`, outside Git.
For environment input, load credentials only for `test-without-building`, not
build commands that could dump their environment. Remove staged simulator
credentials after the run. Missing configuration skips only that live test;
it is not evidence of remote playback. Each load/seek has a 120-second deadline
and frame/progress waits are bounded separately. Preparation and engine-load
timings are reported separately; the combined metric ends after rendered video
has progressed beyond 0.5 seconds after the requested start position, not at the
first decoder output. Resume coverage also requires the first ready video
position to fall between one second before and five seconds after that position.
After the final seek, the live test observes another 60 seconds and requires
more than 58 seconds of playhead advancement. This is a bounded continued-playback
check, not proof of complete-film playback or physical-device frame smoothness.

## Embedded container chapters

`VideoEngine.chapters` contains normalized chapter starts on the engine's ordinary
seek timeline; `onChaptersChanged` publishes optional metadata that arrives after
load. Plozzigen maps AetherEngine's `mediaChapters` after the normal source probe,
including authenticated/custom-reader sources, without opening another reader.
Native playback loads AVAsset chapter metadata off the startup path using the
same asset and authorization as playback. It cancels and fences that task by load
generation and current player item. Both engines clear chapters on replacement
and stop; the player separately rejects outgoing-engine/load callbacks.

Server chapters remain preferred over embedded metadata. This fallback reads
container chapters, not disc-title-relative chapters or generated scene markers.
Original six-second synthetic fixtures in `Tests/EnginePlozzigenTests/Fixtures`
cover MP4/native, MP4/Plozzigen, MKV/Plozzigen, seeking, and replacement by a file
without chapters. Generate them with:

```sh
cd Tests/EnginePlozzigenTests/Fixtures
ffmpeg -f lavfi -i 'color=c=navy:s=160x90:r=10:d=6' -i chapters.ffmetadata \
  -map 0:v -map_metadata 1 -map_chapters 1 -c:v libx264 -preset ultrafast \
  -pix_fmt yuv420p -g 10 -movflags +faststart chapters.mp4
ffmpeg -i chapters.mp4 -map 0:v -map_chapters 0 -c copy chapters.mkv
ffmpeg -i chapters.mp4 -map 0:v -map_chapters -1 -c copy -movflags +faststart no-chapters.mp4
```

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
[AetherEngine fork](https://github.com/brandomoore/AetherEngine/tree/45e37ed2e6b66ea520229a6fb8b0f973fe155fda)
at commit `45e37ed2e6b66ea520229a6fb8b0f973fe155fda`, integrating upstream
**7.53.1** (`0839aeee18dd0818c5c307a3c5ecba8ea3161b22`).
Playback diagnostics show `AetherEngine v7.53.1`, read from the linked engine
rather than a duplicated version constant. The exact fork commit remains in
attributions because the upstream version does not identify Plozz's patches.
The 7.51.0 integration includes 7.50.0's 24-bit PCM spatial-bed output with
route-selected APAC for AirPlay. The 7.53.1 update advances FFmpegBuild to
3.11.1; LibDovi 2.1.0 and LibTrueHD 3.1.0 remain unchanged.
It corrects the remote-HLS buffered frontier, uses measured producer throughput
for short forward seeks, bounds bitmap subtitle retention after backward seeks,
and supports HLS byte-range segments. The fork preserves AAC timing compensation,
ASS duration handling, dynamic linkage and active-picture APIs, including seam
invalidation in the upstream weak-session callback.
It also retains bounded position-aware WebDAV preparation, video servicing
during source reads, and active-picture cleanup compatible with older runtimes.
Ready SDR guide/fullscreen transitions on tvOS use its in-place display-matching API,
without reopening media or replacing the player item. Previews explicitly use
host-owned fixed output; HDR pipeline changes retain the reload path. Late native
HLS format callbacks honor the current policy, and an outgoing display owner
cannot clear a newer engine's criteria.
New audio shaping and low-resolution SDR upscaling remain disabled by default.
The engine uses upstream's single privacy manifest, including local-media file
timestamps; FFmpeg's applicable frameworks now carry their own manifests.
The update retains overlapped VOD/HDR preparation and adds the upstream
subtitle, HLG, chapter-timing, bounded-loading and cache fixes. Bitmap subtitle
OCR is armed only for a native rendition used by PiP, AirPlay or an external
display, avoiding its extra fullscreen read-ahead. Native subtitle readiness
can still wait for OCR. Live startup waits for the requested first buffered
window before attaching AVPlayer, rather than spending its playlist timeout
filling a large cushion.

The 7.48.0 integration adds VP9 hardware decoding on supported devices, with a
software fallback, and AV1 Dolby Vision Profile 10.1 metadata on the software
presentation path. Upstream added optional spatial audio for software/FEL playback
on tvOS and iOS/iPadOS 26+; Plozz no longer enables that path. TrueHD's optional
renderer now decodes the object presentation with matrix interpolation through
LibTrueHD 3.1.0. This is spatial conversion, not lossless bitstream passthrough.
FFmpegBuild advances to 3.10.1, including its libzvbi update and AAC/ALAC
silent-tail encoders; LibDovi remains 2.1.x. The engine also fixes resume-position
publication, HDR refusal latching and software renderer teardown.

Remote MPEG-DASH support is limited to unencrypted static, single-Period
`SegmentBase` manifests, not live DASH or adaptive representation switching.
New host-owned software Now Playing, paused-background pipeline retention and
renderer audio-session controls keep their upstream defaults; the dependency
update does not opt Plozz into a new ownership or background policy.

The 7.47.0 update starts software Live TV picture and sound together at the
first keyframe and no longer reports a brief rebuffer while AVPlayer evaluates
its buffer on resume. It corrects the HDMI route check for the optional TrueHD
spatial-output activator and no longer runs that activator for DTS:X conversion.
The existing 30-second diagnostic probe also reports coarse per-thread CPU
usage. Upstream stereo presentation is additive and remains at `.automatic`;
Plozz's tvOS and iOS targets still present these sources in 2D. Dependency
versions and production component traits are unchanged.

Plozz uses the new session-cache byte budget with its existing Video buffer
presets and exposes a separate Live TV buffer, both defaulting to Automatic.
See [buffering contracts](../Sources/FeaturePlayback/README.md#on-demand-read-ahead)
for route limits, temporary storage, safe-edge semantics and startup tradeoffs.
Upstream moved DTS:X height decoding to FFmpegBuild 3.9.0; Plozz no longer enables
the optional conversion component.
ASS/SSA packets with neither a decoded end nor a packet duration are now discarded
instead of lingering for a fabricated five seconds. This also applies to sidecars;
other subtitle codecs retain their established fallback. This upstream snapshot
does not include this correction; the fork retains it and its regression tests.

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

The fork exports **AetherEngine as a dynamic framework**, keeping the engine's
decoder runtimes separate from Plozz's Objective-C and C++ text-rendering code.
Both app targets must embed and sign it alongside the FFmpeg frameworks.
Upstream 7.44.0 replaced LibDTSX with FFmpeg's patched `dca` decoder.
`DTSX.framework` and the retired LibDTSX notices are no longer shipped;
existing FFmpeg notices remain.

Plozz explicitly enables no optional engine traits. `DolbyVisionStillReshaping`,
`DualLayerDolbyVision`, `TrueHDObjectAudio` and `DTSXObjectAudio` are disabled:
their engine implementations are excluded, and LibTrueHD is not resolved or
linked. The existing FFmpegBuild binary still contains its dormant DTS:X
`x_heights` decoder option; Plozz does not enable it. This is not a stripped
FFmpeg build. Ordinary FFmpeg audio decoding is unchanged. Both apps consume
this same local package, so no generated-project trait patch is needed. Engine
integration tests inspect the linked engine's `OptionalComponent.isBuiltIn`
flags, not just its load options. Upstream's licensing notices remain applicable;
this configuration does not establish patent clearance.

Dolby Vision Profile 5 / AV1 Profile 10.0 sources no longer receive software-
reshaped scrub or I-frame stills. Ordinary base-layer thumbnails remain available.
Native Dolby Vision playback is unchanged; the pinned engine can retain a held
picture through the system compositor instead of applying its own reshaping.

The 7.23.0-to-7.34.1 range adds live-start/holdback and source-open recovery
fixes, corrected software resume/seek timelines, transport-intent preservation
during rebuilds, and blocking engine work moved off Swift's cooperative pool.
Changing speed while paused now leaves the session paused until `play()`.
E-AC-3 JOC stream copies advertise object audio in the HLS master, including
untagged tracks. FFmpegBuild **3.7.x** fixes dependent-substream spatial signaling;
LibDovi remains **2.1.x**. The earlier 7.36.0 integration used LibTrueHD **2.3.x** and
LibDTSX **1.0.1**. Upstream 7.36.0 added another object-audio rendering path, corrected
spatial speaker positions and a tvOS spatial-output activator for receivers that need it.
It also includes live-replay recovery, software-video recovery after a screen lock,
and the intervening 7.35.x playback fixes; these are upstream changes, not new
Plozz-specific implementations. The current pin uses FFmpegBuild **3.11.1**
and LibDovi **2.1.x**. LibTrueHD and LibDTSX are no longer linked in Plozz. It also includes
single-connection spatial-audio probe safeguards and system-composited Dolby Vision
held pictures. The fork retains the persistent HTTP body-reader isolation
correction from its previous integration.

### Lossless surround

Playback's **Prefer lossless audio** toggle defaults on for
both new and upgrading devices. It controls the ordinary Aether audio bridge for
on-demand files, downloads, and Live TV, independently of source channel count.
Each new load reads the device preference. Profile switching and profile sync do
not replace the choice because the connected audio setup belongs to the device.

On selects the existing FLAC bridge, including for 5.1 DTS-HD MA and sources whose
channel count is unknown before the engine probes them. AVPlayer decodes FLAC to
PCM; multichannel output requires a compatible HDMI/eARC path. A legacy ARC or
other stereo-PCM-only path may downmix it to stereo. Off selects Aether's E-AC-3
compatibility-surround mode, which is lossy and caps multichannel sources at 5.1;
stereo sources still use FLAC under the engine's existing policy.

This does not recover quality already lost in a server rendition, change
stream-copy audio, force native playback through a bridge, or override spatial
audio conversion. Diagnostics describe the actual engine pipeline, not the
toggle's desired mode or the receiver's output.

### Spatial audio

**Height-channel conversion is disabled.** The adapter always requests
`objectAudioRendering = .off`, and the engine's `TrueHDObjectAudio` and
`DTSXObjectAudio` package traits are disabled. Neither saved profile preferences,
profile transfers nor old device layout values can turn conversion back on.
The former toggle and layout picker are removed on both platforms. Legacy
`trueHDAtmosEnabled` JSON values are ignored and omitted when settings are saved.

Ordinary channel presentation still follows Prefer lossless audio: FLAC by
default, or the E-AC-3 compatibility bridge when off. Software playback uses
channel PCM, including for E-AC-3/JOC sources; native E-AC-3/JOC stream-copy remains
unaffected. Explicit track selections, language preferences, buffering and
progressive segment delivery defaults are unchanged.

Compatible native spatial audio remains system-owned. Plozz does not override
the OS's Spatial Audio or head-tracking choices. Source format labels do not
promise separate height-channel output. Diagnostic parsing retains recognized
rendered-layout labels for historical/engine reports rather than inferring
output from a preference.

LibTrueHD is no longer linked. Both apps retain its unmodified MIT/Apache-2.0
license and NOTICE resources, and the credits identify it as a former dependency.
Removing this component is not a general patent-clearance or store-approval claim.

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

## Dolby Vision FEL

**Experimental FEL reconstruction is unavailable.** Its Settings control and
search result are removed on tvOS and iOS/iPadOS. The adapter explicitly sets
`LoadOptions.preferDualLayerDolbyVision = false`, and the `DualLayerDolbyVision`
package trait is disabled. Legacy `dolbyVisionFELEnabled` values are ignored when
loading or transferring profile settings and omitted on the next save.

Normal Dolby Vision handling remains automatic. Profile 7 keeps the existing
single-layer Profile 8.1 conversion where the display accepts Dolby Vision, or
the HDR10 base layer otherwise; the enhancement layer is discarded. Other
profiles' playback, ordinary audio paths, and native E-AC-3/JOC stream-copy are
unchanged. Software still-image reshaping is separately disabled as described
above. External players own their own decoding preferences.

Removing the optional reconstruction path does not establish licensing clearance
for every remaining video or audio feature.

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
| **Plozzigen** | `.plozzigen` | AetherEngine: native HLS, local remux/AVPlayer, or software decoding | Primary owner for library video, selected server renditions, ordinary downloads, and live channels |
| **Native** | `.native` | AVPlayer / AVComposition | OS-managed download packages, separate trailer audio, constrained HEVC-HLS initialization repair, and bounded compatibility recovery |

> `.hybrid` is a legacy routing value meaning "this item needs on-device
> decode." It historically selected a libmpv-backed `EngineMPV`, which has been
> **retired** (recoverable at the `archive/mpv-engine` git tag). The current router
> no longer emits `.hybrid`; retained compatibility values resolve to Plozzigen.

## Routing Logic

`EngineSelection` chooses the owner, not the decoder:

```
1. Credential-scoped network file -> Aether transport, never a native URL loader.
2. Constrained, transcoded HEVC HLS -> native AVAsset initialization repair.
3. Separate trailer audio or an OS-managed .movpkg directory -> native asset.
4. Otherwise -> Aether when linked; native on native-only hosts.
```

Missing codec metadata, MP4/MOV, Dolby Vision profiles, and subtitle classes do
not reintroduce host-side format gates. Aether probes the selected source and
chooses its supported decode/render path. A progressive file with a legacy
`.movpkg` extension is not an OS-managed asset package.

The adapter loads `PlaybackRequest.playbackSource`, **not**
`localRemuxSource.originalSource`. The latter retains original-file facts and
preview access; substituting it would bypass server-selected quality, audio,
subtitle and conversion choices. Resume and server-session ownership remain
with the existing playback coordinator. VOD uses Aether's ordinary load path,
which classifies finite HEVC-in-TS HLS; forcing `nativeRemoteHLS` would bypass
that classification. Live HLS keeps its separately configured engine path.

Managed server renditions retain the provider's source audio choices, even when
the delivered stream contains only one audio track. Manual picks, imported
language preferences and restored selections renegotiate through the playback
coordinator. Source track IDs are never passed as rendition-local demux indexes.

This follows the single-player, server-selected-input pattern in
[Sodalite's player](https://github.com/superuser404notfound/Sodalite/blob/31799bde53e2d93384216b3f9b2523600896ef2b/Sodalite/Player/PlayerViewModel.swift).
It does not assume that another app's profile or comments override Plozz's
pinned engine API or provider contracts.

## Provider input capabilities

`PlozzigenMediaFormats` is the shared decoder-backed input list for Plex and
Jellyfin/Emby negotiation. It includes MP4, Matroska/WebM, transport/program
streams, AVI, ASF, Ogg, FLV and RealMedia, with their linked video/audio families.
MPEG-2, MPEG-4 Part 2, VC-1, WMV/WMA, Theora, RealMedia and supported FLV-era
codecs are not rejected merely because the old native-remux path lacked them.
The list is not a promise that every file or arbitrary codec/container pairing
works. Decoder availability, actual stream validity, transport, output and
provider policy still matter. DASH is not advertised: compiled demuxers alone
do not establish a supported remote-input path.

Native-only capability profiles remain separate. Server conversion profiles,
quality budgets, selected versions/tracks and session maintenance are unchanged.

## Deliberate native exceptions

- An `AVAssetDownload` package is an OS-managed asset, not an ordinary file.
- Separate trailer audio needs the existing `AVComposition`; Aether's single
  URL/reader load is not that composition.
- Constrained HEVC HLS retains the tested empty-`sdtp` fMP4 initialization repair.
  It uses Plozz's custom AVAsset resource loader, which Aether's URL load cannot
  accept. `HEVCInitializationPlaybackHostedTests` exercises the original
  rejection and actual decoded frames after repair, including seeking.
- Existing bounded alternate-engine/server-conversion recovery remains.
  A transcoded request is not eligible for arbitrary alternate-engine recovery;
  that ladder is not a substitute for preserving the initialization repair.

These are asset/API compatibility boundaries, not a blanket MP4, HEVC, HLS,
Dolby Vision or subtitle exclusion. Aether's AVPlayer-backed routes are still
native decoding; consolidation does not force software decoding or establish
lower CPU, I/O or energy use.

## Persistent playback diagnostics

`PlaybackDiagnosticJournal` records event-driven request/load/first-frame,
phase-change, failure, retry, stop and server-release evidence. Random
session/attempt IDs correlate retries without persisting server session IDs.
Typed failures are captured before teardown; output codec/range are separate
from source metadata and negotiated output. Live playback records the existing
typed failure evidence even when there is no server reporting callback; unknown
live provider identity remains unknown rather than being labelled IPTV.

Recording neither reads AVPlayer logs nor performs disk I/O. A utility queue
coalesces writes, retaining at most 256 entries and 128 KiB for 48 hours.
No new per-frame observation or polling loop is added. URLs, headers, titles,
account identifiers and arbitrary error descriptions are excluded. Storage
failures are explicit. `releaseFinished` means the provider release API returned,
not proof that the server deleted the session.

Settings' existing consent-gated diagnostic submission asynchronously appends
the journal to its attachment, rechecking reporting availability after export.
This is not an automatic per-event upload. The HUD remains separate.
The `playback-journal-disabled/enabled` performance-lab controls measure 10,000
notifications, synchronous admission separately, and completed persistence with
retention assertions; they do not establish physical-device frame pacing.

## Quality Capabilities by Engine

| Feature | Plozzigen | Native |
|---------|-----------|--------|
| Dolby Vision | ✅ (Profile 5/8; optional dual-layer path, see above) | ✅ (if server delivers DV) |
| Directly compatible spatial audio | ✅ (E-AC-3 JOC on the native path; software playback uses channel PCM) | ✅ (if stream has E-AC-3 JOC) |
| HDR10 / HLG | ✅ | ✅ |
| Full-timeline seek | ✅ | ✅ (if not live transcode) |
| PGS subtitles | ✅ (engine-owned subtitle paths) | ❌ (server burn-in needed) |
| Spatial audio conversion with heights | ❌ (disabled; ordinary channel audio remains available) | ❌ |
| DTS bitstream | ❌ (channel audio uses FLAC/E-AC-3 bridge) | ❌ |
| TrueHD bitstream | ❌ (channel audio uses FLAC/E-AC-3 bridge) | ❌ |

## AirPlay 2 / HomePod Audio Recovery

Native and Aether's AVPlayer-backed routes use `AVPlayer` +
`AVAudioSession`, so they can encounter the **AirPlay 2 / HomePod silent-drop**
that was root-caused and fixed for music. The cure (a full audio-session
deactivate→reactivate cycle — `setActive(true)` alone is a no-op), plus what
did/didn't work and how to port it to video seek/route-change handling, is
documented in **[airplay-audio-recovery.md](./airplay-audio-recovery.md)**.

## Source Code References

- Provider input formats: `Sources/CoreModels/PlozzigenMediaFormats.swift`
- Engine routing: `Sources/FeaturePlayback/EngineSelection.swift`
- Plozzigen adapter: `Sources/EnginePlozzigen/PlozzigenVideoEngine.swift`
- Engine factory: `Sources/FeaturePlayback/EngineFactory.swift`
- AetherEngine dependency: `Package.swift` → `brandomoore/AetherEngine` (patched upstream fork)

## History

Plozzigen replaced a custom local-remux engine (CRemuxCore + cue-table approach)
that suffered from audio/video desync, fragile resume behavior, and inability to
handle Plex content correctly. The prior engine's experimental branches are
preserved under `preserve/remux-*` git tags for reference but are not used.

AetherEngine was adopted because it solves the exact same problem (MKV → AVPlayer
with Dolby Vision, spatial audio and seeking) with a battle-tested pipeline. Plozz wraps it via
the `PlozzigenVideoEngine` adapter conforming to the `VideoEngine` protocol.

An earlier libmpv-backed `EngineMPV` engine (routed via `.hybrid`) was also
retired once Plozzigen covered the on-device decode path. Its source, build
scripts, and staged xcframeworks were removed; it's fully recoverable at the
`archive/mpv-engine` git tag.
