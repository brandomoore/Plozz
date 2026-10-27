# Live TV

A native Live TV destination for Apple TV, iPhone and iPad, available in Debug
and Release builds. It combines configured IPTV playlists, authorized server
channels and scheduled library channels, using Plozz's existing AetherEngine
(`PlozzigenVideoEngine`) integration.
It lives
inside Plozz's actual navigation instead of replacing the application root.
Release builds include the same navigation, standalone onboarding, source
management, guide/search, Multiview, playback and profile-scoped iCloud sync. Existing
profile authorization, parental approval, account, source and persistence gates
remain in force.

Source setup explains that viewers must have authorization for their channels
and that Plozz does not provide TV content or channel subscriptions.

For past failures, attempted repairs and related tests, see the short
[IPTV troubleshooting history](iptv-history.md). It is historical context,
not a specification.

For the reliability-first hardening priorities and explicitly deferred feature
gaps, see [Live TV reliability](live-tv-reliability.md). It records finite
provider cooldowns, safe connection-limit errors, controlled rolling-playback
results, and remaining real-provider/long-session coverage gaps.

## Diagnosing disappearing sources

**Send to Developer** automatically includes a structured Live TV source journal
on iPhone, iPad and Apple TV, including TestFlight/Release builds. No debug launch
arguments or playback overlay are required. Reproduce the disappearance and send
diagnostics before removing or re-adding accounts; the send action captures the
current account selection, active profile/storage scopes, saved source document
and enrollment suppression without refreshing a provider.

The local journal retains up to 48 hours, 512 events and 256 KiB across restarts,
separately from the short Recent Activity buffer. It records missing versus
unreadable source storage, save/removal and sync origins, suppression changes,
account membership, Sources/guide admission and loading, enrollment decisions,
and correlated IPTV catalog progress/failures. Launch IDs, sequence numbers and
build numbers distinguish sessions and versions. Provider catalog IDs link an
import to its account; profile, account, source and scope identifiers are hashed.
Names, server/playlist addresses, credentials, content and error descriptions
are never journal fields. Source snapshots cap detailed entries at 64 and report
the omitted count; eviction and persistence failures are explicit in the export.

The journal is local application-support data excluded from backup. Upload still
requires the existing crash-reporting consent and an explicit diagnostic send;
recording does not enable automatic uploads. Do not interpret absent events
after an eviction or storage failure as proof an action never occurred.

## Cached Home cards

Normal Live TV use publishes a small, profile-scoped **local** Home snapshot:
up to three recently watched channels in Continue Watching and an eight-channel,
favorites-first Live TV row. Existing Home row controls determine their visibility
and order on Apple TV, iPhone and iPad. The selected cards persist in a separate
device-local cache file (at most 64 KiB, three recent cards and eight row cards).
Cold launches hydrate only that file; opening Home does not warm the lineup.
Absent, corrupt, oversized or unsupported cache files are treated as cache misses.
There is no portable-state initialization or sync registration for this cache.
Portable state applied to another profile must not clear the displayed profile's
snapshot, pending selection, or persisted cache. A same-profile apply invalidates
channel identities until that profile's catalog owner republishes them.

Home performs at most 24 candidate lookups in the already indexed catalog when
the Live TV owner publishes a snapshot. It never reads/decrypts a full lineup,
hashes an imported playlist file, refreshes a playlist/guide/provider, starts a
tuner, runs a preview, or introduces a polling timer. Cards retain channel
identity, display text and the selected channels' logo URLs. The shared channel
artwork pipeline fits logos without cropping, reuses prepared images, and falls
back to the channel name. Only visible logo requests are added; no catalog work
is needed for artwork. Snapshots containing potentially credential-bearing URLs
are authenticated ciphertext with a profile-specific Keychain key. URL-free
legacy snapshots remain readable; plaintext artwork URLs are rejected, and a
missing or locked key never causes a plaintext fallback or replacement key on read.
Home TV cards use a direct SwiftUI Button with the native card style for System
focus, keeping artwork loading and focus in the same view hierarchy. The native
style owns the dark surface, sheen and corner shape; only custom-focus and mobile
cards draw the fallback surface. Fast row scrolling must retire the previous
card's visible highlight as well as its focus state. Loading Continue Watching
keeps the hero empty until a real card is focused or the first slot finishes
loading, rather than seeding it from a trailing cached channel.
Playlist sources and server-backed sources
(including IPTV accounts) retain current profile, source-approval and server-user
authorization fences. Persisted scope uses non-secret account credential revisions
and profile/server-user identity, not ephemeral per-launch Plex override revisions.
Current source approval, credentials and profile access are checked before cached
cards are exposed. No plaintext credentials or token-derived identity hashes are persisted.
Scheduled library channels remain in the Live TV guide.
The mobile tab shell supplies its current `ProfilesModel` to the shared Home
scope and all tab destinations, not only the Live TV child. The shared scope
requires that model even when a different tab is selected.

Selecting a card first enters the existing Live TV destination. A one-shot typed
request waits for that destination's current authorized catalog and ordinary
playback gates, then uses its owned watch coordinator. Home itself neither opens
a stream nor records a channel as watched; normal video acceptance owns recents
and existing playback/lease cleanup remains unchanged.

## Run

Generate the project using the normal wrapper:

```sh
export GIT_CONFIG_PARAMETERS="'safe.bareRepository=all'"
tools/generate-project.sh
```

Open `Plozz.xcodeproj` and run a **Plozz** build on Apple TV or
**PlozziOS** on iPhone/iPad. Choose and connect a media server or **IPTV** during
first-run setup, then complete the ordinary profile and appearance steps.
Standalone IPTV requires no media-server account. Select **Live TV** in
navigation. Apple TV supports the top tabs, native sidebar and custom
navigation rail variations; iPhone/iPad expose the same destination in their
tab shell. Device installation must be authorized; a build alone does not
install anything.
Navigation uses the plain **Live TV** label in every style. The source-setup
introduction carries a small, secondary **Experimental** note on both platforms,
without a warning dialog or an extra confirmation step.

On iPhone and iPad, selecting a channel opens a video preview above the guide,
8 points below the existing navigation toolbar controls. There is no channel-artwork card or
Watch channel button over the video. Tapping the preview shows or hides the
shared player transport and fullscreen action; fullscreen keeps the same player
and stream. Its video surface stays in the same native parent during expansion,
return, and rotation; an interruptible resize follows the current window geometry
without waiting for a forced orientation. Reduce Motion disables that animation.
Expanding the current preview rechecks authorization and presentation ownership
without starting channel preparation or showing an opening-channel banner.
Before a channel is selected, the guide uses the available space.
Opening the preview reduces the guide's viewport without replacing its scroll
view or resetting its channel/time position. Search and the narrow category
directory hide the preview surface while retaining the existing playback policy.
In wide mobile layouts, the category sidebar retains its full height and scroll
position; only the channel guide sits below the video in the adjacent column.
Preview transport controls are centered on the video independently of its title
row, with a larger Play/Pause button than Previous/Next.
The playing surface is reflected below the preview, upward behind the toolbar,
and into available side gutters, without moving the video or controls. This
also fills the space around a fitted picture on folded and unfolded devices.
When both horizontal sides have room, the sharp picture uses the shared content
corner radius. The surrounding reflection uses native blur and a gradual fade into the guide
background. The reflection starts at full intensity, then follows a quadratic
falloff with a faint tail rather than a steep final cutoff. One transparency
mask fades both the reflected video and its blur into the actual background,
avoiding a flat-color edge where the reflection ends. The reflection sits
behind guide content, adds no layout height, and shares the original video
surface rather than opening another player or copying decoded frames. It is
disabled in fullscreen, multiview, Reduce Transparency, and when the
preview is inactive, interrupted, or continuing on an external presentation.
Apple TV keeps its existing browsing info bar and focus-driven preview.

In compact iPhone windows, browsing stays portrait. With Playback orientation set to Auto, rotating
a visible playing preview sideways expands the existing player; rotating upright
returns automatically expanded playback to the guide preview. Manually opened
fullscreen stays open on rotation. Close restores portrait browsing and waits for
physical upright before allowing another automatic expansion. This follows system
rotation lock; iPad browsing and playback rotation are unchanged. Expanded phone
windows (at least 600 points in both dimensions) follow system rotation instead.
Resizing or unfolding alone does not expand the preview. Layout uses the current
window and its independent leading/trailing safe areas; a vertical navigation
bar does not reserve its full height above the video.

For isolated physical-TV iteration, build a branded Debug app using the existing
per-branch build configuration. It has its own bundle ID, preferences and data;
normal Plozz remains installed and untouched. Cloud sync and Top Shelf are not
enabled for branded builds. A branded app therefore needs its own normal
profile/source setup. Once installed, launch that bundle explicitly:

```sh
xcrun devicectl device process launch --device <device-id> \
  <branded-bundle-id>
```

The old `--live-tv-prototype` and remembered prototype-entry preference no
longer bypass Plozz's root or its background services. The older prototype
schemes also open the normal app; enter Live TV through navigation.

Debug-only launch arguments:

- `--live-tv-5000`: repeat the real catalog into 5,000 clearly labeled rows for
  scrolling tests. These are copies, not 5,000 distinct stations.

The former `--live-tv-guide` flag is no longer needed: channels and their guide
are one screen, including when no listings exist.

Release builds never honor prototype launch shortcuts or stress-catalog
arguments. Synthetic channel/program fixtures and the public regression catalog
remain Debug-only; neither is a production default or a source offered to users.

## Try

### Native navigation and animated browsing

On Apple TV, Live TV remains inside the selected native tab/sidebar, including
its normal title/header. Browsing never presents a separate fullscreen host or
reparents the player to reveal navigation. One Back from the guide or browsing
controls belongs to native navigation. The native sidebar also owns the leading
direction from categories (Left in LTR, Right in RTL). Search, dialogs, pending
channel preparation, and expanded playback retain their own Back handling.
Menu round trips preserve the guide and playback session; a genuine
destination/profile change still deactivates playback.

Profiles without a saved navigation choice default to **Pinned Sidebar**.
The first-run, new-profile, and Settings pickers list Pinned Sidebar, Sidebar,
then Top Bar. Saved profile choices are not overwritten.

Automatic entry reuses the account's saved channel catalog. Explicit Refresh
channels, Refresh sources, and retry actions bypass that cache and await the
replacement, including when the saved playlist has no channels.

Search and the active-channel artwork stay aligned, with an additional 16-point
clearance below native navigation. Pinned navigation keeps its existing inset.
The full-height Search/categories pane remains beside the guide during TV
browsing. Moving focus between panes does not move or resize the guide.
The category list remains lazy; no per-row animation timers or rasterized
snapshots are used. Mobile layouts choose the sidebar or category directory
from the available window dimensions, not the device name.
Native guide row hosts accept both growing and shrinking widths with leading
alignment, so explicit-width programme timelines do not recenter independently
of channels without listings during the sidebar transition.
Native-menu round trips, selected-category restoration, and preview-session
identity have remote regressions; hosted rendered-pixel tests cover synchronized
Search/Multiviews/category movement, mixed-source guide rows, guide travel, and
rapid reversal.

### IPTV accounts and large catalogues

**Sources > IPTV provider** and **Add Server > IPTV** use the same account
setup on Apple TV, iPhone and iPad. Connections accept a personalized M3U URL,
HTTP Basic credentials, a bearer token, custom request headers, or an Xtream
server/username/password. On iPhone and iPad, **Playlist file (M3U)** imports
through Files into the same disk-backed catalogue. File catalogues remain on
the importing device; they are not copied by account sync. Use a playlist URL
for a source that should refresh independently on multiple devices.

Selecting **Playlist URL** does not require knowing the provider's protocol.
An Xtream `player_api.php` link containing a username and password is recognized
directly. For a server address or `get.php` link, Plozz first accepts a real
playlist; if the response is not a playlist or the endpoint is absent/unsupported,
it tries Xtream once on that same server using the URL's credentials or the
username/password entered under **Advanced options**. Basic-authenticated M3U
feeds remain playlists. No credentials are guessed, conflicting or incomplete
login parameters are not inferred, and authentication failures, rate limits,
network failures and cancellation do not trigger a protocol retry. The saved
account uses the detected protocol, including when reopening its connection.

The basic form includes **EPG URL (optional)**. Leave it blank to use the
provider's guide automatically; a custom URL takes priority. Additional guide
URLs and authentication remain under **Advanced options**. The old discovery
toggle is no longer shown or honored, including for existing sources. Its
serialized value remains compatible with older clients. Previously opted-out
URL accounts keep their saved channels while one background catalogue refresh
recovers playlist-declared guides; failures retain the saved catalogue and
normal retry backoff. Once discovery finishes, the active guide rechecks source
authorization and warms the recovered listings without requiring another source
reload. Old imported-file accounts whose guide addresses were
never retained require a replacement file or a custom guide URL.

Xtream and playlist playback follow provider-issued HTTP(S) redirects to
delivery servers automatically, including changing hosts/ports and URLs carrying
account credentials. No provider domain or delivery IP is hardcoded, and no
manual allowlist is required. This applies to live streams, movies, episodes,
and redirected HLS manifests, segments and keys behind the authenticated
loopback proxy. Provider-issued HTTP delivery can be unencrypted even when the
initial stream uses HTTPS; only connect providers you trust with the account.
Authorization, cookie and custom account headers are stripped when crossing
origins, including subsequent hops. Login, catalogue and guide requests retain
their stricter checks against copied credentials and HTTPS downgrades.

Event playlists can be added before their streams go live. A valid `#EXTM3U`
playlist with no entries is saved and remains in Sources with zero channels.
Refreshing Live TV or Sources checks the provider again, bypassing the IPTV
catalog's normal 30-minute cache. Newly published channels appear on refresh;
a successful empty response clears ended events without deleting the source.
Failed downloads preserve the previous catalog. Blank responses, web pages,
and lists containing only unusable entries still fail validation.

The 30-minute age is a refresh interval, not an expiry of saved channels.
Ordinary browsing, guide availability, library discovery and playback read the
last committed current-format catalogue immediately, while one background
refresh stages its replacement. A failed automatic refresh retains that data,
logs a sanitized reason and waits at least one minute before another automatic
attempt. Explicit refresh joins an in-flight refresh of the same catalogue or
starts a new one, waits for completion and reports failures without that backoff.
Cold accounts and old-format catalogues still await their required import.
Provider teardown cancels background work; cancelling one explicit waiter does
not cancel a refresh still owned by saved-catalogue readers.
`IPTVIntegrationTests` gates a slow refresh and requires saved reads within one
second; `IPTVLiveTVImportTests` checks that the actual import model publishes
channels and leaves loading before that gate opens. The opt-in physical
`PhysicalDiagnosticInputTests.testExistingLiveTVPublishesSavedChannels` observes
the foreground app, enters Live TV only through its existing navigation button
when needed, and retains its screenshot/tree without relaunching or changing
the user's preview choice, account or catalogue age.

The first-run chooser selects a provider, not a playback destination. Its
**IPTV** entry opens the playlist/provider connection form directly, just as
account management does. **Live TV** is a destination inside the app: it can
show channels from a connected media server or an IPTV provider. Server users
do not need to select IPTV to use their server's Live TV.

The provider separates live channels, movies and recognizable series/episodes.
Movies and series use ordinary paged libraries, Search, details, playback and
profile-scoped Continue Watching. Live-only accounts do not create empty movie
or TV libraries. Xtream categories become channel groups and item tags.
M3U file extensions alone never classify an entry as a movie: channels can use
MP4, WMV or other file URLs. An explicit live type takes precedence; otherwise
VOD classification uses declared types, movie/series paths, episode metadata or
a positive duration. Existing URL catalogues refresh once for revised mapping
without resetting the account; previously imported files need reimporting to
apply that mapping. Account-backed IPTV channels pass the same active-profile
authorization checks during enrollment, loading and playback.
Bracketed availability notices such as `[NO PUBLIC STREAM]` are skipped, not
resolved into fake relative channel URLs. Valid relative addresses, encoded
filenames and IPv6 streams remain supported.
Basic M3U files may contain absolute HTTP(S) URLs without `#EXTM3U` or
`#EXTINF`; unnamed entries receive a localized channel label without exposing
their URL credentials. Their identity does not depend on playlist order.
Headerless `#EXTINF` entries still support relative URLs; arbitrary bare text
does not become a relative stream. Malformed extended entries remain skipped,
and HLS segments/renditions never become individual channels. `#EXTGRP` supplies
persistent default groups until changed or cleared, while an entry's
`group-title` overrides those defaults for that entry.

Playlist `user-agent`/`referrer` attributes (including HTTP-prefixed aliases),
`#EXTVLCOPT`, and URL pipe headers share the same bounded header validation.
Precedence is entry attributes, then following VLC directives, then URL pipe
headers; none leak to the next entry or into playlist-download requests.
Kodi inputstream/DRM properties are not executable player configuration.
Account catalogues retain `tvg-name` and country metadata for XMLTV matching,
without relaxing the existing station/region checks or accepting name-only
guesses. Existing URL accounts refresh once for the new mapping; imported files
need reimporting to recover previously discarded metadata.

Explicit XMLTV guides are ordered, with separate first-guide-origin headers;
Xtream otherwise uses its native guide API, falling back to its `xmltv.php`
for channels with empty, malformed or unsupported API listings. Successful
native listings are retained. Working explicit guides remain preferred. If an
explicit Xtream guide returns HTTP 404, other configured guides are tried in
order before one attempt at the account's standard `xmltv.php` for uncovered
channels. A default URL already in the configured list is not requested again.
Its successful partial or empty result is retained rather than treated as a
missing endpoint.
This recovery does not fan out into per-channel native API requests, does not
apply to playlist/file accounts, and does not replace a working but empty guide.
An unavailable endpoint is not retried once per remaining channel in the batch.
Authentication failures, rate limits, transport failures and ordinary server
errors remain visible rather than triggering another request path; a failed
XMLTV fallback also remains an error. Playlist-declared HTTP(S) guide URLs load
automatically, including guides hosted on another server, scheme, or port.
Each guide is requested at its declared address without copying the playlist's
query credentials. Account headers stay scoped to their configured origin;
the standalone source loader does not share cookies or stored HTTP credentials.
Guide redirects retain their existing transport safeguards.
Confirmed XMLTV 404s are reused only within the current provider's refresh,
across its channel/window batches. Every new refresh can retry immediately;
neither another account nor a later refresh inherits those failures. Diagnostics
distinguish a reused failure from a new HTTP request. Successful document caching
retains one account-scoped response per provider instance for at most 60 seconds,
honoring shorter max-age, no-cache and no-store. Bodies up to 16 MiB remain in
memory; larger permitted bodies (up to the existing 256 MiB download limit) use an unlinked temporary
file mapping. Expiry and teardown release the cache without requiring another
request. This avoids downloading a large guide again for each channel batch;
matching and parsing still run separately for each batch. Initial download
assembly still uses Data. Backing failures are logged and leave a valid response
uncached rather than failing its guide import.
XMLTV accepts minute- or second-precision programme timestamps, compact and
colon-separated numeric timezone offsets, and the unambiguous UTC/GMT/Z labels.
Absent zones mean UTC. Calendar and offset validation remains strict; coarser
dates and ambiguous regional timezone abbreviations do not invent airtimes.
Programme-only feeds can supply exact channel IDs without invented display names
or relaxed station matching. Repeated channel declarations with the same exact
ID combine distinct display names in source order, rather than rejecting the
whole guide. Different IDs remain separate and ambiguous names do not establish
a match. Referenced IDs and declared channels share the channel/text budgets;
repeated declarations still count toward the declaration limit. Declarations
with missing, empty or whitespace-only IDs are skipped without inventing an
identity; they still count toward declaration limits and their display names
remain subject to text limits. Other channels and programme-only IDs remain usable.

Programme titles, subtitles and descriptions select the first nonempty variant
in the requested language, then untagged text, then the first nonempty variant.
The default is the device language, independent of the profile's UI-language
override and audio/subtitle preferences. Matching reuses the shared ISO-639
normalization, including two/three-letter codes and regional variants. Empty
variants never erase usable text. Indexed guide settings include the normalized
language and parser version so old selections cannot pass cache-restore checks.

XML remains strict: malformed markup, unknown entities, external/internal entity
declarations and exhausted resource budgets fail the import, not a partial-success
fallback. Standard external DOCTYPEs do not fetch their DTD. Harmless entity-like
text in comments, processing instructions and CDATA is not a declaration.
`XMLTV_PARSE` diagnostics identify the failing pass, a closed-vocabulary reason,
numeric parser code, line/column and channel/programme counts. They never include
XML fragments, station names, URLs or native error descriptions. Compatible
duplicate and skipped declarations are reported once per metadata pass as counts.
Playlist and imported-file accounts without an explicit or playlist-declared
guide immediately report no guide capability. Both platforms show "No program
guide available" and skip guide warmup and browsing requests instead of showing
"Loading guide...". Channels remain playable. Configured feeds and Xtream retain
real loading, empty-listing and failure states; an empty response does not disable
their guide capability.

Catalogue imports stream into encrypted SQLite staging, not a retained
document or a giant array of media items. They have no legacy 128 MiB document
or 100,000-entry cutoff. Individual lines/records, guide documents and playback
manifests remain bounded; malformed data, unsupported protocols, exhausted
storage and provider errors remain explicit failures. Movies and series are
decoded by page; the guide still holds lightweight channel values for its full
lineup. This is not a claim of unlimited device memory or measured performance
on every older device.

First-import identity generation reuses the same lowercase digest encoder as
durable Live TV identities and compiles the episode-name expression once.
Digest inputs, IDs, classification, encrypted records and atomic catalogue
replacement are unchanged. The opt-in `IPTVPerformanceProbeTests` accepts only
an owned loopback replay through `.build/iptv-performance-source.json` (`url`
and `entries`). It reports reading/staging and final commit time separately.
Optional `verifyRecords: true` computes a sorted-key fingerprint of every
decrypted record, without printing its contents; `expectedRecordDigest` checks
that fingerprint against a baseline. Fingerprinting happens after timing.

An optimized tvOS simulator comparison used two separately captured 102.6 MB
responses with 382,408 entries each (382,407 accepted and one skipped). Fresh
local replay imports took 91–95 seconds before these changes and 63–66 seconds
afterward, with identical per-source fingerprints across all 413,265 resulting
records, including series and seasons. Faster digest formatting supplied most
of the gain; expression reuse reduced the reading stage further. The one-time
upstream downloads separately took 24–30 seconds, including 18–24 seconds before
headers. These small-sample replay measurements isolate app-side work; they
are not end-to-end provider timings or physical-device guarantees.

`IPTVScaleAndRecoveryTests` exercises an 800,005-entry, 50 MB HTTP playlist
through sign-in, encrypted catalogue commit, session restoration and final-page
queries. The fixture includes 2,000 live channels and 798,005 movies. It also
checks interrupted downloads and truncated Xtream arrays beyond 2,000 rows:
failed refreshes preserve the previous catalogue, and complete retries replace it.
These are simulator integration checks, not a reproduction of an unavailable
provider playlist or physical-device performance guarantees.

IPTV HTTP teardown closes request admission before invalidating its session.
Requests still creating their native URLSession tasks are cancelled and drained
first; delivered response bodies are cancelled by final invalidation. Late
callers receive cancellation, not an Objective-C invalidated-session exception.
Cancelling one caller does not close the session for other callers.

Opening Settings also restores each authorized IPTV account's committed channel
catalogue, not just standalone playlist caches. This cache-only operation does
not authenticate, refresh channels, fetch programme listings, or tune a stream.
It distinguishes a missing catalogue from a successfully imported empty lineup
and rechecks profile/account authority after asynchronous work. Reopening
Settings therefore shows the saved channel count rather than "Ready to load"
after a successful account import. Upstream authentication/access refusals are
reported as provider permission failures rather than missing profile membership;
local account/profile authorization checks are unchanged.

The mounted Live TV destination suspends catalogue loading while profile
authorization is unavailable and resumes it when setup or unlocking completes.
New account enrollment and saved channels recover without reopening the tab,
while genuine profile, parental-approval, and server-permission checks remain.

The shared live-channel publication path normalizes each matching name once,
rather than during every sort comparison, and collects language/country facets
from distinct metadata values. It avoids full-lineup copies for absent overrides
and indexes only the visible recent/favorite shortcuts it needs. Sorting moves
lightweight browse keys instead of full channel records. Catalogue and guide
lookups share their immutable presentation arrays and index IDs to ordinals,
rather than duplicating every record in dictionaries; guide sections are assembled
in one reserved array. Publication remains synchronous and validates the complete
replacement before changing the current catalogue. This preserves
all channels, search relevance, ID tie-breaks and profile filters; it does not
cap the lineup. `LiveTVLargePlaylistHostedTests` measures the synchronous
publication of 10,000 and 100,000 channels in both sort orders with a one-second
budget. That focused budget is not an end-to-end import, memory, frame-pacing,
or older-hardware guarantee.

Private URLs and authentication headers remain in Keychain credentials and
encrypted catalogue records. Playback uses an account/revision/session-fenced
locator and a provider-owned loopback proxy. It forwards authorized headers
only to the original origin, rewrites HLS playlists and supports byte ranges.
Opaque proxy paths preserve only verified `m3u8`, `ts`, `m2ts`, and `mts`
suffixes, never original filenames. The suffix must agree with the encrypted
upstream URL. Known raw transport-stream URLs use Aether's regular live-source
path rather than its HLS-only native bypass; HLS retains native playback,
including fragmented MP4. Hosted tests require a rendered frame and advancing
time through the authenticated proxy on both platforms. Opaque or otherwise
undeclared HTTP addresses receive a bounded content check before engine loading:
at most 1,024 consumed bytes and a 15-second request/resource deadline. Manifest
bytes select native HLS (including fragmented MP4); framed MPEG-TS selects raw
ingest, regardless of a missing or generic MIME type. Other bytes go to Aether's
container probe rather than being assumed to be HLS. The check closes before
playback opens its request, so it adds a sequential request for these addresses,
not a simultaneous provider stream. It applies to legacy direct HTTP channels
as well as account-backed proxy URLs; declared formats skip the extra check.
Cancellation or replacement retires the owned check, and an HTTP refusal is
reported rather than retried on another route.
The proxy observes player disconnects while waiting for upstream headers or
body data, cancels its native HTTP tasks, and drains owned request work on close.
Within one live proxy, root requests are serialized so duplicate player probes
cannot open two long-lived channel streams. HLS child resources remain
independent. An IPTV channel replacement waits for prior owned lease cleanup
before publishing its URL to the player; intentional multiview panes keep their
separate ownership.

Preview/Watch admission is separate from its presentation commit. Admission
rejects stale intent before stopping an existing stream; after cleanup, current
intent and authority are rechecked, then the UI commit and replacement
publication run without an intervening suspension. In particular, clearing a
preview's `pendingRequest` must not cancel its SwiftUI task during cleanup or
let an old-player teardown erase the replacement's selected channel.

Upstream HTTP failures retain their status with an empty, sanitized response.
Authentication, access-block, and rate-limit refusals are latched for that proxy
so native retries cannot repeatedly contact a rejecting provider. HTTP 451 is
an access restriction, not evidence of an invalid password or a codec failure.
The live engine retains this typed refusal for the current playback attempt
even if AVFoundation later reports a generic load failure. These safeguards do
not add automatic channel reconnects or guess another output format, guarantee
that the provider immediately releases its connection slot, or enforce a
subscription limit across different devices.

Ambient cookies and credential stores are disabled. HTTP remains unencrypted;
use HTTPS when available. HLS/file playback does not establish DRM, DASH,
browser-login, or remote AirPlay receiver support. Credential-protected artwork
is not currently resolved; credential-bearing artwork URLs are not published
into ordinary item caches.

**Settings > Servers > account > Edit connection** reconnects an account without
changing its account identity or losing profile watch state. New credentials
use a fresh encrypted catalogue; the existing connection is replaced only
after authentication/import and persistence succeed. A removed account,
changed credential revision or switched profile invalidates an in-flight form.

Existing legacy sources remain intact. Their details offer **Connect as IPTV
account** for URL sources, preserving the name, URL and guide order.
This is additive, not an automatic migration: disable the old source
after connecting to avoid duplicate channels. Existing source approvals,
favorites and manual guide mappings are not silently reassigned. Legacy source
editors and encrypted imported-file archives retain their existing bounds and
compatibility; new account/file imports use the disk-backed path.

Source setup appears only after the initial source reload, server enrollment,
and library-catalog restoration have established that there are no channels.
Onboarding reveals the same full-page background as the guide instead of painting
an inset Settings-colored panel. On tvOS, the page owns the gradient behind the
top navigation and source choices; empty setup has no video-legibility scrim.
Source choices use the shared detail-card controls and page-aligned gradient
surface, with solid fills when gradients or transparency are disabled.
On iPhone and iPad, source icons use the theme accent; server-enrollment status
sits below a divider as secondary context.
Light, dark, black, and the gradient-background preference remain respected.
Pending catalogs keep the page layout in place with non-focusable skeletons for
the info artwork/text, category column, channel logos, and programme cells. They
share the loaded guide's sizes/insets and Home's neutral fills/shimmer, including
Reduce Motion behavior; normal startup never replaces the page with a loading
message. The storage-opening stage uses that same layout. Already-loaded
channels remain browsable while other sources finish. Library failures use the
unavailable state and can retry both library and external sources.
On Apple TV, the pinned guide's horizontal gutter is measured from the physical
viewport, like the rail itself, so title-safe-area changes during entry do not
shift or resize the skeleton or loaded guide.
The shell keeps this clearance while Live TV temporarily suppresses navigation
to focus its first channel or restore guide focus. Navigation visibility and input
remain gated; the full-screen video and native Search use their own full bounds.
The guide background still reaches the trailing screen edge, but channel and
programme controls retain the guide's inner gutter on both sides so their focus
outline stays fully visible, including in right-to-left layouts.
An empty configuration does not contact a public feed or play an unsolicited
channel. Add your own M3U playlist or use an authorized
connected server. Plozz does not provide or offer a public channel catalog.
Setup uses matching source cards with an icon, description and explicit action.
Cards share their width and height in a row, and stack when space or larger text
requires it. Plozz channels uses the same card treatment for its automatic
library-lineup enable flow; custom channel creation is secondary.
Enabled sources are combined;
adding one does not replace another. Channels become available before guide
loading finishes. There is one unified
channel guide, not separate Channels and Guide tabs. It groups up to three
**Recently watched** channels first, then **Favorites**, then the full filtered
channel list. Empty groups are omitted. Recent and Favorite entries are
independent shortcuts: a channel can appear in both and always remains in the
main list. Each section/channel occurrence has its own stable row and focus ID.
Search, categories and view filters apply across every group.
Search, categories, sorting and Favorites survive opening the player,
returning to the guide and refreshing sources.
Favorites and recent channels are saved per Plozz profile and restored across
sessions. Initially empty or temporarily unavailable source catalogs do not
erase saved IDs. Unreadable preferences are not overwritten, and failed writes
offer a retry rather than displaying an unsaved change as successful.
Search text remains session-scoped; browse selections are saved locally with
the profile. Playlist addresses, optional guide
addresses and their order, source names, and enabled states are stored securely
per profile. Server sources store an account reference, not duplicate credentials.
View preferences and source management live in **Settings > Live TV**.
**TV sources** is the first section on the Live TV settings page on both
platforms, with a regular-sized **Add source** button in its header. Saved
sources open directly from this page; there is no separate Sources drill-in or
truncated list with an All sources row. Up to four sources use their natural
height. Longer lists reuse `FadingScrollView`, measuring the rows to show four
complete sources and half the fifth with the existing directional edge fade.
Long names and source errors contribute to the measured height rather than
being clipped. Scrolling or remote focus reaches every source without moving
the following settings down by the full list height.
Saved sources use icon/name/status rows instead of repeating every control and hostname.
Provider/type and status share one secondary line, with compact row insets rather
than another full layer of group padding. Long content can still wrap.
Playlist icons optionally load the source origin's favicon, with a generic
fallback; no playlist credentials or third-party favicon service are used.
Connected media servers reuse `ProviderBrandMark`, including the same Plex,
Jellyfin, and Emby logos and focus-aware colors used elsewhere in Settings.
Their identity comes from the active profile's account metadata, not their
user-entered name or a credential lookup while rendering. Unavailable account
metadata retains the generic server icon.
Each source opens its controls and diagnostics on a child page with Back.
**Plozz channels** follows the sources, with the guarded **Auto-create channels from
your libraries** switch and a separate **Manage channels** action. The toggle label
explains the action directly, without a detached section footer. Turning automatic
channels off leaves custom channels available. **Guide & browsing** labels its root picker
**Live TV opens to**, with Categories or Guide as its value. **Channel order** is
also a root-level menu, offering Channel number or Name without opening a child
page. Guide preferences and channel visibility have child pages. Single-line
TV navigation and menu rows share the standard form height; configured source
rows retain their compact sizing. Mobile retains its network playback preference. **Tools** contains
source refresh, channel availability checks, and guide coverage when applicable.
Source management remains PIN-protected while ordinary browsing preferences stay
available without unlocking source mutations. On Apple TV, child pages stay
inside the Settings workspace. Custom channel creation/editing and save dismissal
use the same page navigation.
The guide's separate Sources presentation also opens channel checks directly,
without requiring Plozz channels to be available or open first.
On tvOS, Generated channels is a bounded scrolling group with focusable,
read-only rows. It shows four full rows and half of the next row to hint at more
content; Up/Down browses the lineup and leaves it at either end.
Custom-channel actions and menus use the shared form sizing, and Source
libraries uses the same multi-select check rows as other Settings pages.
Genre and ordering rules are explicit controls, without a one-off Comedy preset.
Guide lookback/lookahead use native value menus on TV so all day choices fit
the fixed detail column without overflowing horizontal pills.
Child pages inherit the workspace background rather than drawing a second
gradient. Hidden-channel restoration also lives in its detail pane.
Setup and source pages reuse Plozz's shared settings groups, row labels,
switches, focus/card styles and page heading.

**Manage IPTV channels** is available from Categories on mobile and Manage
channels in the TV sidebar. Category choices are scoped to the configured
source and profile, so equally named groups from different sources stay separate.
Automatic follows the regional filter, Show overrides it, and Hide excludes the
category. A hidden membership wins when a channel belongs to several categories;
an individual Show channel exception wins over category/regional filtering.
Manual channel hiding and scan exclusions remain separate.

Management links use shared disclosure labels with group-owned padding.
Visibility uses a native menu on iPhone/iPad and a disclosed selection page
on TV. Hidden-channel recovery uses native secondary action buttons aligned
to the trailing edge; narrow widths and large text place the action below the
description rather than squeezing it.

The optional regional filter includes channels matching **any selected country
OR language**. It uses supplied tags, normalizing known codes/English names, not
guesses from channel names. Nonmatching and untagged channels appear in the
searchable **Hidden channels** page with a reason and a Show channel action.
Nothing is deleted. Reset category and region visibility retains individual
hidden channels, scan exclusions, and favorites. Settings also offers this reset.
Non-IPTV providers are not region-filtered.

Favorite category follows membership after refresh without writing a favorite
record for every channel. Individual favorites survive unfavoriting a category;
individually removed favorites remain exceptions. Rules follow new channels in
the same category, while a renamed category is a new choice. Category, region,
and individual exception choices participate in the existing profile-scoped
Live TV sync; browse filters and recent playback remain local. Hidden channels
are excluded from guide/search, pickers, and Home without stopping playback
already deliberately started.

On iPhone/iPad, Sources and its grouped detail pages use a scroll-based settings
surface rather than embedding multiple navigation links in one native List cell.
Saved sources appear first as compact icon/name/status rows. Each opens its own
page for enabling, editing, checking and removing that source; guide policy and
diagnostics sit behind named links rather than expanding every source inline.
Each tap pushes only its selected destination, and Back returns one level.
This applies to both Settings and the Live TV toolbar's Sources entry.
Channel, guide and access failures appear beside the affected enabled source,
using the shared theme-aware inline error style and naming failed guides.
On mobile, the source row, error and Retry stay together as one item, including
inside the bounded settings list.
Retry shows an inline loading spinner and label, prevents duplicate taps, and
briefly retains feedback even when the provider refuses the request immediately.
During a source Retry, that inline indicator replaces the source's loading
subtitle and page-wide loading indicators instead of showing duplicate spinners.
Source Retry refreshes only that playlist and its guides, or that server; it
preserves other sources' channels, errors and in-flight server-guide requests.
The source detail page offers the same error and Retry. Page-wide storage,
configuration, enrollment and profile-access failures appear above the source
list rather than in a duplicate generic footer. Provider access errors are
reported as received, not interpreted as proof that an IPTV trial expired.
When embedded in a native List, the iPhone/iPad Sources pane clears its row's
background, separator, and extra insets, so the shared settings gradient and
group keylines continue through the whole page rather than an opaque inner panel.
The mobile welcome screen uses compact, whole-row choices instead of tall cards
with duplicate action footers. Source cards use the detail page's shared adaptive
surface: a theme-aware gradient wash and edge, or an opaque surface when gradients
or transparency are disabled. IPTV setup uses the same settings-page background
as the other setup sheets. The media-server choice identifies Jellyfin, Emby, and
Plex without implying Plex is limited to guide listings. Actual server setup,
permissions, and playback availability are checked during enrollment and tuning.
Modal sheets have an icon-only Close control,
distinct from the form's Add/Save action. Source choices cover playlist URLs,
local files (iPhone/iPad), and connected media servers. Playlist fields keep their
labels visible while editing and show example URLs instead of repeating labels
as URL placeholders. Primary setup actions use full-width Settings rows with
at least 64-point height on Apple TV and 44-point height on iPhone/iPad; removing
a guide is a labeled action beside its URL on Apple TV and an accessible
44-point icon button beside the field on iPhone/iPad. New playlists start with
no guide fields; Add guide reveals the first, then Add another guide reveals
additional fields. Existing guides remain visible when editing. Guide mapping
on mobile is offered only when explicit or discovered guides exist. Both playlist editors
limit guide fields to 32 and retain explicit guide priority. Adding a URL still
checks and saves in one action; canceling or failing validation writes nothing.
Add/save/import and server-check actions use the app's filled primary pill,
with the palette's inverse text color, so the next step stays visible even
without focus. Canceling a check uses the secondary treatment.
The Add a source section uses concise playlist-URL, local-file and supported-server
labels rather than repeating the section's action in a subtitle.

Rendering source choices does not resolve server credentials. Profile account
selections are observable model snapshots, read back from durable storage after
membership writes and refreshed when profiles are imported or reset. An unset
selection remains distinct from an explicitly empty selection.
An unreadable membership suspends account access rather than inheriting the
household account set. Account reload and foreground recovery retry only
unconfirmed selections; rendering never retries Keychain. Cloud capture retains
the previous membership record during that failure, and setup transfer waits
for confirmed selections instead of exporting a temporary access denial.
Catalog display state checks the current in-memory profile/account admission without reopening
the secure source store. This display state is not an operation permit: catalog
publication, scans, imports and mutations retain their fresh durable-source and
parental-authorization checks.
Sources admission compares actual playlist/server settings and current authorization,
not the Cloud sync checkpoint stored alongside them. A checkpoint-only write must
not revoke an open Sources page, discard a pending channel refresh, or stop channel
checks. Checkpoints remain intact in secure storage; real source edits, account
changes, profile locks and parental-approval revocations still invalidate old work.
An open Sources page also observes profile-scoped local and synced source changes.
If a real configuration change invalidates its snapshot, it cancels the old work
and restores the newly authorized cached catalogue without requiring Retry or
reopening. Changes while inactive wait for normal presentation admission; they
never bypass a profile lock or re-enable a deliberately disabled source.
App and Sources admission use the same provider-aware identity check: only an
active, locally present Plex account can owe a server-user choice. Sync can
record pending questions before an account's provider is known; a marker that
later resolves to IPTV, Jellyfin, Emby, Silo or a network share must not block
Live TV. These markers remain stored, and genuine Plex questions still gate
access until answered; no identity or PIN requirement is cleared by this check.
Diagnostic builds record Sources admission transitions and rejection stages in
the bounded `HandoffDiagnostics` journal under `SOURCES`. These distinguish app
entry gates, runtime invalidation and changed catalogue authority without logging
profile/account names, identifiers, credentials or source addresses. The mobile
Settings host also records which app-entry conditions are pending.
Earlier prototype builds did not store Favorites or Recents on disk, so there
is no prior in-memory history to migrate on the first updated launch.

- Browse, search names/numbers/categories/sources, filter and sort.
  Live TV opens to Categories by default. The profile-scoped **Live TV opens to**
  preference in Settings > Live TV can select Guide instead.
  Narrow windows show a grid of category tiles and an All channels tile, each
  with its eligible channel count. Selecting a tile opens that category's guide
  without tuning; Categories returns to the directory and its previous position.
  Counts exclude hidden/filtered channels, deduplicate multi-group membership,
  and do not change with the current search query or selected category.
  Eligibility/catalog changes refresh counts; category/query changes reuse them.
- Select a channel logo to open its Play, Favorite and Hide actions. The
  right-hand programme/channel-name area plays directly; long-press actions
  remain available there.
  Hidden channels are excluded from Search and every guide section for this
  profile. Restore them in Settings > Live TV > Hidden channels. Hiding retains
  their favorite/recent metadata and source data, and does not end deliberate
  playback. After hiding, focus goes to the next remaining row, or the previous
  row when the hidden row was last; another occurrence of that channel is not
  a replacement. An all-hidden catalog explains where to restore channels.
- Search transforms the current screen rather than opening a second results
  dialog. Apple TV uses the native inline search keyboard above the familiar
  channel/programme rows; mobile uses a standard native search field without
  reserving the hero's height. The narrow category directory includes this field
  directly above the tiles.
  Both use the same query and filtered catalog, not an extra eight-result list.
  Channel search also shows matching categories above its channel results.
  Category matches use the same active browse filters and hidden-channel rules;
  a channel-name match alone does not make its unrelated category a result.
  Selecting a category closes Search and opens that category at the first guide
  row without tuning a channel. Back without selecting a category still restores
  the previous guide position. Program search remains a separate scope.
  On TV, the guide and Search use `PrototypeNativeGuideList`, a native collection
  view that recycles visible rows while retaining the shared SwiftUI row controls.
  The focus engine no longer traverses a full-catalog set of synthetic lazy-stack
  placeholders. Each row has its own hosting boundary, preserving the logo/programme
  focus column and keeping keyboard-collapse scrolling aimed at the actual row.
  Stable row identities and cached row configuration avoid rebuilding unrelated
  rows as focus moves. The native layout computes frames only for the requested
  viewport, using the guide's shared Dynamic Type-scaled row and section-label
  metrics. It can jump directly into a 100,000-row catalog without a synchronous
  full-catalog self-sizing layout pass. Guide lookup indices are refreshed
  with catalog/filter changes, not rebuilt for every scroll callback.
  Guide-window preparation uses those indices for the current occurrence instead
  of scanning from row zero. A removed Recent/Favorite occurrence still falls
  back to the first remaining occurrence. Server authorization and guide mapping
  lookups inspect only the requested 12/48-row neighborhood, not every channel's
  reference or mapping, including while the category pane opens.
  Category selection uses normalized category-to-channel offsets built with the
  catalog/facets. Multi-group aliases do not duplicate channels; hiding, scan
  exclusions, metadata overrides and catalog replacement refresh the index.
  The large-catalog regressions cover repeated selection and deep neighborhood
  lookup; simulator timing does not establish physical-TV frame pacing.
  The current category remains identified. Leaving Search restores the
  original guide occurrence and time position; the video stays in the same player.
  On Apple TV, Back works from both the native keyboard and the results.
  Completing programme-focus restoration retains that focus; it must not request
  another native Search focus update that sends selection back to a different row.
  Search has a full-screen, transparent navigation host rather than an inset
  sheet. The old guide fades away, then the native search surface fades in
  without sliding down; closing reverses that handoff. Reduce Motion removes
  the fade timing. Temporarily opening playback or another sheet hides Search
  without discarding its query or results host.
  App navigation is suppressed before the TV keyboard opens and stays suppressed
  through closing and guide-focus restoration, so Back does not briefly open the
  native navigation menu or pinned rail.
  Live TV is the root of its native navigation stack, with no hidden empty page
  for Back to expose. Its shell sends Search/playback chrome visibility directly
  to that owning stack, restoring native navigation while browsing. With native
  navigation, watching uses a real fullscreen presentation above the tab shell,
  rather than relying on a root toolbar preference to hide its menu chip.
  The existing playback owner transfers the same engine's output view into
  that presentation and back; it does not create another engine or reload the
  channel. Pending startup survives the handoff. Presentation does not slide
  the picture in, and dismissal restores the retained guide before restoring
  its focus. The custom pinned rail
  retains its existing chrome coordinator.
  Live TV also participates in the profile's Hide or Reorder Navigation list,
  alongside Home, Search and the other destinations. Settings remains visible
  but can be moved. Press-and-hold Hide keeps focus at the vacated list position;
  Move Up/Down follows the moved item.
  Pinned navigation reveals its selected row before requesting native focus,
  including Settings or another destination below a long list's visible area.
  An open request expands the complete panel instead of leaving a thin backing
  at collapsed width. Collapsed icons have no panel behind them.
- Wide screens pin Search and an independently scrolling category list
  to the left of the guide. Search never scrolls away
  with either list. Select a category directly; Right enters its guide.
  Mobile windows with at least 700 points of content width and 500 of content
  height use the sidebar, including roomy phone layouts. Narrow iPad windows and
  short landscape windows use the same category directory as narrow phones.
  On iOS, Guide, Filters and the profile action share the native navigation
  toolbar and its system Liquid Glass grouping. Browse actions use standard
  native button sizes rather than custom circular controls. The native search
  text field, category heading and tile grid share one content keyline; category
  columns and rows use the same gap. Only the timeline guide uses edge bleed.
  Narrow guides expose Search, Filters and Multiviews directly, without a Now
  shortcut or a one-item More menu. The iPhone's channel-guide subpage omits the
  profile action, which remains on its Categories page; iPad and wide sidebar
  layouts retain it.
  Apple TV reserves 384 points for categories on wide layouts and 320 on narrower
  sidebar layouts, without shrinking category text. Mobile sidebars use
  200, 224, or 272 points according to available width.
  Its sidebar runs the full content height, beside both the channel details and
  guide. Loading and loaded layouts use the same two-column container.
  The category panel remains visible when native focus enters the TV guide;
  channel details and the mounted guide keep their geometry, channel,
  vertical position, and time. A leading-edge move out of the guide focuses the
  selected category. Back belongs to native app navigation. Internal
  programme-to-programme moves keep their normal timeline behavior.
  Once a category-entry focus request completes, transient focus loss during
  native fast scrolling must not re-arm its eligibility gate. Only a new
  entry request or a real native focus departure to another region may gate
  the other controls; otherwise an offscreen selected category can leave every
  visible category disabled. Real menu round trips still restore the selected
  category before releasing that gate.
  Left/Right continues across the guide normally. Exactly one leading press
  from the far-left channel column (far-right in RTL) must enter categories,
  without entering them early or also opening app navigation.
  A separate leading press from the panel should reach the app menu.
  The guide's boundary recognizer gives ancestor horizontal navigation
  recognizers a failure dependency: they wait until the guide decides whether
  it owns the press. Otherwise window-level navigation can begin before the
  guide receives the press and expand over the focused category. Non-boundary
  input fails immediately, preserving normal guide navigation; boundary input
  remains owned through release.
  Remote regressions use the production destination handoff and full native
  tab layout, checking ordinary, rapid, and held input in both directions and
  with preview enabled and a non-default category selected. A native-focus counter
  detects transient focus theft;
  screenshots must also be checked for expansion without a focus change.
  The opt-in `PhysicalDiagnosticInputTests/testExistingLiveTVRevealsOnlyCategories`
  checks the existing foreground app without installing, relaunching, selecting
  channels, or changing settings; enable it only in an agreed physical testing window.
  With pinned navigation visible, the Live TV controls also clear its title-safe
  margin; native top-bar/sidebar styles keep their tighter leading spacing.
  The selected category uses a checkmark rather than a second focused-looking
  box. Favorites are grouped in the guide, not a separate sidebar button.
  The More menu is gone: sorting, Auto preview, Favorites-only and guide-only
  preferences are in Settings > Live TV. Sources and Guide time remain
  directly available through channel/programme context menus; failed or empty
  imports also expose Sources beside Retry.
  On Apple TV, each profile is asked about live previews on its first Live TV visit
  with available channels. "Turn on previews" initially has native focus, but no
  automatic playback starts until it is selected. "Keep previews off" and Back
  both keep previews off and complete the choice. Settings > Live TV > Auto preview
  can change the choice later. The completion flag is profile-scoped and independent
  of filter saves; legacy saved values alone do not count as a choice. Inactive,
  backgrounded, or unauthorized profiles cannot answer the prompt. iPhone and iPad
  retain tap-to-play and do not show this prompt.
  On Apple TV, Back from a guide row focuses Search without scrolling the list.
  Back from the controls goes to the
  surrounding app navigation. Holding Select on a channel/program also opens
  its context menu with Search channels, Sources, Guide time when available,
  and Back to top. The sidebar's bottom clock remains removed.
  The channel/program context-menu Back to top action remains and does not
  reset the selected time.
- Compact category choices use an explicit navigation list with checkmarked
  selections, not nested system Picker presentations inside a sheet. Sorting
  uses the app's standard Settings controls.
- The guide sits in one rounded tray with roomier channel rows and
  quieter programme tiles. Logo plates, channel tiles and the outer tray use
  concentric radii derived from their insets. TV rows are 128 points tall,
  with full-height 200 x 128-point logo plates and 16-point row spacing.
  On first entry, focus moves to the first available channel's current programme
  to the right of its logo. With no guide data, the channel-name area remains
  separately focusable and playable. Missing-listing gaps have their own focus
  identities rather than pretending to be programmes. Subsequent playback/Search
  returns keep their remembered row; an explicit visit to a logo is still
  preserved when returning from browsing controls.
  The backing fills the complete station focus bounds, with the same corner
  radius and no outside gutter. Artwork fits inside without stretching, with
  eight additional points of inner padding; the full-height plate stays unchanged.
  Guide, Search, preview metadata and the player use the same `ChannelLogoArtwork`
  component. Solid logo plates replace the gradients that faded into the page.
  Detected source backings are extended unchanged, including white boxes inside
  transparent margins. Otherwise a restrained, desaturated brand tint sits over
  a light or charcoal plate; even a small bright wordmark can require charcoal.
  A quiet perimeter stroke keeps
  the plate boundary visible. Brand pixels are not recoloured or haloed.
  The existing shared hero preparation cache and synchronous memo resolve the
  logo and its backing together, so a warmed guide logo appears immediately in
  the player with the same appearance. Hero/search/player sizes remain
  independent of the full-row guide treatment.
  Plozz library channels without supplied artwork use the locally rendered Byline:
  a prominent, original-case channel name above a small pixel-mascot and Plozz
  signature. Both share an inset leading edge; the signature is lifted away
  from the bottom corner. Category moods tint the active theme's opaque surface:
  cinematic blue, playful amber, calm green, warm rose, intense terracotta,
  mysterious plum, and imaginative indigo. Light, Dark, and Black keep their
  own surface and text contrast, including increased-contrast borders.
  Automatic group keys and custom recipe genres determine the mood, never
  translated or renamed display titles, current programmes, or provider order.
  Unrecognized categories and mixed custom moods use a neutral field; unfiltered
  movie-only channels use cinematic blue. Studio/director channels use cinematic
  blue without guessing their content, and decade channels use warm rose.
  The guide and player carry the same mood to the shared renderer. No saved
  channel identity, schedule, recipe, or sync format is changed by this styling.
  Real source logos still take precedence; missing
  external-channel logos keep their ordinary name fallback. No network service,
  generated image asset or per-channel manual design is needed.
  Station tiles show only the logo, or a name fallback when artwork is missing,
  rather than repeating names, numbers and badges beside it. Names and numbers
  remain searchable and available to accessibility; the focused channel's name
  and full programme title remain in the hero.
  No second surface surrounds the logo backing. Programme surfaces are quieter,
  with lighter-weight 26-point TV titles and the standard Plozz system font,
  not a separate rounded face.
  A small Liquid Glass surface anchors Search on the left; compact windows
  retain the glass control group. Programme cells do not create individual glass
  surfaces. Glass reduction preferences and Reduce Transparency use the existing shared
  fallbacks. Guide focus uses a crisp rounded outline and tonal fill, with a
  solid high-contrast treatment under increased contrast or Reduce Transparency.
  Focus outlines pair a bright outer edge with a dark inner keyline so white
  artwork cannot hide focus. Both strokes sit inside the existing rounded bounds,
  with no extra gutter, and strengthen under increased contrast.
  Focus and selection never swap the button's structural identity.
- The preview spans the screen width behind the upper guide. One continuous
  fade reaches the page colour before the video's lower edge; the date/time
  header no longer starts an opaque panel. The tray begins at five percent
  opacity rather than disappearing completely, then grows more opaque lower
  down, with a solid fallback for Reduce Transparency or increased contrast.
  A compact, noninteractive Now pointer sits just below the fixed time ruler,
  with a small shadow for contrast rather than a line through the channel rows.
  A subtle fill marks elapsed time inside programme cells, no-guide rows and
  gaps between listings, staying aligned with the pointer when the timeline
  scrolls. The pointer disappears when the current time is outside the visible
  window. Wide guides retain the time ruler and pointer even when
  no channel has listings. On no-guide rows this indicates elapsed clock time,
  not a known programme duration; channel names remain stationary. Compact
  channel-only layouts without a time ruler do not imply programme progress.
  Shared smooth edge masks dissolve rows underneath the fixed time header and
  programme cells at the horizontal viewport edges. The guide has no bottom
  fade and extends to the TV screen's bottom and trailing edges in both Search
  and normal browsing, without a trailing gutter or rounded trailing edge;
  the sidebar controls retain their safe inset. Touch layouts retain their
  bottom safe-area clearance. Each remaining fade ramps in only
  when content extends beyond that edge, keeping reached endpoints readable.
  Programme containers match the full height and corner radius of their station
  logo plates. Row spacing still separates channels; time widths and inner text
  padding are unchanged.
- **Sources** adds, edits, pauses and removes playlists and connected servers.
  Playlist checks finish before saving, and stale editors cannot overwrite a
  newer source. Guides are optional and can be added, removed or reordered later.
  The address can describe an M3U channel list or a direct HLS stream. A direct
  master or media manifest imports one channel, not one channel per segment.
  Channel-list entries can also point to HLS streams.
  Playlist downloads parse incrementally, with bounded line buffering rather
  than a retained raw response, full decoded string and split-line array.
  Legacy source imports accept up to 100,000 entries and 128 MiB, with a 64 KiB
  line bound. New IPTV account imports use the disk-backed path described above.
  An exact 100,000-entry network fixture exceeds the previous 20 MiB ceiling
  without truncation. Parsed response caching has a separate 64 MiB budget;
  guide bodies retain their existing limits and cannot reuse playlist validators.
  Imported files use authenticated, chunked encrypted archives and incremental
  parsing; legacy encrypted files remain readable. Failed replacements retain
  the original, and incomplete or tampered archives cannot publish a catalog.
  Source details retain playlist/skipped-entry counts, guide matches, loaded
  listings and per-feed failures; the guide overview shows loaded coverage.
  Settings restores authorized cached channels and guide statistics without
  starting network requests merely by opening Sources. Refresh sources loads
  fresh data there; source changes refresh the retained Settings catalog.
  Failed sources do not block successful ones or erase their last-good data.
  **With guide listings** filters populated channels without changing source
  authorization or stopping a hidden, deliberately watched channel.
- Guide retains all channels, even if none has a schedule. Unknown intervals
  remain honest gaps; they do not hide channels or shift later programs under
  the wrong time. Channel buttons still tune live without guide data.
  Missing listings show the channel name to the right of the logo in place of
  a program, without inventing a show title, start time or duration. Real
  listings still show their programme title. Entirely unlisted rows
  keep that label stationary rather than drawing an empty six-hour program.
  Detailed diagnostics remain in Sources, not repeated on every channel.
  A focused missing-listing row can show a loading, failed or not-yet-requested
  state. Program details identify the selected guide source.
- On wide screens, the station/logo column stays fixed while program rows scroll
  horizontally through a shared timeline. It starts at six hours and adds six
  more as the viewer nears the end, up to seven days. Rows render nearby
  programmes; guide data loads around the viewed time, not all seven days at
  once. Returning from Search restores the browsed time and its extended span.
  The time ruler stays above the vertical list and follows the same horizontal
  offset, with day labels after midnight. Its leading label identifies the
  visible channel group instead of showing a date and buttons.
  Guide time in the context menu retains the date and Earlier/Now/Later controls.
  Earlier/Later shifts the
  window from one day back through seven days ahead, subject to source coverage.
  The time anchor does not jump at the half hour while browsing; **Now** recenters
  it on the current wall clock. The header pointer tracks that same clock.
  Focused programme details above the grid show the full title and broadcast times,
  including for very narrow cells.
- Wide-guide stations, programme cells and horizontal scrollers share one scaled
  row height. Short programmes and clipped edge intervals cannot enlarge an
  entire row through timestamp wrapping, including cells outside the viewport.
  Wide cells prioritize titles rather than repeating timestamps/progress bars in
  every row; very small slices show an ellipsis. Compact touch cards retain times.
  Their time widths remain accurate, and full titles/times remain available
  through accessibility and programme details.
- iPhone and narrow iPad windows use compact rows with horizontally browsable
  program cards; no-guide rows put the channel name beside its logo.
  Video stays above the scrolling list. Touch browsing does not automatically
  open streams; selecting a channel starts playback, and returning leaves its
  preview visible. Use Watch channel to reopen playback.
- Select a channel or its currently airing program to watch real video.
  Past/future programs open details, not a pretend future broadcast.
  The live host exposes real buffering,
  failure/retry and live transport state rather than a fabricated VOD timeline.
  Recently watched records only deliberate fullscreen viewing after the matching
  source is playing and has presented video. Automatic previews, failed startup
  and stale callbacks do not count. Revisiting moves a channel to the front.
  Next/Previous snapshots the filtered guide order, deduplicated by channel, when watching starts, so
  promoting a channel into Recents cannot make transport bounce between stations.
  This channel history never writes movie/episode progress or watched status.

Straight Up/Down browsing initially enters each channel's currently airing program
(or its current guide gap), independent of how wide the previous program was.
Only the active row exposes its other programs. A deliberate Left/Right press,
horizontal focus move or timeline drag hands navigation back to tvOS's ordinary
spatial behavior. **Now**, playback's current-time restoration, or a fresh guide
restores current-program entry. Explicit focus restoration still takes priority,
and VoiceOver keeps unrestricted native navigation. No after-the-fact focus bounce
or invisible focusable target is used.

### Preview display mode and original titles

On tvOS, ordinary guide previews do not request content-matched dynamic range or
refresh rate. They leave the display in the Apple TV's configured menu format
(SDR when that is the menu default), without changing system settings. Opening a
channel full-screen enables matching; returning to the guide disables it even
when Keep watching while browsing retains the player. Multiview still has one
display owner, independent of which pane supplies audio.

Plozzigen applies this policy before source loading. Changes on a retained tvOS
player use AetherEngine's session-preserving option reload, keeping its playhead,
pause intent and tracks rather than starting a new broadcast session. Queued
superseded requests, source replacement and stop cannot revive an older policy.
Failed changes surface through playback recovery instead of silently retrying.
This can require one playback/output transition when entering or leaving watching,
but not a new HDMI mode switch for every automatically previewed channel.
Plozz channels play normal library files through that decoder, with a scheduling
controller choosing the file and position; they are not actual live broadcasts.
Shared loading messages say **Loading channel** rather than “live stream.”
Scheduled-channel playback uses **ON NOW**, **DELAYED**, and **Jump to now**;
genuine stream sources retain their **LIVE** and **Go Live** controls.

Library-channel catch-up waits for a usable playback position, not merely an
engine `ready` notification. Plozzigen requires its real first frame and settled
seek/reload state before the schedule can issue corrective seeks. Losing that
readiness during a seek defers reconciliation without spending the retry budget;
unsettled positions do not earn watch coverage. The existing 45-second startup
limit still bounds genuine failures. An end within
the already-allowed three-second clock drift waits for the published schedule
boundary instead of briefly reporting a missing file. Materially early endings
still fail, and a failed join disarms its old startup watchdog.

Playback errors name the movie or episode when known and say it could not play,
rather than labeling every startup failure unavailable. User-facing English uses
“program”; XMLTV's standardized `<programme>` element and existing protocol names
are unchanged. Structured `LIBRARY_CHANNEL` diagnostics record readiness,
positions and failure reasons without channel names, IDs or credentials.

Plozz channel menus, program details and playback controls offer **Go to show**
or **Go to movie**. These open ordinary title details; they do not start playback
or rewrite watch history. The underlying library item carries the original
account and native IDs, so no title-name matching is needed. An episode without a
known parent offers **Go to episode** rather than guessing a show. Playback uses
the actual scheduled item, including a paused/delayed program, not wall-clock
guide selection. The active profile and library authority are checked again when
invoked, then channel playback is stopped before navigation.
tvOS uses Home's regular title stack, temporarily making that destination available
if navigation customization hid it, without changing the saved layout. iOS pushes
the title in the Live TV navigation stack.

### Connected-server Live TV and standalone setup

IPTV playlists and XMLTV guides do not require a media server. With automatic
Plozz channels disabled, the library-channel runtime loads local definitions
without querying unrelated connected servers. Discovery is limited to libraries
referenced by enabled custom channels; opening their editor explicitly discovers
the other available libraries. Enabling automatic Plozz channels opts into
discovery of the profile's accessible supported libraries.
A failure in an unused server is not reported as a broken channel in the IPTV
guide. Failures affecting configured Plozz channels and saved schedules remain
visible, and editor-only discovery errors stay in the editor.

The guide and Sources share one profile-authorized library refresh. Navigating
away from either view does not cancel the other view's channel preparation or
report an access change. A changed account authorization or explicit retry
supersedes the old refresh; profile checks still reject late results.

### Automatic Plozz channels

Enable **Plozz channels** once to prepare a lineup from the accessible movie and
TV libraries on Plex, Jellyfin and Emby. The automatic path does not ask for
channel names, library selections or scheduling rules. **Create custom channel**
remains available separately for users who want a particular recipe.

The lineup is based on actual library metadata, not a fixed catalogue of empty
presets. Broad movie and TV channels cover eligible content, with useful themed
channels where enough matching content exists: genres, decades, animation,
family-friendly ratings, studios/networks and directors. Animation alone is not
evidence that a title is suitable for children. Missing metadata does not produce
invented classifications or cause an otherwise playable title to disappear from
the broad channels.

Automatic selection favors a compact, varied lineup: up to 24 themed channels
alongside the broad channels, skipping duplicate lineups and themes with too
little distinct content. Existing catalogue and snapshot limits still apply;
an oversized broad catalogue reports a preparation error instead of silently
omitting part of the library. Metadata-poor libraries may therefore have fewer
themed channels, but do not require manual recipes.

Automatic recipe revisions reuse an existing snapshot when all immutable inputs
match, rather than duplicating them for a metadata-only recipe change. Published
revisions and their boundaries are never rewritten. This prevents new redundant
payloads; it does not migrate or delete previously published duplicate snapshots.

The opt-in is stored per profile on this device and defaults to Off. Disabling
it stops automatic discovery and removes generated channels from playback and
the guide without deleting their saved identities or any custom channel/IPTV
source. Re-enabling reuses the generated lineup rather than making duplicates.
Imported generated definitions do not opt a new device into library discovery.

Preparation and failures are visible in Plozz-channel management. An empty or
unavailable library does not turn an unrelated IPTV station into a failed
library channel. A failed saved server does not block channels from other
reachable servers. Management names the failed connections and distinguishes
connectivity, rejected access and invalid responses; it does not tell an
already signed-in user to add the same account again. Saved groups belonging
to temporarily unavailable servers are retained, but cannot play without
current library authority. Media-share libraries are not yet supported by
the automatic channel generator.

Automatic scans skip individual items with invalid scheduling metadata as well
as missing or invalid durations, and show the skipped-item count in management.
Only validated native identities and metadata enter saved schedules; rejected
values are never repaired by guessing or logged. Page diagnostics contain only
item type, offset and counts. Source identities are checked before paging.
Malformed responses and unstable pagination discard that server's incomplete
scan, report it as unavailable and allow healthy servers to finish. An entirely
malformed scan retains the server's saved groups instead of treating it as an
empty library. Access changes, cancellation, catalogue limits and publication
failures still stop publication. Custom-channel previews remain strict.

Preparation reports the current server/library, actual page counts and total
library items checked, followed by building-channel and saving-guide stages.
The progress bar belongs to the current library/item type, not an invented
whole-job percentage. Elapsed time and a waiting-for-server message explain
long requests without claiming a predicted completion time. Progress is held
in a separate observable object so elapsed ticks and page updates do not redraw
the guide. Turning the feature off cancels preparation even during initial
server discovery; late callbacks cannot replace the next run's progress.

Catalogue changes trigger coalesced refreshes; foreground
periodic refreshes provide a fallback. Refreshes wait while playback holds live
identities. Published programme slots remain frozen, with changed catalogues
applied in future schedule revisions rather than rerolling the current show.

### Connected-server tuning

Jellyfin, Emby and Plex adapters discover authorized channels, load native guide
data, and open explicitly owned live-stream sessions. Plex tunes the selected
DVR/channel, negotiates a consumer through the playback decision API, and uses
the returned HLS consumer path or an individually identified universal
transcode. A current guide programme is not fabricated or required by Plozz.
No adapter invokes administrative or device-wide session termination.

The provider-neutral `LiveTVServerEnrollmentCoordinator` accepts the existing
authorized account choices and resolver. Composition calls `refresh` at login,
profile activation and refresh, then reloads source catalogs. Configuration and
removed-account suppression are read again before each source is saved, so a
concurrent remove, manual add, rename or disable wins. Call `invalidate` before
changing profile/account authorization. Source IDs are stable account-derived
identities; secret tokens and server-user credentials remain in the existing
account resolver, not source configuration.

Checking a server is metadata-only and never acquires a tuner. The chooser
distinguishes missing tuner setup, no channels, permissions, an unreachable
service, explicit subscription requirements, unsupported APIs and guide-only
playback limitations. It uses only
accounts available to the current profile, including effective Plex Home
credentials, and rejects stale results after profile or authorization changes.
Source configuration uses the existing household parental-PIN policy.

Plex gives each pane/tune a fresh playback UUID, carried on tune, consumer
decision/start, timeline reports and scoped transcode stop. A detached allocation
request is observed to completion even after cancellation, then rolled back
using the same identity. Provider retirement fences late opens. Heartbeats run
every ten seconds; close serializes behind outstanding reports, sends the
owned viewer's stopped timeline, and stops only its own transcoder identity.
Stopping one viewer never deletes the shared live-session UUID.

#### Server API evidence and verification boundary

The [official Plex Media Server OpenAPI](https://developer.plex.tv/pms/)
(embedded schema 1.2.2, inspected September 8, 2026) documents channel tune,
live-session/consumer HLS, universal decision/start, and `POST /:/timeline`.
The timeline contract explicitly specifies a separate
`X-Plex-Session-Identifier` for simultaneous playback on one client and a
ten-second LAN/WAN cadence. It does **not** document a consumer DELETE endpoint:
none is invented here. Session-specific universal stop and the live stopped
timeline are additionally corroborated by independent existing clients,
including [Rivulet's playback client](https://github.com/l984-451/Rivulet/blob/6985966892ba00dcbeb1822a6360142fc5764b19/RivuletCore/Plex/PlexNetworkManager.swift)
and [live timeline implementation](https://github.com/l984-451/Rivulet/blob/6985966892ba00dcbeb1822a6360142fc5764b19/Rivulet/Services/LiveTV/PlexLiveTimelineKeepalive.swift).
These are API-behavior references, not a claim of local real-server testing.

[Plex's permission documentation](https://support.plex.tv/articles/115007689648-watching-live-tv/)
limits Live TV sharing to permitted Plex Home users. OTA viewing must not be
rejected merely because the owner lacks Plex Pass.
[Emby's Live TV setup](https://emby.media/support/articles/Live-TV.html) requires
Premiere; [its user-authenticated Info API](https://dev.emby.media/reference/RestAPI/LiveTvService/getLivetvInfo.html)
exposes enabled users, while its [Open](https://dev.emby.media/reference/RestAPI/MediaInfoService/postLivestreamsOpen.html)
and [Close](https://dev.emby.media/reference/RestAPI/MediaInfoService/postLivestreamsClose.html)
contracts identify individual stream handles. Missing entitlement metadata is
not evidence that Premiere is missing. An explicit HTTP 402 is distinguished
from permission denial; fixtures for this status do not assert which server
versions emit it.

Jellyfin's [API reference](https://api.jellyfin.org/) and
[official LiveTv controller](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/LiveTvController.cs)
identify the authenticated `LiveTvAccess` policy on channel/Info requests.
Discovery does not require its administrative tuner-configuration endpoints.

Focused deterministic selectors: `PlexLiveTVTests`, `JellyfinLiveTVTests`
(including independent Emby response shapes), `LiveTVServerEnrollmentTests`,
`LiveTVServerImportTests`, `LiveTVServerProbeTests`, and
`LiveTVServerGuideImportTests`. Fixtures cover no-guide tuning, permission and
subscription states, cancellation/retirement, same-tuner independent viewers,
failed handoff cleanup and concurrent source opt-outs. These are not integration
tests against a configured server. No supported-server-version matrix or
physical tuner contention, long-running renewal, remote streaming or
Home-user two-viewer release result is claimed without authorized real-server
verification.

Native guides bypass XMLTV name matching. The browser requests the displayed
two-/six-hour window for a bounded neighborhood of at most 12 rows; recently
watched and favorite duplicates do not produce duplicate requests. Loaded or
in-flight coverage is reused. Larger requested windows are split at the provider
limits rather than downloading every Plex channel for every day on entry.

Standalone admission is an explicit, device-local choice, separate from
accounts, profiles and source count. Deleting the last source or signing out of
the final server does not strand an opted-in installation at server login.
Existing profile confirmation and PIN/Plex Home gates remain intact. An explicit
first entry can temporarily expose a hidden Live TV destination; later launches
respect navigation customization, including Settings-only layouts. This behavior
is shared by Debug and Release builds on both platforms.

### Channel scanning

After importing a source, an optional scan can check channel availability
without blocking browsing or playback. Sources exposes Scan channels,
Scan results, Show hidden and Rescan channels. Browsing also exposes Check
channels. Importing a playlist does not start probes automatically.

Scan catalog preparation parses origins and hashes stream/health identities on a
cancellable worker, not the main actor. Identical authorized playlist/channel
inputs reuse the existing binding when guides publish again. Source edits and
refreshes revoke old scan eligibility immediately; a completed preparation must
still match the active owner, catalog request and freshly checked authorization.
Scan controls show progress while preparing; browsing and playback remain usable.

Results belong to the profile, source, channel and stream identity. Confirmed
missing links can be hidden reversibly without deleting playlist entries,
Favorites or guide mappings. Restore is separate from manually hiding a channel.
Timeouts, offline checks, authentication/geo restrictions and unsupported
playback remain uncertain; one failed request does not remove a channel.
An HTTP 200 master playlist alone is not evidence of playable media, and
reachability checks are not decoder compatibility tests.

Concurrency, response sizes, deadlines and retries are bounded, with progress
and cancellation. Source refreshes, authorization changes and profile changes
fence old results. Each profile has one active scan owner. Scans inspect imported
IPTV links, not network discovery or tuner-consuming Plex/Jellyfin/Emby streams,
and do not commandeer the playing engine.

### Audible previews and seamless viewing

On iPhone and iPad, tapping a station, programme, or empty guide cell starts that
channel in the upper preview without opening fullscreen. The preview sits below
the top safe area. This is explicit playback, independent of the TV auto-preview
preference; channel preparation, authorization and stale-request cancellation
still use the shared Watch coordinator. Watch and the channel's Play action open
fullscreen without replacing an already prepared channel. Long-pressing a station
retains its channel actions, and programme selection still updates the info bar.

On Apple TV, resting on a different channel for **600 ms** requests its preview.
Rapid scrolling cancels pending requests; moving between programs on the same
channel does not restart the delay or retune. The delay is **not** a stream
startup guarantee: network, source, keyframe and decoder startup follow it.
Ordinary guide preview and fullscreen viewing share one active player, with
sound on while browsing. No second decoder is opened to fake an instant
crossfade. A server change can prepare a replacement
session while the current feed remains visible, then retire the old owned session.
Tuner contention offers an explicit stop-current-and-retry action rather than
silently interrupting playback. Cleanup attempts completing cannot guarantee
that an unreachable server has released its tuner.
Search, controls, sheets and inactive
scenes cancel pending focus-driven tunes.

Live video fills the upper backdrop rather than a boxed preview. A leading scrim
protects programme details and a continuous bottom fade blends through the
translucent upper guide into the solid page background.
The picture remains anchored while either guide axis scrolls. The backdrop
extends through the safe-area margins; only text and controls receive the
navigation rail's leading inset. Selecting a ready preview slides/fades the guide
away and expands the existing surface to unobscured, aspect-fit playback.
Back restores the guide's row, program, filters and time position; it does not
stop, reload or replace the engine. Reduced Motion removes the spatial animation.
On Apple TV, Search and surrounding navigation remain unavailable during the
focus handoff. The playing channel's currently airing programme receives focus
in the same Recent, Favorite or main-list occurrence used to start watching;
programme rollover selects the new programme, and missing listings fall back to
the channel. If a shortcut no longer exists, the same channel's main-list entry
is used instead. A changed channel or offscreen programme is brought into view.
Focus restoration waits for the row to mount and for native focus confirmation,
not merely an assigned focus binding. A bounded station fallback releases the
entry gates if it fails, so the guide cannot remain unreachable from Search.
Moving from the sidebar toward the guide reveals its remembered occurrence even
when that row was scrolled offscreen.
Returning from fullscreen keeps the chosen channel playing while its guide
focus is restored. **Auto preview** remains enabled by default after watching:
subsequent focus movement uses the same 600 ms settling delay. The separate
per-profile **Keep watching while browsing** setting opts into retaining the
deliberately watched channel instead. Turning Auto preview off still prevents
focus-driven tuning. No preview can commit during focus restoration, and stale
restoration callbacks cannot rearm it. The remote's Play/Pause also works during
browsing.
The normal tvOS player header has no Close button; Back returns to the guide.
Transport focus selects an available playback action instead of a removed
header target. Startup and interruption escape/retry controls remain available,
and iPhone/iPad retain their touch Close button.
The player also offers Add to Favorites / Remove from Favorites for the channel
being watched, using the same profile preferences as the guide. The star reflects
saved state; failed saves keep the previous state and surface the existing retry
alert. Favorite changes do not retune or restart playback.

Tuning another channel reuses the engine with a new, fenced source attempt.
Loading/failure states remain local and nonfocusable in the preview, with an
opaque placeholder until the new source actually produces a first frame.
Opening a failed preview exposes the existing full retry/close UI.
Leaving the Live TV destination releases playback and invalidates pending tunes,
including when a native tab keeps its view alive. Ordinary playback tears down
on background entry; explicit mobile PiP/AirPlay follows the authorization-gated
continuation policy below.

## IPTV compatibility checks

`ProviderIPTVTests` includes controlled Basic, bearer, cookie, custom-header,
signed-query and Xtream authentication cases. They exercise sign-in, catalogue
import, provider restoration and actual requests through the playback proxy;
rejected/expired accounts and HTML login pages cannot create successful sessions.
All credentials are synthetic. This does not certify a particular paid provider,
DRM service or browser-based login flow.

For an opt-in public corpus, run `python3 tools/iptv-playlist-corpus.py` before
running `ProviderIPTVTests` through the package test runner. It captures nine
public channel lists, with byte counts, hashes and independent HTTP-entry counts,
under `.build/iptv-playlist-corpus`. The test replays those exact snapshots through
account sign-in, channel enrollment and the guide loader, checking that channels
are retained without inventing movie/TV libraries. It makes no external requests.
The downloader fails explicitly for unavailable sources; ordinary runs skip only
the corpus test when no snapshot manifest exists. Captured catalogues stay out of
Git. These are import/routing checks, not a claim that every listed stream is
online, playable in every country, or fast on every physical device.

## Developer test inputs and artwork

These public addresses are developer test inputs only. They are not offered
in onboarding or Sources, and the importer has no default playlist or guides.
To use one for manual testing, add its address explicitly through the ordinary
playlist editor. Previously saved sources remain editable and are not removed:

- Playlist: `https://iptv-org.github.io/iptv/countries/us.m3u`
- Pluto TV US: `https://i.mjh.nz/PlutoTV/us.xml.gz`
- Samsung TV Plus US: `https://i.mjh.nz/SamsungTVPlus/us.xml.gz`
- Plex US: `https://i.mjh.nz/Plex/us.xml.gz`
- EPGShare US2: `https://epgshare01.online/epgshare01/epg_ripper_US2.xml.gz`
- EPGShare Plex: `https://epgshare01.online/epgshare01/epg_ripper_PLEX1.xml.gz`

The September 6, 2026 source snapshots import 1,468 stream entries across 28
primary categories, with 1,443 logo URLs. The multi-feed import provides listings
for 253 streams, compared with 70 in the original US2-only build. Evaluated at
2026-09-07 03:04 UTC, all 253 had current listings, with 11,257 programs retained.
The selected sources supply 185 Pluto, two Samsung, three Plex and 63 US2
schedules; EPGShare Plex supplies overlapping fallback data, not extra channels.
These counts describe those snapshots, not guaranteed availability or coverage.
The remaining 1,215 streams stay available without invented program information.

Playlist entries are not necessarily distinct stations: feeds can include
alternate resolutions and stream providers. Stable stream identities preserve
variants without duplicate row IDs. Channel logos come from `tvg-logo` metadata
in the [iptv-org catalog](https://github.com/iptv-org/iptv).
Channel and hero marks reuse `HeroLogoArtwork`: cached off-main preparation,
transparent/solid-margin trimming, ink-aware sizing, monochrome contrast and
contrast analysis. A bounded fit contains the whole mark inside the station plate;
measured ink chooses a legible solid backing. The existing preparation pass
retains the background colour it already detects before removing a solid plate.
That sample follows the prepared-logo cache and synchronous memo to the host.
The solid plate adds no image download, resampling pass, blur or continuous animation.
Multicolour artwork is not recoloured. Failed/missing artwork keeps a readable
fixed-size text fallback. Loading artwork never changes the reserved row height.

The original nine-channel `LiveTVPrototypeCatalog` remains a small regression
fixture, not the app's default catalog or a channel limit.

Availability and regional restrictions may change. These are developer test inputs, not a
Plozz-provided channel service, broadcaster endorsement, or permission to
rebroadcast, record or redistribute content. No third-party image binaries
are committed.

Import does not certify that every stream plays. A reachable master alone is
not sufficient: inspect its media playlist and segments, then exercise actual
device playback. Playlist request headers pass through the live host to Aether,
including retries and automatic source resets.

For example, ABC News Live 1's published master returned HTTP 200 on September 7,
2026, while all ten advertised media playlists returned HTTP 404. A guide match
or a valid master cannot make those missing media playlists playable. The
prototype keeps the supplied channel identity rather than silently substituting
a different ABC feed.

Guide loading and parsing run outside the main actor. Listings are associated
with imported channel identities, not synthetic layout scenarios. Unknown or
ambiguous matches receive no schedule. Guide failure does not remove a working
playlist; failed refreshes preserve the last successfully imported data that
still belongs to current channels.
Playlist-declared guide URLs are optional metadata: exceeding the automatic
guide-source budget does not reject playable channels. Header/attribute size
guards still bound parsing. Each playlist retains at most 32 configured and
discovered guide sources, with explicit guide URLs taking priority and an
informational notice when additional declarations cannot be added. Discovered
guides may use a different HTTP(S) origin and retain their stable IDs through
cache restores and portable mapping sync. Excess declarations do not authorize
extra requests; unsupported URLs and embedded user-info credentials remain rejected.

Matching first uses exact native Pluto IDs from recognized stream URLs, then
explicit guide IDs, verified aliases and unique display names. Provider guides
only use name matching for streams identified as that provider; similarly named
streams from unknown or different providers are not silently assigned a FAST
schedule. Explicit foreign Samsung stream origins are excluded from the US
guide even when the playlist's station ID ends in `.us`. Country, affiliate
and time-shift conflicts continue to prevent name-based matches. An unmatched
native Pluto ID is not replaced with a guessed same-name station.

Each stream receives one whole schedule, never interleaved programs from
different feeds. Stronger identity evidence wins. Equal-confidence matches
prefer a schedule with upcoming listings, then the source order shown above.
An unavailable refresh retains that source's last good data for current channels.
Source changes fence late network/parse results before reloading.

Compressed input, expanded XML, retained text and program counts are bounded.
The combined in-memory guide cache is also capped at 250,000 programs and
32 MiB of program title/subtitle text. Sequential feed loading limits transient
memory. Two streaming XML passes discover channel metadata before retaining
matched programs, supporting feeds that interleave channel declarations and
listings without keeping all unmatched programs in memory. Plain XML and gzip
are accepted. Normal external XMLTV DOCTYPE headers are accepted without
retrieving the DTD; entity declarations remain rejected.
Custom-source setup is available in both build configurations. The importer uses an
encrypted, indexed catalog and guide cache. Guide windows and program searches
fetch only the requested channel IDs and time range; a large import does not
publish its entire schedule into observable UI state. Cached data is bound to
the current source URL and profile authority. Changing credentials cannot
restore streams or guide data from the previous source binding. A failed
refresh retains the last good generation for an unchanged, still-authorized
source. Backend playback handles remain runtime-only.

## Boundaries

The integration includes manual guide mapping, durable channel identity,
generated library channels, indexed program search, channel checks and four-channel
Multiview. Multiview retains each player's decoder and prepared stream through
side-by-side/corner layout changes, audio selection and returning to one player.
Setup keeps the pictures inside a bounded canvas with room for controls.
Focus outlines hug the actual video aspect, reported by the retained player,
rather than its letterbox area or caption. Add and Replace return to the actual
guide in selection mode: the same channel/programme rows, vertical catalog,
Favorites, Recents, category sidebar and native Search, backed by the same
profile model and loaded guide. There is no separate channel browser or
horizontal all-channel shelf. The current audible picture remains in the guide
preview, and browsing never retunes a Multiview player. Selecting a station or
programme adds/replaces its live channel, then returns to setup. Already-added
channels are marked; selecting one returns to it without allocating another
player. Cancel preserves every stream and the existing composition.

Watch switches to the full physical-screen canvas, including safe-area edges,
with no video focus outlines. Two channels split horizontally in landscape and
vertically in portrait; three or four use a two-row grid. Main and stack places
one large picture on the left and up to three separate pictures stacked on the
right, without overlap. Corner mode retains its overlaid inset column.
Each renderer fits its source without cropping. Edit layout returns to setup;
ordinary viewing never reserves permanent space for controls.

On Apple TV, native pane focus selects that channel's audio once its source is
prepared. Moving into the controls keeps the last selected audio. Select opens
the focused picture full-screen; Back restores all retained players without
retuning. On touch devices, tapping a picture selects its audio and expands it;
Show all restores the layout. Tapping again reveals hidden controls.
iPhone/iPad controls use the original container safe area even though the video
canvas extends beneath system chrome. A compact Close control and separate Watch
action stay at the top; a touch-sized bottom dock exposes Add, Layout, and Audio,
with Favorite and channel management in More. At large text sizes or narrow
windows the dock scrolls rather than truncating labels. Setup's pictures reserve
the measured header and dock heights so landscape and large-text controls cannot
cover them. TV focus controls and the retained players' full-screen geometry are
unchanged.
Apple TV multiview's header and toolbar keep visible title-and-icon labels with
the same native button treatment as normal playback, including the Layout menu.
Their height stays transport-sized while width follows the action's title.
Focused labels stay dark against the bright fill in native-glass and
reduced-transparency modes. These controls do not use the larger page/form action pills.
Watching hides controls after four seconds of inactivity. Editing, native menus,
channel selection, preparation failures and VoiceOver keep them available.
Native menu focus notifications do not write back into the pinned controls'
activity state, avoiding an update loop that can repeatedly rebuild the menu.
Back from a guide row still focuses Search; Back from those controls or Cancel
returns to setup. In Multiview, Back restores all pictures if expanded, then
leaves setup or dismisses active controls. Any Back or Close Multiview action
that would end the composition asks for confirmation. Keep watching dismisses
the confirmation without closing streams.

Favorite saves channel IDs in display order, the main picture and the chosen
layout. The guide's Multiviews control opens these saved compositions. Favorites
are profile-scoped and device-local, survive relaunches, and store no stream
URLs, credentials or tuner leases. Restoring resolves channels against the
current catalog and authorization; missing or unauthorized channels produce an
error without replacing current playback. Channel identity migrations update
the saved composition, and ordinary channel preferences or portable preference
imports preserve it. Required lifecycle or authorization cleanup never waits
for exit confirmation.

On tvOS, Favorite Multiviews uses a compact native sheet rather than a full
Settings page. Its title and Done control stay above the scrolling saved list;
the empty state fits its content, and long lists cannot expand the sheet beyond
600 points. Typography follows the smaller sheet scale with Dynamic Type, and
focused rows retain the shared contained highlight without growing. iPhone and
iPad retain their native navigation-sheet presentation.

Its hardware decoder capacity, mixed HDR/SDR behavior and long-running resource
use still need real-device acceptance; controlled fixtures are not proof of
those guarantees.

Generated channels use immutable schedules and seek into the current program
when joined, rather than resuming an ordinary movie or episode session. Library
history defaults to Off. With consent, sufficient actual watched coverage can
produce a canonical watched completion through the existing profile outbox.
Generated completion never writes resume position or sends a legacy
playback-stop event. Pending completions retain runtime consent and account
authorization checks; restoring an outbox cannot recreate an expired grant.

IPTV provider catalogues retain their indexed metadata, including on-demand
movies/shows where supplied, rather than downloaded video. SQLite retains at
most a 4 MiB reusable WAL after a completed reset/checkpoint. The client also
attempts a non-waiting checkpoint of oversized legacy journals on first use and
after imports. Active readers defer truncation; their snapshots and committed
catalogue are never removed to meet a space target. No database sidecars are
deleted manually, and these limits do not cap the underlying catalogue itself.

Live TV follows the main iCloud Sync switch for each profile. The existing
portable channel covers channel preferences, matching hints and generated
definitions/snapshots. A separate encrypted source channel carries playlist
and guide addresses, stable guide identities, source options and imported files.
Both use the same existing CloudKit engine. Source records reuse deployed
encrypted fields in an isolated zone; old clients cannot erase them.
Parental approvals, history grants and channel health remain device-local.
Server sign-in credentials retain their existing authorization flow.

Server-source enablement and enrollment suppression travel through the
non-secret portable channel. Incoming state cannot overwrite a local re-add,
removal, or enablement change that has not been captured. A captured server
change remains protected across restarts until the ledger acknowledges its
exact digest; delayed cloud state and fallback hydration cannot bypass that
receipt. Both app shells pass the incoming delta and capture receipts together.
Confirmed hard deletions retain the removed ledger entry's receipt for that
apply, so unchanged sources still follow legitimate deletions on other devices.
This does not delete or replace the authenticated server account.
The local observation also records suppression caused by accepted remote source
changes. Split source/enrollment delivery can then re-enable a source without
mistaking the earlier remote disable for a new local decision. Only the applied
accounts advance that observation; unrelated local changes stay protected.
Suppression also keeps its remote origin in the same atomic local document as
the decision itself, so a failed journal/observation commit cannot lose that
provenance. Explicit local decisions clear it; saving an already-suppressed
unrelated source remotely cannot relabel a local restriction.
Source tombstones retain their account association locally. Enrollment updates
must also respect that account's uncaptured or unacknowledged source removal,
including removal of a source that was already disabled.
Exact remote server records and resulting local-state digests (including
deletions) are saved atomically with the source configuration, scoped to the
profile and iCloud account epoch. A
failed source-record journal write can then be retried or captured without
mistaking the already-applied remote state for new local intent. Local server
edits invalidate the affected receipts, including edit-away-and-back sequences.
Accepted descriptors awaiting native enrollment replace older deletion receipts
even without a configuration change. Enrollment also protects new, uncaptured
source IDs for the same account. The encrypted playlist channel retains its
separate checkpoint.
`IPTVCloudOverwriteHostedTests` exercises these races on iPhone/iPad through
the separate presentation test host, isolated Keychain/defaults storage, and
controlled incoming payloads. It does not mutate the normal app's sources or
claim to reproduce CloudKit network delivery timing.

These generated-channel snapshots are different from IPTV catalogue/guide
downloads: they carry immutable library-item inputs so devices agree on the
generated schedule, not video files. Authenticated IPTV accounts use the normal
account-descriptor and credential-transfer paths; their disk-backed catalogues
and downloaded guides remain local. The imported files mentioned below belong
to the older playlist-source transfer path, not the newer IPTV account catalogue.
The sync breakdown separates **Plozz Channels schedules** (definitions and
immutable inputs) from **Live TV preferences**, and reports pending-upload bytes
separately from all locally retained payloads. These are encoded record bytes,
not measured CloudKit storage or wire traffic. Unchanged acknowledged records
are not re-uploaded on every capture.
For genuinely empty onboarding and separate cloud-restoration tests, use the
[cloud-enabled first-user cases](per-branch-builds.md#cloud-enabled-first-user-cases)
rather than resetting the normal app or disabling sync.

Imported files use immutable, bounded chunks and a manifest containing their
byte count and checksum. A source is installed only after the complete file
verifies, regardless of delivery order. Imported identities cannot replace
different existing file content. Source deletions use explicit tombstones.
Canonical source observations and remote-ownership receipts are committed with
the source configuration in Keychain, preserving unreported local edits.
Captured edits remain pending until a durable ledger receipt acknowledges that
exact intent. A failed write or restart cannot let an older cloud fallback
overwrite them; a recorded server-wins conflict can still converge normally.
Account/profile/root-namespace and snapshot-order fences reject stale work;
an account change quarantines sources received from the previous account.
Parental grants are invalidated through the existing approval-aware store.

Encrypted CloudKit channels also seal their local ledgers with a device-only
Keychain key. A small atomic index references separately encrypted entry files,
so acknowledgements do not rewrite all imported playlist bytes. Legacy plaintext
credential ledgers migrate only after validation; unreadable keys or ciphertext
never restore an empty ledger. These reconstructable files are excluded from
backup, and missing encrypted ledgers force a complete cloud fetch. Source
ledger indexes also bind the account epoch, so an old file left by a failed
account-switch write cannot be replayed as the new account's sources. Channel
state commits before engine cursors advance; failed persistence stops delivery
and retries from the last durable state. Source transfer retains a 256 MiB
aggregate record budget rather than silently dropping
files when an account exceeds the device's supported working set.

The non-secret Live TV state channel also uses an incremental local record
ledger, not a whole-library JSON rewrite on every acknowledgement. Matching
local/server payloads are stored once while edit clocks, server fields, pending
changes and deletions retain their exact semantics. Legacy whole-ledger JSON
(including files above 256 MiB) is validated and migrated before replacement.
Unchanged entry files are reused; failed saves retain the committed index.
Startup validates that index before reclaiming unreferenced entry files and
abandoned atomic writes for this channel. Credential channels remain encrypted;
CloudKit record formats and schedules are unchanged.

Incomplete transfers remain pending. Identity changes are deferred while
playback holds their identities, while authorization revocation takes effect
immediately. New clients leave legacy plaintext playlist descriptors unchanged,
but only the encrypted channel owns playlist configuration.

The mobile Settings root supplies its active profile model to both compact and
split navigation, including the shared Live TV sync controls and pending-source
list. Availability still comes from the bridge registered for that exact model;
the UI does not substitute a different profile or infer CloudKit availability.

Sync troubleshooting shows a dedicated Reload From iCloud progress indicator
and retains its completed, unavailable, interrupted or failed outcome on both
platforms. Intermediate automatic fetch/send updates cannot dismiss that
indicator or overwrite its result. Reload and Reset are disabled during a
reload, and repeated reload requests cannot rebuild the sync engine concurrently.
Full reloads retain the existing per-channel ledger and verified-deletion rules.

Portable library schedule validation, snapshot assembly/encoding and merge
planning run on a serial worker actor using immutable inputs. Prepared exports
are reused during capture instead of rebuilding schedules on the main actor.
Definition-only changes, such as advancing the published guide horizon, are
revalidated but reuse the same encoded snapshot records. Changed snapshot
contents or a different profile require a fresh export; matching UUIDs alone
are insufficient.
Consent, source changes, acknowledgements and definition publication remain
main-actor-owned. Every worker result is checked against the current profile,
account epoch and consent revision; definition publication also rechecks the
original definitions before compare-and-swap. Disabling sync or opting in again
cannot authorize an older preparation. Pending-source settings read descriptors
without reconstructing library schedules, and revocations do not wait for that
reconstruction.

Portable journal reads and full record validation are prepared off the main
actor, then reused for one bridge operation. Preparation does not hold the
journal lock during decoding. Writes and resets invalidate other adapters'
prepared views; UI-facing readers require preparation rather than falling back
to synchronous decoding. Pending-source lists reload asynchronously, while
saving a source checks only its own descriptor record. Prepared journal data is
discarded when the operation ends.

Settled captures retain a bounded per-profile receipt, not decoded journals or
schedule snapshots. Before reopening large payloads, the bridge checks current
consent, namespace/account epoch, portable preferences, source configuration,
definitions, playback holds, SQLite change counters, Keychain publication
manifests and imported-file/journal metadata. SQLite counters cover writes from
both the current connection and other connections; file identity checks reject
evicted or replaced databases. The cloud fallback must also exactly match the
previous capture's input, not its output: unacknowledged local uploads may differ
from the server baseline. Reuse returns the previous local output. With unchanged
inputs, polling skips journal decoding,
snapshot reads, schedule partitioning and identity/guide exports.

Successful, settled captures qualify after their inputs remain stable through a
complete operation. An otherwise settled capture rejected solely by the library
export's size guard also qualifies, retaining its unavailable status and previous
library records rather than publishing a prefix or claiming recovery. Unchanged
oversized inputs must not be reread and reserialized on every poll. A real edit
invalidates that receipt and retries immediately. Storage quotas remain enforced.
Pending transfers, other unresolved changes and transient failures continue
through normal reconciliation. Remote apply and account/profile/consent changes
invalidate receipts. Stores without authoritative revision support retain the
full path. Receipts keep compact SHA-256 fingerprints of the cloud input and only
the local output that differs from it, rather than retaining another entire
schedule collection. Fingerprint checks run off the main actor. Retained output
is capped at 64 MiB, with 50,000 fingerprint/output entries across profiles; an
unchanged collection larger than 64 MiB still qualifies. Wire formats, schedule
agreement and polling cadence are unchanged.

The journal enforces its **128 MiB serialized-storage bound** before writing.
Each export and incoming preparation has a separate 128 MiB staging quota and
50,000-record bound, not a 64 MiB whole-library memory limit. Encoded records
above a **4 MiB working buffer** spill to invocation-owned, memory-mapped files.
Their file names are unlinked before payload bytes are written. Each returned
`Data` owns its mapping, so releasing the export owner cannot invalidate a
retained value, and process termination reclaims the backing without requiring
`deinit`. Startup removes only recognized old numbered-record staging folders
from this app's temporary directory, off-main, even when sync is disabled.
These are per-operation working limits, not a claim that all simultaneously
retained exports together occupy only 128 MiB.
Journal reopening validates one wrapper at a time with the same bounded backing;
prepared snapshot entries retain only validated identity and encoded bytes, not
a second decoded copy of every item. Opt-in replay and failed-apply hydration use
that validated identity too; immutable snapshot parts have no local preference
fields to compare, so replay must not decode their bodies on the main actor.
The export still owns the immutable schedule
inputs, and the existing cloud ledger/transport still owns its record dictionary;
this is a bound on additional preparation buffers, not a 4 MiB whole-app RAM claim.

Snapshot digests stream the exact existing sorted-JSON bytes one item at a time.
Snapshot-part IDs, v1 wire records and digest values are unchanged. Deferred import
decodes parts on the worker only when assembling a required snapshot, checks all
parts and the complete digest, and keeps each incomplete definition pending.
The prior schedule remains authoritative until its replacement passes ordinary
snapshot staging and definition compare-and-swap publication.

Journal commits stage record descriptors rather than another fully serialized
collection. The worker encodes and writes one bounded wrapper at a time; exact
serialized sizes are checked before any new records are written. Storage quota,
record-size and record-count failures remain explicit and never authorize a
partial schedule. Retired temporary backing is reclaimed with its mappings; failed/cancelled
operations retain no reusable authority. A fresh device can receive more than
64 MiB of valid parts in one preparation or progressively across deliveries.

Replacing or deleting a known library definition retires snapshot parts only
when no remaining definition revision references that generation. Current,
future, retained and pending revisions all count. Retirement uses explicit
tombstones; old unreferenced parts are not discarded merely by age or absence of
a definition, because a delayed transfer may deliver its definition later.

Unchanged schedule exports are reused by the worker after comparing the complete
definitions and snapshots, not snapshot IDs alone. Authorization reads still
check current credentials and durable definitions each time; only their
unchanged hashes and validated JSON are reused. External edits, storage errors,
profile changes and credential rotation retain their existing revocation checks.

Transient server-discovery failures that leave no lineup retry one minute after
the attempt finishes while the library host is active, instead of waiting for
the normal 15-minute refresh. A working partial lineup keeps the normal cadence. Playback identity
holds still defer refreshes. The empty guide exposes the same per-server errors
as source settings; tvOS source management opens as a full page rather than a
compact quick-action sheet.

Preparation shows the current stage, library/server, count and elapsed time.
Connection failures remain source-specific and wrap instead of truncating.
The compact history copy retains the watched-coverage threshold, no-resume rule
and original-file requirement.

Channel checks use bounded probes and keep unsupported, blocked and uncertain
results distinct. Only confidently missing streams can be automatically hidden;
restoring a scan-hidden channel does not change a manual hide. Scanner network
permissions do not grant the media engine a transport capability it lacks.

DVB-I, DASH-specific integration, catch-up,
programme-rating restrictions and recording management are outside this
implementation. Source-configuration PIN protection is not a
programme-content rating filter. Real tuner installations remain a validation
gate beyond controlled provider fixtures. Many streams still lack a confidently identified schedule;
more name guesses are not a substitute for accurate provider/region mapping.

The normal shell owns account/profile models; the Live TV feature does not
create a second account or profile stack. The small
`FeaturePlayback.LiveChannelPlayerView` hosts the existing real engine without
constructing the VOD `PlayerViewModel`, VOD reporting sessions, resume
writers or trackers. Live server sessions have separate UUID-scoped first-frame,
progress and cleanup reporting. This avoids incorrectly treating an endless channel as a
movie while leaving ordinary library playback unchanged. The app shells inject the
player into `FeatureLiveTV`; UI feature modules do not import one another.
The app also injects the `LiveChannelEngine` implementation into the host, so
`FeaturePlayback` does not depend back on `EnginePlozzigen`. Engine initialization
failures are visible; the prototype never silently substitutes direct AVPlayer.

The paired `FeatureLiveTV` / `FeatureLiveTVCore` types are explicitly named
`LiveTVPrototype*`; they are not a final provider API. The core's synthetic
30-channel fixture catalog remains Debug-only for deterministic guide/filter/state
tests, separate from the real catalog used by the app. Without supplied channels,
the Release model is empty; imported listings never receive synthetic gap fillers.

## Live activity and diagnostics

Account-backed IPTV guide batches write `IPTV_GUIDE` events to Recent Activity
on both platforms. A random batch ID links the source mode, requested channel
count, Xtream-to-XMLTV fallback counts (empty, malformed, or unavailable), and
completion outcome. Up to six operation samples retain the first four, first
failure, and last operation, with the omitted count reported explicitly.
Samples identify `get_simple_data_table` or XMLTV, lookup/request/download/parse
stage, observed HTTP status and allowlisted response type, bytes, cache use,
returned listing count, elapsed time, and a classified failure/network code.
Cached XMLTV does not invent an HTTP response; cancellation is not a failure
or success. These diagnostics add no requests or retries and do not change
fallback selection. They contain no hosts, URLs, account/channel/program
identities, credentials, raw headers/bodies, or error descriptions.

Guide-only endpoint failures show **Guide unavailable**, not a claim that the
server's channel API is unsupported. Working channels and previously loaded
listings remain available. After reproducing, use **Settings > Help & Diagnostics
> Recent Activity** to copy the log, or enable **Share Crash Reports** and use
**Send Diagnostics > Send to Developer** with a short identifying note.
Guide events are local recent activity, not new automatic telemetry; a reporter
must run a build containing this instrumentation to supply the missing evidence.

Copied playback reports use `plozz-live-tv-2`; `stream_format` is separate from
the report-format identifier. Both the local report and opt-in failure telemetry
retain the engine route, first-frame state, up to eight nested native error
domain/code pairs, and the last four native error-log domain/code pairs. Native
logs are read off the UI actor with a 500 ms deadline and at most two outstanding
readers process-wide. Missing items, busy readers, and timed-out captures are
explicit, not interpreted as an absence of native errors. A replaced or stopped
playback cannot publish a late capture into its successor.

The authenticated IPTV proxy keeps a bounded, playback-local delivery history:
the latest completed root GET (or the current attempt until one completes),
first failed upstream attempt, and eight recent attempts,
including successful responses. Facts include root/child role, GET/HEAD, relative
timing, HTTP status, observed format, redirects/cross-origin delivery, range
presence/validity, expected/received bytes, and network error codes. HLS facts
include target and maximum segment durations, media sequence, segment count,
master/end-list flags, byte ranges, initialization maps, and encryption presence.
They are observations, not a playlist validator or a new retry policy. A child
404 remains available even if AVFoundation replaces it with a generic failure;
an earlier recovered request does not become the terminal error.

For live root GETs, the relay also recognizes HTML/JSON/XML document signatures
or an empty body from its existing 16-byte prefix. A recognized non-video
response fails without opening a second origin request, preserving the actual
HTTP status and a fixed body classification in the error shown to the user.
It does not infer authorization failure. Unknown prefixes, HEAD, byte ranges,
opaque HLS children and on-demand delivery keep their existing behavior.

These reports never include URLs, hosts, IPs, channel names, response bodies,
raw headers, native descriptions, or native error-log comments. Local copying
does not enable telemetry; the existing consent-generation, report-count, and
deduplication gates still apply. Diagnostics make a subsequent failure more
actionable but cannot reconstruct the missing evidence in an older report.

The centered activity indicator is owned by `LiveChannelPlayerModel` and driven
by AetherEngine's typed `playbackPhase`, gated on
`hasFirstFrameReadyForDisplay` for initial video. Connecting, buffering, seeking
and reconnecting are distinct. The host no longer reconstructs engine state
from AVPlayer transport hints or a second playback-clock classifier.

TV controls keep one stable set of focus targets. Live playback reuses the normal
player's `InfoActionButtonStyle`: white labels at rest and black labels on a
white capsule when focused, with both colours changing together. The same style
covers transport, Favorite, loading, retry and close actions. Its type stays
constant as focus changes, avoiding replacement of the focused control.
Shared CoreUI focus-activity observation and monotonic inactivity tracking
keep native remote input non-consuming and use the same four-second grace
across live-player and Multiview overlays.
An available transport or recovery action receives focus; normal TV playback
has no top-right Close control. The connecting indicator does not intercept input. On-device regression checks
must include video rendering and Back/Close while a channel is still connecting;
the headless package test runner has no window scene to exercise TV focus.

Live loads use `isLive: true`, the stable `.standard` join profile and native
remote HLS with Aether's compatibility fallback. A native HLS route still uses
AVPlayer internally; Aether owns route selection, engine state and recovery.
The host uses actual live seekable ranges and Aether's Go Live API, never a
fabricated movie timeline or a guessed seek target.
Native HLS uses the origin's actual sliding window; no local DVR duration is
invented. If compatibility recovery switches to ingest without a DVR window,
timeshift controls disable rather than promising unavailable rewind.

The host subscribes to `liveSourceReset` before loading. A fixed public channel
reopens the same URL, with one automatic retune in flight, at least 20 seconds
between automatic attempts and at most three before recovery is exhausted.
Five minutes of continuously observed playing state with a presented frame and
an advancing playhead replenishes that allowance. Pause, inactivity, buffering,
seeking, a new load, backward/nonfinite clocks or more than five seconds without
observed progress discard the healthy interval; elapsed wall time alone does
not count. This clock observation only qualifies recovery credit, never changes
the engine's published playback phase or starts a periodic retune.
Duplicate signals coalesce, pause/inactivity defers recovery, and exhaustion is
visible. Two manual retries remain available; they do not replenish automatic
recovery's budget. Startup is bounded at 30 seconds and sustained activity/stall
at 60 seconds, leaving room for Aether's own recovery before failing visibly.

Brief inactivity pauses the current feed and cancels pending tunes without
releasing the current server lease. Background entry or leaving Live TV closes
ordinary playback; an explicitly authorized mobile PiP/AirPlay continuation
retains its exact player and preparation until it ends or loses authority.
Returning to active browsing follows the Auto preview preference; touch browsing
still requires selecting a channel. Stop, failure, authorization changes and
replacement invalidate outstanding loads and seeks. Ordinary VOD playback and
its lifecycle remain unchanged.

Mobile cellular playback is allowed by default. The optional "Stop without
Wi-Fi or Ethernet" control stops playback after detecting a network change.
The engine does not expose per-request cellular restrictions, so this is not
a guarantee of zero cellular bytes during a handoff.

Debug diagnostics use the existing `HandoffDiagnostics` bounded playback journal
and `PlozzLog` recent-log ring, tagged `LIVE_TV` with `engine=AetherEngine`.
Snapshots include typed playback phase, actual video route, first-frame readiness,
playback/buffered positions, behind-live time and seekable bounds. Changes are coalesced to at most one
snapshot per second; steady playback emits a heartbeat every ten seconds.
Lifecycle and classified failure events are also recorded. Correlation uses a
random session ID, not a channel name, locator or credential. Error text and
raw URLs are never included in these new events.

Committed focus previews record monotonic `settleMs` separately from the
player's tune-to-first-frame timing. A canceled focus request emits no tune
event. Startup timings describe actual first-frame readiness, not merely a
manifest response or successful `load` return.

The journal is `Library/Caches/Plozz/playback-trace.log` (64 KiB limit).
Use existing in-app diagnostics export when available. Do not copy the active
tvOS app container, attach a debugger, or relaunch with `--console` during
someone's viewing without authorization: these can interrupt playback.
The existing `PlozzigenVideoEngine` log mirror is reused; the live host installs
no competing `EngineLog.handler`.

Terminal live errors retain Aether's typed `PlaybackErrorInfo` classification.
Explicit source HTTP refusals, connection failures, rate limiting and decoder
failures receive distinct channel-specific copy, rather than generic media-server
or sign-in instructions. Native AVFoundation failures do not imply a particular
HTTP status unless the engine actually supplies it. Bounded failure diagnostics
include an allowlisted error kind/domain and numeric code; messages are not
regex-parsed for classification, and raw locators are not added to those fields.

Run the focused model and native layout tests through the existing simulator runner:

```sh
tools/run-tests.sh FeatureLiveTVTests FeatureLiveTVCoreTests FeaturePlaybackTests EnginePlozzigenTests
```

`LiveChannelFullscreenPresentationTests` additionally needs an app-hosted tvOS
test target with a window scene; the standalone package runner skips it.
It exercises native sidebar/top-bar presentation, actual dismissal, focus
ownership, in-flight startup, channel changes and reuse of the engine's output
view. It does not substitute for a physical Siri Remote usability pass.

The [native Live TV regression fixture](../Tests/FeatureLiveTVRemoteTests/README.md)
provides that scene-backed host, actual remote Search traversal and isolated
source-onboarding navigation. Its independent project and inputs are committed;
it does not require a configured server or download a channel feed.
