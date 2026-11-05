# PublicMetaDBService

## Development checkpoint: 5 November 2026

The PublicMetaDB and shared tracker-sync branch is paused, not release-ready.
Implementation spans personal-key connection, playback reporting, reviewed and
ongoing history imports, explicit exports, lists/catalog, community contributions,
and shared support for existing trackers. Implemented surfaces are not equivalent
to completed real-data acceptance.

The acceptance ledger at this checkpoint contains 74 completed, 13 in-progress
and 14 pending tasks. These are differently sized scenarios and parent tasks,
not a feature-completion percentage. Historical evidence covers selected real
Jellyfin, Plex, Emby, Silo, SMB and NFS routes on owned simulators; it does not
establish every provider/platform combination or physical-device behavior.

The latest completed checks cover fresh iPhone/iPad profile setup and two
separate consent boundaries: an inactive consenting profile cannot authorize
either an active disconnected profile or an active connected-but-unconsented
profile. Both cases used actual remote playback changes, the real automatic-sync
interval, native foreground transitions and independent profile-scoped store
reads. Returning to the original profile required review of conflicting local
progress rather than overwriting it. Experimental permissions were revoked.
The profile setup fix is in `ffef584bfc61b83f11ade5259e0fec18a4c36ea6`;
`ecc3eb7ce4e32f053616e5c323dd65ea82041992` fixes hosted PIN-fixture readiness,
not production authorization.

Outstanding acceptance is grouped below; partial coverage remains useful:

| Area | Remaining work |
| --- | --- |
| Safety and recovery | Actual per-item playback guard, ambiguous/incomplete identity, key/server-user switching, in-flight cancellation, uncertain delivery and coexistence |
| History routes | Remaining provider/platform, episode/share and lifecycle coverage for imports, exports and ongoing synchronization |
| Community | Remaining ratings/season ownership, partial-result and lifecycle cases; markers/highlights, votes, external IDs and anime mappings |
| Watchlists | Universal-watchlist consent, synchronization and recovery |
| Existing trackers | Real end-to-end Trakt, Simkl, WeTrakr, AniList, MyAnimeList and Last.fm campaigns |
| Final audit | Current-source evidence reconciliation and outstanding scoped test-session credential hygiene |

Resume with one maintainer-agreed milestone rather than automatically expanding
or restarting the whole campaign. The maintainer's private recovery package
`publicmetadb-20261105` contains the portable task/dependency ledger, frozen
audits, raw test evidence, helper scripts and a saved uncommitted connection-test
delta. It is intentionally outside Git and the deleted-worktree boundary.
Recover that delta only if absent, and consult the package's `RESUME.md` before
using historical runners. No credentials or private server identities belong in
this document.

Preserve the distinction between historical evidence and fresh validation.
Inspect current source and external state, rebuild only the required current
app/driver, and rerun affected cases. Old absolute paths and `.xctestrun` manifests
are not runnable after removing build outputs. Retain immutable result records
separately from reusable build directories; do not recreate every historical
DerivedData directory. See [tracker acceptance](../../docs/testing-policy.md#opt-in-tracker-acceptance)
for the native-action and independent-readback requirements.

Dropping a whole TV show is an explicit, confirmed tracker-only action. A fresh
read prevents redundant writes; a complete readback must confirm the drop, even
after a lost acknowledgement. Movies and individual seasons/episodes are not
supported by the documented drop endpoint. Dropping does not delete watched or
resume history; subsequent watches/list additions may undrop the show upstream.

## Catalog navigation

Picks, lists, and history labels resolve names through the app runtime. Verified
active-library copies retain their server IDs, titles, artwork, and watch state;
otherwise an enabled, configured TMDB source can supply an unowned title.
An index miss is not proof that a title is absent from the user's libraries.
Lookup does not change tracker or server history. Account authorization,
profile restrictions, connection epochs, visibility, and metadata settings fence
asynchronous results. Native detail navigation consumes each request once while
keeping its ID observable long enough to dismiss integration sheets.
Season and episode records explicitly open the parent show; TMDB episode
coordinates never become invented server season/episode IDs.

Personal-key integration with the documented
[PublicMetaDB external API](https://publicmetadb.com/api-docs). Each user supplies
their own key. Connecting only verifies read access; it does not upload a library,
enable playback tracking, or import history.

## API and credentials

The typed client covers watched plays and dates, resume, dropped titles, ratings,
episode ratings, skip markers, highlights, mappings, anime mapping groups/chunks,
lists, Picks, and contribution votes. Public/private list creation is explicit.
The API does not document an OAuth flow or remote key-revocation endpoint;
disconnect removes Plozz's profile-scoped saved credential, not the website key.

Keys use the shared synchronized Keychain token mechanism. Replacement creates
a new connection identity. Profile changes and replacement invalidate existing
clients before asynchronous verification, including requests waiting for quota.
Requests are fixed-origin, bounded, cookie-free, and omit URLs from diagnostics.
Do not put keys in URLs, QR codes, UserDefaults, or test fixtures.

### Browser-assisted key entry

`PublicMetaDBBrowserPairing` creates a ten-minute, eight-character code at
`plozz.app/publicmetadb`. The browser encrypts a user-pasted key with ephemeral
P-256 ECDH, HKDF-SHA256 and AES-256-GCM for the requesting app's in-memory private
key. The QR fragment pins that public key; neither the API key nor the app's
separate 256-bit redemption secret appears in the URL. Manual code entry trusts
the HTTPS relay's public-key lookup. The website itself is part of this trust
boundary because it serves the encryption JavaScript.

The protocol is version 1: unpadded canonical base64url; X9.63 public keys;
HKDF salt is the eight-character code and info is
`plozz-publicmetadb-pairing-v1`; GCM authenticated data appends `:` and the code
to that info. The sealed value is nonce (12 bytes), ciphertext (63 bytes), then
tag (16 bytes). The app rejects different versions, sizes, codes and keys.
Polling is capped at 200 attempts with three-second waits and checked expiry.
Requests are fixed-origin, cookie-free, response-bounded and URL-redacted.

The separate `brandomoore/plozz-website` repository owns the relay. Its non-public
`plozz-publicmetadb-pairing` Worker hosts the `PUBLICMETADB_PAIRING` Durable Object
without changing the website's version-only publishing. Redemption, expiry and cancellation
are serialized rather than relying on eventually consistent KV get/delete.
Profile changes, replacement and page exit invalidate local handoffs. Remote
revocation is best-effort with a bounded timeout; a lost creation response or
unreachable relay leaves only temporary encrypted state until its expiry.
Nothing restores a pending pairing after relaunch. The existing read-only key
verification and synchronized Keychain save run only after a current handoff.
Cancelling replacement re-verifies the previously saved key in an uncancelled,
connection-fenced task. Its original identity and consent remain intact; old
invalidated clients are never revived. A failed re-verification is shown rather
than claiming the saved key is connected.
The entry screen also restores the saved connection when cancelling after a
completed relay/key-verification failure. Credential-persistence failures remain
explicit and are not cleared by closing the entry.
Direct entry remains available when the relay is unavailable. Transport-rejected
error pages, including oversized HTML from an unpublished route, show the same
actionable manual-API-key fallback rather than a generic response error. Pairing
failures retain their typed, localizable messages in `Phase.pairingFailed`;
they must not pass through `AppError.unknown`, which intentionally displays a
generic fallback. The new Worker
binding and production activation require separate deployment approval.

Real production TV, iPhone and iPad simulator checks verified replacement-confirmation
cancellation, entry cancellation with relay revocation, invalid-key rejection
and restoration of the saved connection, and disconnect cancellation. Confirmed
disconnect survived a normal relaunch. Actual QR/code browser reconnection and
native manual re-entry of the same dedicated key restored authenticated
private-list access; a final relaunch retained the connection with optional
ratings off. Independent complete list/history/resume fingerprints were unchanged.
Mobile manual entry used the native Paste action, with a local-only, expiring
simulator clipboard whose previous contents were restored and checked. Real keys
never pass through XCTest typing arguments or logs.
This does not establish second-member key replacement, iCloud propagation,
or in-flight mutation/consent boundaries.

Non-idempotent writes are not automatically retried. A lost reply, malformed
successful reply, or ambiguous server failure is an uncertain write, not proof
that nothing happened. HTTP 207 batch outcomes retain item-level failures.
Complete history/resume reads validate pagination, totals, and duplicate IDs;
a capped or incomplete read cannot become a successful import snapshot.
Writes validate returned identities and values, not just a success flag or row
count. Episode ratings support season-only queries, and resume reads support
external-ID lookup. Picks retain open-ended recipe filters and weights without
interpreting unknown options or substituting local recommendation behavior.
Picks report the full candidate total while exposing at most five pages of
twenty recommendations. Their validation checks that capped window, including
exact page sizes and catalog identity, without changing the returned candidate
total or weakening complete-history/list validation.

Resume uses whole milliseconds; the live API rejects decimal values. Playback
and export samples truncate submillisecond precision before encoding and
readback comparison. Malformed fractional remote values are not silently rounded.
Movie responses normalize the upstream zero-valued season/episode storage fields
to absent coordinates; nonzero movie coordinates remain invalid. Resume writes
send those zero storage fields explicitly: omitting them makes the live API
miss an existing movie's upsert key and reject its update as a duplicate.
This wire representation does not turn movies into episodes. Timestamp reads
accept both ISO `T` separators and the service's space-separated storage dates.
PublicMetaDB ignores progress below 2% and clears
resume at 80%; that does not mean Plozz or a media server considers the title
watched. Plozz's completion threshold remains 90%. Watched dates distinguish
omitted/current, explicit null/unknown, and a known timestamp. Reads also accept
the service's empty-string storage representation of an unknown watch date;
missing fields, whitespace and malformed nonempty dates remain invalid. A new watched
record is another play; do not use blanket deduplication to suppress rewatches.

## Server history comparison

`historySnapshot()` reads all required watched and resume pages. It produces
observations for the shared `TrackerHistoryImportSession`, not server writes.
The Settings comparison shows explicit server-user destinations and current
server state. Users select supported differences and confirm before delivery.
Missing records never mean unwatch, delete, or clear resume.
Before queueing an approved import, the shared session reads another complete
tracker snapshot and compares all records relevant to the selected titles.
Changed or removed plays, new conflicting records and changed connections
require a new comparison; unrelated titles do not invalidate the selection.

The existing guarded watch outbox performs approved writes without expansion to
other servers or tracker mirrors. Runtime authorization checks profile, resolved
server user, connection, live playback, and the still-open comparison. A separate
dispatch precondition checks a freshly read server baseline before each write.
Confirmation reads the server again; an uncertain response is not blindly replayed.
It waits for an already-running drain before readback. Comparison rows are paged,
and interrupted or failed readback leaves outstanding outcomes unconfirmed.
Closing the page or finishing the bounded attempt revokes undelivered work.
Approval is never restored as a grant after relaunch.

Imports currently express watched flags or compatible resume positions, not
exact server play counts or historical dates. Existing watched state is left
alone; conflicts require selection and confirmation. Episode matches require
confirmed ordering or verified exact episode and parent external IDs at the
same coordinates, always for a single-episode file. PublicMetaDB snapshots
resolve each distinct episode once through the configured TMDB metadata source.
This adds matching evidence without changing the original tracker identities or
ongoing-sync fingerprint: newly available metadata is not new tracker activity.
Changed evidence invalidates a reviewed preview; lookup failures or changed
connections cannot publish a partial snapshot. Aggregate episode counts are not
fabricated into individual plays. Server plugins can forward server changes;
the confirmation discloses that consequence. Read-before-write checks cannot
provide a server-side transaction against a concurrent third-party writer.

### Ongoing imports

After reviewing a comparison, users can separately enable **Ongoing sync** for
selected server users and watched state and/or resume points. Consent is local
to this device, profile, and saved-key connection. Connecting, one-time imports,
playback reporting, and cross-server watch sync do not grant it. Replacing the
key requires new consent; changing the profile or server user fences delivery.

Enrollment rechecks the reviewed complete snapshot and stores its one-way
evidence fingerprints without importing that existing history. Foreground and
completed-index events may check new evidence, with a fifteen-minute minimum
between automatic attempts; **Sync now** is explicit. Each attempt is bounded
to sixty seconds and twenty-five new records per selected server user. There
is no polling timer or work after leaving the foreground. The same controller
supports other history readers with durable connection identities; see the
[Settings capability rules](../FeatureSettings/README.md). Simkl remains
manual-only, using its activity-gated reads.

Disconnect or key replacement durably disables the permission before changing the credential, even
when comparison has not been opened in this process. Restoring that old saved
key cannot reactivate revoked consent. If permission persistence fails, delivery
is paused in the current process and the UI asks the user to retry before closing
the app; it does not claim revocation survived a restart.

Only non-destructive, conflict-free changes use the existing guarded outbox.
Current playback is deferred without consuming the new record. The `tracker-history`
debug events distinguish attempt start, completion, and per-item playback deferral
without logging titles or account IDs. A foreground event does not itself prove an
attempt ran: foreground admission and the automatic interval still apply.
Changed server state, incompatible or ambiguous
matches, unsupported facts, removals, and unconfirmed deliveries require review.
Category consent limits which new changes can be imported; it does not hide
competing records from the complete tracker snapshot. An existing watched record
can therefore hold a new resume for review even with resume-only consent.
In particular, a later resume change that conflicts with an existing server
resume is not silently advanced. Imported flags do not recreate play dates or
counts, and imports never dispatch another tracker scrobble.

The durable ledger retains the initial source fingerprints and per-server-user
receipts, not a replacement watch-history database. Attempts and target holds
are saved before writes. Missing/corrupt records or failed persistence block
delivery; pending receipts survive restart without automatic replay. Fresh
server readback can confirm a lost reply during that attempt. Even a new source
record cannot bypass an uncertain target hold; reviewing and re-enabling consent
establishes a new baseline. Baseline/receipt buckets stay under the durable
store's per-record limit, and snapshots over 100,000 observations are rejected
for ongoing imports rather than truncated. One-time comparison remains separate.
Local receipts cannot provide exactly-once delivery across other devices or
third-party server writers.

## Explicit server-history export

The TV and mobile account pages offer a separate **Export server history** flow.
Users choose a server user, library, and watched-title or resume mode. Read-only
preview walks bounded provider pages, probes the advertised end, refreshes relevant
items and parent-series identities, and rejects partial inventories and ambiguous
duplicates. Movie IDs and single-episode TMDB identities must be confirmed.
Episodes with another or unspecified server order require the same exact
child/parent reference proof as playback reporting; coordinates are not translated.
Reference reads are deduplicated within the preview, and the retained proof is
checked against the fresh source again at approval and dispatch. Missing proof,
conflicting IDs and combined files remain unavailable.

Watched backfill adds at most one missing play. It preserves an available server
last-play date only when there is no unfinished resume; otherwise the date is
explicitly unknown. It does not reconstruct earlier plays or play counts.
The `dedupe=true` API option is used only for backfill, never genuine playback
rewatches. Resume export copies seconds as milliseconds only within PublicMetaDB's
stored range `[2%, 80%)`. Its original update time cannot be backdated upstream.
Missing server records never authorize unwatch, deletion, or progress clearing.

Nothing is selected automatically. Each approval covers at most 50 selected
titles in the still-visible preview. Conflicting tracker progress/history and
automatic undropping require explicit selection and confirmation. Live playback,
profile/server-user/key changes, closing the page, or stale server/tracker
baselines stop delivery. There are no media-server writes or inferred ongoing-sync
grants. Other clients may react to PublicMetaDB changes.

The local request gate serializes complete playback/history-edit/export mutation
operations, while unrelated reads remain available. Export refreshes the source
again at actual dispatch, after quota waits. The API has no compare-and-swap for
resume points: another device/plugin can still race those preconditions.
Non-secret, profile/connection/content-scoped receipts are saved before dispatch.
Uncertain writes require independent readback and survive relaunch without
replaying. Confirmed backfills are not resurrected after remote deletion.
For selected episodes of the same dropped show, an acknowledged watched write
and its readback can advance only that batch's expected dropped flag. Other
history/resume baselines still need exact equality; a later re-drop stops the
batch. An ambiguous response does not grant that baseline adjustment.
Definite refusals permit a fresh preview, not automatic retry. Partial batches
retain individual outcomes and stop at the first unconfirmed result.
On iOS/iPadOS, controls use the native borderless button style to keep separate
actions inside the composite list cell from activating the first server picker.

## Watchlist destination

Users explicitly choose one of their own lists and confirm its current visibility
before it joins the universal watchlist. Consent is local to the device and
profile, bound to the verified key connection and a unique selection identity.
Stopping sync, changing profiles or replacing credentials immediately fences old
requests. Re-enabling creates a new consent identity; old queued writes cannot
move to a new list or key. Merely connecting a key grants no list writes.
Changed remote visibility blocks further writes until the list is confirmed again.

The shared watchlist registry, alias ledger, hydration and durable outbox own
membership and fan-out on both platforms. The adapter supports strongly identified
TMDB movies and whole series, not title matching or guessed anime ordering.
Complete list reads reject changed totals, missing pages, duplicate record IDs,
duplicate content and episode entries. Removal addresses the exact observed list
item, never the list itself.

The existing outbox's stable delivery ID is recorded before dispatch in the
durable local-state store. Receipts contain no keys. A lost or stale reply requires
fresh complete membership readback; failed verification parks delivery rather
than automatically repeating it, including after relaunch. A later observation
can resolve an earlier uncertain membership change. Confirmed receipts prevent
replaying an old delivery after someone independently changes the remote list.
Read-before-write cannot provide a transaction against concurrent remote editors.

Confirmation discloses existing/future watchlist changes, propagation to other
enabled destinations, public-list visibility and the possibility of PublicMetaDB
undropping shows added to lists. It does not authorize watched-history or
progress imports.

## List management

Account browsing includes explicitly private/public custom-list creation, owned
list deletion and exact-entry removal, plus read-only public-list URL browsing.
Picks can be added to an owned list after a visibility confirmation. List changes
are explicit actions, separate from selecting a universal-watchlist destination.

Management verifies current ownership and shown visibility before dispatch, then
reads the complete affected collection independently. An uncertain creation is
never automatically repeated. Ambiguous addition/removal/deletion is accepted
only when complete readback proves the requested result. Deleting the selected
destination first stops its automatic writes without deleting server history.
Profile/key changes close the account browser and fence all outstanding requests.

Real iPhone-simulator acceptance covers private/public creation, visibility
confirmation, public-URL resolution, exact movie membership add/remove, and
cancelled/confirmed owned-list deletion. The public URL was obtained from the
actual anonymous website, not inferred from the credential's local label.
Independent API reads verified the same list and movie, cancellation preserving
membership, and HTTP 404 by both ID and URL after deleting the disposable list.
Other lists and the tracked movie/episode histories on the dedicated Emby,
Jellyfin and Plex identities stayed unchanged.

This testing exposed a native dialog dropping sibling message paragraphs.
Shared Settings confirmations now compose the reviewed details and disclosures
into one localized `Text`. Real public-add and play-date/new-play cancellation
screens verified complete messages; this does not establish live acceptance
of the remaining watchlist or community-contribution workflows.
The live API stores omitted list descriptions as empty strings. Creation and
readback treat those two empty representations equally, while still rejecting
changed nonempty descriptions or visibility.

## Explicit history management

Individual account records expose play-date edits, deletion of one exact play,
resume clearing and undropping. Users can add a separate dated or explicitly
undated play, including a deliberate rewatch. These are PublicMetaDB changes,
not server-history imports or playback events; other connected clients may
nevertheless react to the tracker change.

The watched-history endpoint supports pagination, not title filters. Playback
reporting and export read every page before selecting the exact movie or episode;
an incomplete account history never becomes an empty title history. This costs
an account-history scan per fresh check, bounded by the existing page budget.
Title-history browsers paginate those matched records locally; show/season
browsing includes the matching episodes without crossing movie/TV namespaces.
Resume lookups continue to use the documented server-side identity filters.

History editing reads complete account history before dispatch and requires
the exact record identity/date to remain unchanged, even when other titles are
present. Removal uses an exact
record ID, not a title-wide watched deletion. Successful replies need independent
readback. Missing fields, foreign identities, replacement progress and uncertain
creation are never treated as successful resets or permission to retry.
Unchanged dates and already-absent exact records do not issue redundant writes.
No upstream compare-and-swap exists, so another client can still race between a
preflight read and the request; the UI does not promise transactional editing.
Title controls in native card/detail menus, Picks, list entries and history
records expose the same explicit history actions. Opening these controls neither
starts playback nor marks the title watched.

Real iPhone-simulator acceptance covers dated/undated play creation, independent
rewatches, known/unknown date changes, exact no-op date preservation, cancelled
and confirmed exact deletion, and selected bulk deletion. During a four-play
deletion, an independent real API writer changed the third play after the first
removal. Plozz confirmed two removals, stopped at the changed record, left the
fourth untouched, and blocked replay until history was refreshed and selected
again. Independent readback confirmed each exact record, the subsequent cleanup,
and preservation of the original play, other tracker collections, and dedicated
media-server histories. Retained native-driver failures concerned offscreen
selection/result controls; read-only follow-up scenarios verified the existing
outcomes rather than repeating destructive requests. Interrupted transport and
other-platform acceptance remain separate.

Separate real iPhone acceptance verified a movie resume's identity/progress,
complete clearing disclosure, cancellation, and clearing after fresh review.
Independent real API edits exercised both an updated position and a replacement
record with the same content: the pending native confirmation rejected each and
preserved the newer state. After a fresh confirmation, the selected resume stayed
absent across relaunch. Other tracker resumes, watched plays, lists and drops,
and dedicated media-server positions/history remained unchanged. Those controlled
API edits are concurrency setup, not evidence of additional playback.

Real show-drop testing verified cancellation, exact drop/undrop across relaunch,
movie/episode controls excluding show-level drops, and automatic undropping after
an explicitly added episode play. A documented upstream side effect did not
occur in the live list tests: adding that show to either a custom list or a
watchlist created the correct membership but left the dropped record intact.
List-add and sync consent therefore disclose possible undropping, not a guarantee.
Plozz does not issue an additional undrop request to manufacture the side effect;
the explicit undrop action remains available.

Real catalog-navigation checks exposed mobile Search replacing a visible card
with its loading state during a long press. Same-query refreshes now retain the
loaded grid. After rebuilding the production simulator app, three cold movie
menu round trips, two show round trips, and an exact episode-history-to-parent
route passed. Independent dedicated-server and tracker reads found no history
changes from browsing.

A separately created private list verified show-entry navigation across
relaunches, matching all six season IDs and the synopsis read independently from
the real server. The temporary list was deleted afterward; original metadata,
history and the control list remained unchanged. A real account with no Picks
now shows an explicit empty result after loading and refresh.

An independently verified unowned movie was added to a disposable private list
through the real API as fixture setup. Native library Search returned no results;
the list entry opened the correct external title and release year across two
relaunches, without a library Play control. Independent Plex, Jellyfin and Emby
reads confirmed the title remained unowned. The list was deleted through native
confirmation; original lists and server/tracker histories remained unchanged.
This verifies the configured TMDB fallback, not native list-add coverage or
playback of an unowned title.

A real owned recommendation recipe exposed a pagination-contract defect: the
API returned 191 candidates but only five pages. After the Picks-only validation
fix, native iPhone acceptance checked all 100 real title/year rows, page-three
refresh, the final-page cap, and reverse navigation. Independent API reads
confirmed the same identities and order. A recommended movie opened its actual
library detail across relaunches, without starting playback or changing server
metadata/history. Exact API cleanup removed only the owned temporary recipe;
native refresh and relaunch returned to the empty state. This is native browsing
and routing coverage, not recipe-editor or other-platform acceptance.

## Optional community ratings

The profile-scoped rating lookup preference starts off. Enabling it sends the
strongly identified titles users browse to PublicMetaDB and adds an attributed
overall score alongside the existing rating providers on TV and mobile. It does
not submit personal ratings or replace server titles, artwork or IDs.

Movie/show namespaces remain distinct. Episodes require a parent-series TMDB ID,
confirmed TMDB ordering and one episode. For a library episode missing that
proof, detail lookup reads the exact scoped server item and parent through the
existing tracker history source, then verifies independent episode and parent
external IDs at the same coordinates. Aired numbering alone is not proof.
The verified order belongs only to the lookup copy; server identity/order is
not rewritten. Conflicting ID aliases do not select an arbitrary title.
Only the explicit `Overall` label is aggregated into this badge,
not acting/direction or other user-defined dimensions. Incomplete collections,
duplicate records, wrong identities and invalid averages are rejected.

The service's five-minute, 256-entry memory cache is scoped to the live connection and
cleared on profile/key/preference changes. Pending requests are fenced too.
Home's cache-only path never starts a network lookup and cannot reuse an
episode badge through an unverified identity.
The lookup handle retains the original connection/preference epoch through
identity resolution, the aggregate request and a delayed base-rating response.
Ordinary keyed/keyless ratings remain available if this optional source fails; its failures are logged
without credentials or title data. Server-selected rating lists, including
intentional empty lists, do not trigger or reuse this contribution.
Existing profile-scoped page snapshots can retain previously displayed public
scores until refreshed; disabling lookup stops requests rather than rewriting
those snapshots. Contribution browsing retains each rating's own label and score;
it does not mix unrelated labels into an average.

Real production-iPhone-simulator acceptance verified native opt-in and opt-out
across ordinary relaunches, exact movie and show Overall scores, and no badge
for a show with 26 contributions but no Overall rating. In one unchanged app
process, publishing an owned Overall rating displayed 50/100; deleting that
exact record removed the badge. Both transitions completed inside the
five-minute cache lifetime without intervening preference, profile or key
changes. Independent reads confirmed restoration of all contributions and
unchanged server metadata, watched/resume histories and original lists.
This does not establish exact request counts, in-flight scope revocation,
server-selected rating overrides or other-platform acceptance.

The real episode case exposed and then verified a separate identity fix.
The server episode supplied episode IDs but neither a parent TMDB ID nor
confirmed TMDB ordering. After scoped parent enrichment and exact independent
identity verification, its own detail displayed the independently read 50/100
Overall score. Native deletion of the exact temporary contribution restored
all four original contributions and removed the badge. Eleven final-binary
native passes cover opt-in/empty, preparation/publication, positive lookup,
deletion/empty, movie/show regressions and opt-out; independent server metadata,
histories and original lists were unchanged. This episode result uses ordinary
relaunches, not a same-process TTL test. TV composition compiled, but native
TV/iPad and other-provider episode acceptance remain separate work.

## Explicit community contributions

Shared title controls support labeled movie/show/episode rating submissions,
exact-rating deletion, skip/highlight browsing and publishing, and contribution
votes. Every mutation requires confirmation, connection fencing and independent
readback. Ratings invalidate cached aggregate requests after a mutation attempt.
Ambiguous creation is not retried. Deletion rechecks the observed value,
contributor and revision and addresses only that exact record. The server
authorizes deletion; contributor names and vote state never establish ownership.

New rating labels cannot contain whitespace. The live API rejects such labels
with HTTP 422 even though its parameter documentation describes a generic
string. Single and batch publication validate this before requesting approval
or sending requests; existing contributions remain readable without relabeling.

Rating browsing validates identities, unique records and returned/total counts
without treating a capped collection as complete. The page discloses the limit.
Managed creation and deletion still require complete, unfiltered snapshots:
an omitted record cannot establish absence or confirm deletion. The live show
endpoint has returned 30 of 35 contributions while ignoring pagination
parameters; label filtering is not a substitute for complete management reads.

The shared contribution pages own their asynchronous reads outside the lazy
result rows. Long rating lists previously restarted the load as rows appeared;
the iOS and tvOS hosted regressions require one read while rendering, one
additional read on explicit refresh, and cancellation/reset when an optional
scope is disabled. Real production-iPhone-simulator browsing matched all 21 movie,
30 returned show and four episode contributions against independent API reads;
IDs, labels, scores, revisions and aggregates remained unchanged afterward.
Native refresh and ordinary relaunch repeated those checks.

Single-rating acceptance on that production iPhone simulator also covered
publication and deletion confirmation/cancellation for a real movie, show and
episode. Independent reads verified each exact new record, unchanged original
contributions and `Overall` aggregate, and complete restoration after deletion.
The capped show refused publication without creating a record. An uncapped
26-contribution show supplied the positive show case; a repeated round trip used
matching detailed server reads to verify metadata and history preservation.
No temporary rating remains. Source/destination histories, tracker histories
and original lists were unchanged. This is scoped single-rating acceptance,
not proof of all stale/ownership boundaries, season/batch
mutations or other-platform native real-data workflows.

A real concurrent-replacement check also passed. After native preparation of
an owned rating's deletion, an independent client deleted that exact test record
and created a new record with the same title, label and score. Confirming the
stale native action treated only the old ID as absent and left the replacement
unchanged. Native cleanup removed the replacement; all original contributions,
aggregates, server metadata, histories and lists were restored or unchanged.
Seven native passes include preparation, confirmation, cleanup and disabled
lookup after relaunch. This proves an already-deleted ID cannot retarget a
same-value replacement, not same-ID edit races or negative ownership enforcement.
The documented rating API exposes creation/deletion, not an update route; no
other person's contribution was used to test ownership.

Vote reads request only the authenticated user's records and require an explicit
`userVote` field. Neutral (zero) and absent (null) remain distinct. A fresh vote
must match the observation approved on screen before it can be replaced; the
server's subsequent own-vote read, not aggregate popularity, confirms the result.

Skip reads are bounded to 20 pages of 200 records for one playable identity.
Foreign IDs, incomplete collections and duplicate records cannot authorize
mutation. Timestamp forms preserve milliseconds, require explicit release
selection for skips and a user check of the times, and distinguish absent pairs
from zero. Highlight descriptions are hidden until explicitly requested. These
community timestamps are not automatically applied to playback: the API does not
establish a matching file/release fingerprint. Server markers remain unchanged.
The playback options on TV and mobile offer an explicit, read-only timestamp
browser. Highlights require a separate spoiler toggle. Contributions remain
separate, with their release source and attribution; no vote or runtime fit is
treated as proof of release compatibility. Each manual jump requires confirmation,
current playback/connection scope, exact snapshot membership and a finite range
within the active runtime. End-of-runtime jumps are unavailable. Stop, reload,
profile/key changes and cancellation revoke stale reads and selections.

Title routes preserve existing server titles and IDs. Missing/conflicting TMDB
identity, unconfirmed episode numbering and multi-episode files cannot trigger
guessed tracker requests. Seasons require the parent-series namespace and
confirmed TMDB numbering. ID-only records use the catalog resolution and normal
title navigation described above, not fabricated server identities.

## External-ID contributions

Title controls expose all external-ID contributions without choosing a winner
when values disagree. Reverse lookup preserves distinct movie/show namespaces
and multiple matches; it does not enrich or replace server identity.
Complete reads reject wrong title/type, duplicate record IDs, unknown database
groups, missing values and inconsistent totals.

Publishing first shows the existing forward mappings and every reverse match
for the proposed ID, including conflicts. Confirmation captures the connection
and both observations; changed observations block dispatch. A single creation
must return its exact ID and pass independent forward readback. There is no
automatic retry, replacement, or claim of a transaction against concurrent
edits. Exact-record deletion and voting reuse the common contribution controls
and server-side ownership checks. No operation here changes server metadata,
starts history reconciliation or changes playback routing.

## Anime mapping management

Show controls retain grouped recommendations, logical seasons, inclusive episode
ranges, specials and cross-show chunks. Complete reads count chunks rather than
groups and reject duplicate identities, unknown source types and inconsistent
totals. Recommendations are attributed to PublicMetaDB, not applied to server
episode ordering or playback matching.

Users review all chunks before explicitly publishing a replacement for their
logical season. The documented upsert replaces all chunks owned by the current
key, not whichever contributor happens to be displayed. A fresh complete
snapshot must match the review before dispatch; returned chunk IDs and values
must then appear together in one matching member group.
Local mutations for the same show/connection cannot overlap: a replacement,
whole-season removal or chunk deletion holds that scope through readback.

Whole-season removal explicitly selects the current key's contributions for a
logical season, not an inferred author. It requires the server's deletion count
and a complete readback showing exactly one whole matching member group removed,
with other chunks preserved (or a confirmed zero-change result). A missing
acknowledgement cannot be reconciled by guessing ownership from contributor
names. Exact single-chunk deletion and per-chunk voting remain separate actions.

The documented five-minute read cache may prevent immediate confirmation.
Stale cached results remain unconfirmed; they never authorize a blind write
retry. These are API-contract and fixture guarantees, not authenticated proof
of live cache invalidation or ownership behavior.

Season browsing validates the full grouped response, individual records and
per-label aggregates. The live API groups season aggregates under lowercase
labels while retaining each contribution's original label. Validation uses
those normalized groups, including combined counts for mixed-case labels,
without rewriting contribution labels or exact IDs. Missing, extra, split or
inconsistent aggregate groups still fail closed.
It rejects the potentially capped 5,000-record response
rather than calling it a complete season. Rated episodes are not presented as
an authoritative episode roster. Explicit batch submission/deletion supports
up to 50 unique episodes/record IDs and independently checks the complete season
afterward. Partial HTTP 207 outcomes retain confirmed IDs and unconfirmed
episodes/IDs, block blind replay, and never become a full success. Deletions
recheck every selected record before dispatch and never become season-wide resets.

Real production iPhone-simulator acceptance compared all ten rated episodes of
one season against independent API reads. Two explicitly selected episode
ratings were published through the native batch form, independently identified,
and removed through native exact-record selection. Both publication and deletion
cancellation preserved remote state; relaunch readback confirmed restoration of
all 40 original contributions and aggregates. Server metadata, watched/resume
histories and lists stayed unchanged, and optional rating lookup remained off.
This establishes that bounded round trip, not 50-item publication, partial-failure,
ownership or native TV acceptance.

A separate real batch-deletion race replaced one selected test contribution
with a new ID from an independent client while native confirmation remained
open. Approving the old selection removed only the remaining original selected
ID; the replacement survived unchanged. Native selection then removed that
exact replacement, restoring all original season records and unrelated controls.
This proves replacement-ID safety, not a same-ID edit or negative ownership
check; no other person's contribution was targeted.

Connected iPhone and iPad native-form checks also reject blank, zero, negative
and duplicate episode numbers and whitespace-bearing labels without approving any write.
Invalid values display input feedback, not a server-response error. The form
accepts 49 additions to its initial row, disables Add at 50, re-enables it after
one removal, and disables it again after replacement. Independent remote reads
confirmed all original records, aggregates and unrelated controls unchanged.
This proves the native entry limit, not a real 50-record publication or acceptance
of fabricated episode coordinates.

The same production mobile binary also completed the two-record round trip on
a separately onboarded iPad simulator, using normal server login and encrypted
browser-code connection. Both publication and deletion cancellation preserved
the exact remote state; exact deletion and relaunch readback restored all 40
original records and aggregates. Unrelated histories, lists and metadata stayed
unchanged, and optional rating lookup stayed off on both installations.
The native driver handles iPad's adaptive tabs, compact scroll containers and
frontmost confirmation backdrop; iPhone navigation, input and cancellation
regressions passed. This is platform UI coverage, not an independent-destination
history-sync round trip or proof of the remaining ownership/lifecycle boundaries.

Real production TV-simulator acceptance now verifies the same two-record season
round trip using native remote navigation. Publication/deletion cancellation
preserved the exact remote state; exact deletion and a final native read restored
all 40 original records and aggregates. Unrelated histories, lists and metadata
remained unchanged. Saved-key relaunch and disabled optional rating lookup also
passed on the final TV build.

That workflow exposed the automatic TV score picker's unreadable 101-segment
layout. Both single and batch forms now use accessible native menus. Actual
0/100/50 selection passed on TV, and 49/50 selection passed on fresh iPhone and
iPad builds, alongside real season reads, invalid-input and cancellation
regressions. These are simulator platform checks, not physical-device delivery,
partial/refused-result coverage or ownership/lifecycle-race acceptance.

## Reviewed multiple-play deletion

The account history screen supports selecting up to 50 records from a page.
Confirmation captures their exact IDs, observed dates and connection. All
selected records are rechecked before the first deletion; each then uses the
same exact-record preflight/readback as an individual removal. No title-wide
delete is substituted, so a concurrent rewatch is not part of this approval.

The first unconfirmed result stops subsequent records. The typed failure retains
confirmed IDs, the stopped record, unattempted IDs and the underlying error.
The UI reports partial completion and requires refreshing/reviewing a new
selection rather than replaying the old one. Cancellation/profile changes never
roll back confirmed remote deletions or claim the remaining records succeeded.
Media-server writers and tracker-import routes are not involved.

## Implementation and verification status

The current app surfaces provide connection management, account browsing,
individual/selected-play management, one-time server-history comparison/import,
opt-in watchlist/playback/community-rating integration, and explicit rating,
season/batch-rating, timestamp and voting controls. Catalog results can hydrate
and navigate to exactly matched library titles. Mapping management and reviewed
server-to-PublicMetaDB history export are also implemented. Trakt, Simkl, WeTrakr
and AniList/MyAnimeList feed the shared history comparison, with provider-specific evidence
and limitations rather than invented progress.
The existing TV Last.fm integration offers separate read-only listening history.
PublicMetaDB, Trakt, WeTrakr, Simkl and AniList/MyAnimeList also support separately
approved, device-local ongoing imports with the capability limits described above.
Broader historical backfill and authentic end-to-end acceptance remain unfinished.
Do not describe this foundation as full end-user support.

Contract/lifecycle/transport fixtures and guarded-import tests are automated.
They are not authenticated service evidence. Release acceptance still requires
dedicated real accounts, authorized real-media playback in Plozz, independent
tracker/server readback in both directions, and exact run-owned cleanup.

On 1 November 2026, real movie resume reporting was verified from the normal iOS
app on an owned simulator against dedicated Emby and PublicMetaDB accounts.
Independent reads confirmed creation, repeated updates of one record, relaunch
persistence, no resume below 2%, and resume removal above 80% without a watched
play. Opt-out suppressed uploads; re-enabling did not backfill old sessions and
allowed only new playback to create another resume. This is a narrow movie/
iOS-simulator/Emby result, not acceptance of TV playback, episodes, other
providers, watched completion, or cross-device synchronization. The separate
one-time import result below does not extend that playback coverage.

The same real movie resume was then imported through native comparison and
explicit confirmation into an independent, dedicated Jellyfin user. Connection
and cancelled confirmation left its zero progress unchanged; approval set
exactly 49.557 seconds without marking watched or incrementing play count.
Independent reads confirmed the Emby source and PublicMetaDB record stayed
unchanged. Relaunch showed both server users already matching without another
write. A destination-only control changed progress from 75 to 90 seconds after
preview: stale approval left 90 seconds intact and reported an unconfirmed
result. Fresh comparison, conflict review and approval restored 49.557 seconds.
This proves the tested movie-resume import and server-staleness guard on an iOS
simulator, not automatic ongoing sync, two-device delivery, watched imports,
episode imports, or other tracker/provider routes.

On 2 November 2026 UTC, additional real iPhone-simulator checks confirmed movie
completion, a distinct rewatch, and multiple-title reporting. The second movie's
resume matched the source's whole milliseconds; completing it added one dated
play and cleared that resume without changing the first movie's records.
Separately enrolled watched-only ongoing import did not backfill, then delivered
that new play to the dedicated Jellyfin user. A repeated sync after relaunch
changed neither server state nor tracker history. Ordinary cross-server playback
mirroring was disabled through Settings to isolate this route. A destination
with prior-play recency correctly remained a review conflict, not an automatic
overwrite. Independent-device delivery, episodes and the remaining
provider/tracker routes are still outside this evidence.

Further real resume-only checks confirmed category isolation, revocation and
re-enrollment without backfill, followed by exact import of newly reported
progress into an empty Jellyfin destination. Watched state/count stayed unchanged;
the existing provider resume setter updated recency for Continue Watching.
Relaunch and repeated sync were no-ops. These checks exposed a continuation gap:
any differing existing resume required review, even when this sync had written
the unchanged destination. The shared controller now retains confirmed
destination fingerprints, permitting only safe forward progress or completion.
See [ongoing import invariants](../CoreModels/README.md#ongoing-tracker-import).

Real iPhone-simulator playback then verified forward continuation from
1548.218 to 2307.588 seconds, preserving the Jellyfin user's unwatched/count-zero
state. An independent destination-only edit to 2500 seconds was preserved when
later source playback reported 3067.161 seconds. Explicit native review restored
synchronization; a subsequent real source rewind remained review-only.
Separately enabling both categories did not backfill. Following explicit
review, actual source completion became one dated PublicMetaDB play and an
ongoing Jellyfin watched update/count one with resume cleared. Independent reads
confirmed no tracker echo or unrelated title/server changes, and relaunch/repeat
remained a no-op. This verifies the tested movie continuation route, not
foreground timing, independent-device delivery, episodes or provider parity.

Real foreground testing also verified conservative conflict deferral: a new
movie resume alongside existing tracker watches left the empty Jellyfin
destination unchanged after the automatic cooldown. Native comparison identified
the competing records, and Ongoing sync displayed its review requirement.
The original delivery assertion remains failed evidence, not a positive import.

A separate clean movie then verified actual automatic delivery: enrollment did
not backfill; an early foreground return left the destination unchanged; after
the real fifteen-minute cooldown, foreground activation imported exactly
120.394 seconds without pressing Sync now. Watched/count stayed false/zero;
the normal Jellyfin resume setter updated Continue Watching recency. Relaunch
and an explicit repeat did not replay the write. After revocation, new actual
source playback advanced the tracker to 242.374 seconds while the destination
retained 120.394 seconds, including after relaunch. Reporting and ongoing import
were turned off afterward. This is same-installation foreground evidence, not
independent-device or platform parity.

Independent-device checks now cover a normal iPhone-simulator Emby source and a
separately authenticated iPad-simulator Jellyfin destination. Native Quick Connect
authorized only the dedicated nonadministrator destination user; no password was
typed through XCTest. Reporting and import permissions stayed device-local, and
ordinary cross-server mirroring was disabled on both installations.

Actual source playback produced one watched event, which the destination imported
once. Watched-only permission ignored a different movie's real resume. Separately
enabling both categories did not backfill its existing 182.948-second progress;
new source playback then delivered exactly 337.004 and 491.869 seconds. Completion
replaced that confirmed destination resume with watched/count-one state.
Independent server and complete tracker-history reads verified no echo with
destination reporting enabled, no repeated write after relaunch, and unchanged
control histories/lists. Test opt-ins were revoked afterward.

The first candidate correctly required review because the destination retained a
previous playback date despite being unwatched with count zero. A destination-only
fixture reset did not clear that date; untouched real titles established the
positive route instead. No conflict protection was relaxed. This is movie
watched/resume evidence using explicit destination Sync now, not TV playback,
reverse-device delivery, every provider/tracker, or physical-device testing.

Additional native movie playback now covers the owned iPad and TV simulators
against the dedicated Emby source and PublicMetaDB account. The iPad reported
exactly 181.372 seconds; the final TV driver reported exactly 29.934 seconds.
Each matched independent source whole milliseconds. Actual playback past the
completion threshold added one dated tracker play and cleared resume; cold
relaunch and reporting opt-out did not replay history. Complete tracker-history
reads and separate server controls confirmed only the intended title/user changed.

The final TV driver measures the real starting clock rather than assuming cached
detail state resumes playback. It uses native transport and verifies return to
detail after stopping. Failed driver attempts remain recorded separately,
including their actual remote effects, rather than counted as acceptance.
The shared TV Search helper also passed a read-only real season-ratings regression.
Playback was muted after the request for silent tests, with zero simulator output
volume verified before each later native run. This extends movie playback platform
coverage, not episode platform parity, other providers/trackers, interruption
recovery, or physical-device testing.

Real native Plex Link sign-in now succeeds for the dedicated nonadministrator
managed test user. The initial HTTP 403 came from the private acceptance
authorizer omitting Plex's `X-Plex-Product: Plex SSO` link header; the same scoped
credential authorized a new native code with HTTP 204. No owner credential or
permission change was needed.

On the owned muted iPad simulator, guarded movie imports changed only the
selected Plex user: a watched flag produced count 1, and a separate real-playback
resume imported exactly 242,374 milliseconds without adding a play. Cancelling
left state unchanged. A real concurrent server edit from 75 to 90 seconds
invalidated the prepared import; a fresh comparison and explicit approval
restored the tracker position. Cold relaunches did not repeat either write.
Independent reads verified unchanged unselected server histories and complete
tracker history/list boundaries.

The native driver now bounds longer three-provider comparisons and waits for
verification before locating result rows that shrink after delivery. Failed
driver attempts remain in the evidence. One comparison showed an unavailable
server before any write; an explicit retry delivered the resume, which was
confirmed independently and in the same process without replay. These checks
establish guarded movie imports, not Plex ongoing sync, exports, playback,
episodes, other providers, or physical-device acceptance.

Separate real ongoing-import checks now cover the dedicated Plex destination on
the muted iPad simulator, driven by actual Emby playback on the muted iPhone.
Watched-only consent ignored a new resume, then imported the completed viewing
with count 1. Resume-only consent imported exactly 254,799 milliseconds and
safely advanced the unchanged destination to 481,052 milliseconds. Completing
that source viewing did not import its watched flag or clear the Plex resume
without watched consent. Unselected Jellyfin histories remained unchanged.

Revocation survived relaunch and blocked a different movie's new 276,623-ms
resume. Explicit re-enrollment with both categories did not backfill that
position; subsequent real playback delivered 524,001 milliseconds. Completion
then replaced that confirmed resume with watched/count-one state. A separate
preexisting tracker resume also remained absent from Plex throughout enrollment.
Repeated checks and cold relaunches preserved server state and tracker records.
Complete remote-history and list comparisons found no unrelated changes or
tracker echo; test opt-ins were revoked afterward.

The scoped audit covers 38 passing native runs and 30 independent snapshots.
One comparison failed with a server-unreachable message before enrollment;
unchanged remote state and a later successful comparison are recorded separately.
These are explicit **Sync now** movie checks, not Plex automatic foreground
timing, playback/export, episodes, all lifecycle/race cases, or physical-device
acceptance. The driver bounds long comparisons and verifies that only the
intended server-user destination is selected.

Real Plex-source movie playback and reviewed exports were then verified on the
muted iPad simulator, with only the dedicated Plex user selected. Reporting-off
playback saved 296,936 milliseconds on Plex without touching PublicMetaDB.
Resume-export preview and cancellation wrote nothing; explicit confirmation
copied that exact position, and cold relaunch offered no repeat.

This exposed duplicate Plex play counts: timeline completion and the final
watched-state convergence both counted one viewing. Bounded independent reads
observed count 2 to 3 to 4 during one native session. The provider now recognizes
an already-completed movie or episode before scrobbling again. On the rebuilt
production app, the same native flow advanced count 4 to 5 only; a subsequent
genuine rewatch advanced 5 to 6 only. The focused Plex suite passed 414 tests.

Watched export displayed the existing tracker resume as an explicit conflict.
Cancellation preserved it; confirmation added one missing play with Plex's exact
last-play date and cleared the conflicting resume. It deliberately did not
reconstruct Plex's play count. Relaunch made no further changes. Enabling playback
reporting then published an actual 431,993-ms resume and exactly one new tracker
play on completion, preserving the earlier backfill record.

The source audit retains 34 native UI passes, including two negative duplicate-
count reproductions, 16 independent snapshots, and one failed cleanup check
caused by the driver's wrong expected user. Corrected checks passed. Full tracker
history/list comparisons and unselected Emby/Jellyfin users were unchanged.
Reporting/import consent was disabled and the original source selection restored.
This is one real movie's simulator evidence, not Plex episode/platform parity,
all lifecycle races, or a distributed exactly-once guarantee.

Guarded Emby movie imports were also verified on the muted iPhone simulator.
Native comparison and cancellation left the dedicated user's history unchanged.
Explicit watched import changed an untouched movie to watched/count 1, without
copying tracker play counts. A separate resume import delivered exactly
1,044,003 milliseconds while preserving the movie's existing watched flag and
play count 5. Both remained unchanged after cold relaunch.

Controlled edits of the dedicated user's resume from 75 to 90 seconds while
the native preview was open verified stale-state rejection. Fresh comparison
and explicit conflict approval then delivered the tracker position. These edits
are real-server race controls, not playback acceptance. The initial control's
post-write assertion rejected an expected derived-percentage change; fresh
readback confirmed the write without replaying it.

The native driver now distinguishes watched and resume actions for the same
title/user and scopes result lookup to the expected status. The audit retains
16 native passes, two failed driver assertions and 15 independent snapshots;
two earlier ambiguous selections are excluded from exact resume claims.
Complete tracker histories/lists, Plex/Jellyfin users and unrelated Emby titles
were unchanged. Reporting and ongoing-import consent remained off. This covers
guarded movie imports, not ongoing Emby sync, episodes, all lifecycle boundaries
or physical-device acceptance.

Separate ongoing Emby movie checks used genuine Plex playback on a muted iPad
and the dedicated Emby destination on a muted iPhone. Watched-only consent
ignored new resume data, then imported the completed viewing with count 1.
Resume-only enrollment did not backfill an existing 344,343-ms tracker position;
new playback delivered exactly 659,888 milliseconds and then 977,299 milliseconds.
Completion did not mark that destination watched or clear its resume without
watched consent.

Revocation survived relaunch and blocked another movie's new 334,779-ms resume.
Re-enrollment with both categories did not backfill it. Subsequent real playback
delivered 640,458 milliseconds; completion converted the confirmed destination
resume to watched/count-one state. Repeat syncs and cold relaunches changed
neither server counts nor tracker history. All unselected Jellyfin titles, an
unrelated Emby control, full tracker histories outside the source titles, and
test lists remained unchanged. Test consent was revoked and source selections
restored.

The scoped audit retains 44 native passes, four failed driver checks and 30
independent snapshots. The initial two snapshots contain selected cases only;
the prior guarded-import cleanup and post-enrollment full readback agree.
All later snapshots contain complete tracker watched/resume history. The first
resume arrived on foreground before a native navigation assertion failed;
independent reads and read-only native inspection confirmed delivery without
repeating playback. The driver now waits for comparison activity to finish,
keeps navigation inside the visible list and waits for the destination page.
Final consent-off checks passed on both mobile layouts.

Plex rounds fractional milliseconds while PublicMetaDB floors them; source
readback can differ by one millisecond, but imported destination positions must
match the tracker exactly. This evidence covers three movie routes, not Emby
episode/platform parity, measured foreground cooldown, network-loss recovery
or a distributed exactly-once guarantee.

Guarded Silo movie imports now have real native iPhone-simulator evidence.
Production device approval selected the dedicated server profile and movie
library; the independent authorizer revoked only its temporary login. Watched
preview and cancellation made no changes, explicit approval changed only the
selected movie, and cold relaunch offered no repeat. A separate resume preserved
the movie's unwatched state. Controlled server edits from 75 to 90 seconds
invalidated a prepared preview rather than overwriting newer progress.

The resume checks exposed two precision defects. Silo's rounded catalog minutes
failed the existing one-second runtime guard even though its single file's
duration matched the tracker. The provider now uses that precise fallback without
relaxing the guard or choosing an arbitrary version. Independent readback then
caught a one-millisecond truncation despite native confirmation. Rounded integer
conversion fixed it; fresh native approval delivered exactly 1,044,003 ms, and
cold relaunch preserved both that position and its server timestamp.

A rate-limited comparison also remained an explicit failure before any write.
The connection now honors a shared API cooldown rather than continuing background
detail requests after a 429; expiry does not replay refused operations. Focused
Silo regressions cover runtime precedence, precision, invalid input and cooldown
recovery. Complete tracker histories/lists, unselected Emby/Jellyfin/Plex users
and Silo control titles stayed unchanged, with reporting and ongoing import off.
Failed native/driver attempts and the inaccurate first delivery remain separate
evidence. Silo's returned history cards do not expose independent play counts or
watch timestamps, so those are not verified. These are guarded movie imports,
not ongoing Silo sync, source playback/export, episodes or physical-device proof.

Separate ongoing Silo movie checks used actual Plex playback on a muted iPad
and native destination consent on a muted iPhone. Watched-only consent excluded
new progress, then delivered a completed viewing. Resume-only enrollment did
not backfill existing progress; subsequent playback delivered exactly 680,441
and 1,001,377 milliseconds. Completion left that destination unwatched and
preserved its resume, including after relaunch.

Revocation survived relaunch and blocked another movie's new progress.
Re-enrollment with both categories did not backfill that progress or the earlier
excluded completion. New playback delivered exactly 613,466 milliseconds;
completion converted that confirmed resume to watched state and cleared it.
Repeated sync and cold relaunch preserved observable Silo state and progress
timestamps. Complete tracker histories/lists, unselected media-server users and
Silo control titles stayed unchanged. Test consent and reporting were disabled,
and the original source selections were restored.

The scoped audit retains 43 native passes and 29 paired independent
Silo/tracker-control snapshots. Three failed native checks, two incomplete runs
and three preflight-only attempts are excluded from acceptance. One incomplete
completion was stopped when simulator audio unexpectedly became unmuted: its
source watch remained visible, while only the later successful viewing reached
the tracker. All nine accepted playback runs had uninterrupted mute monitoring.
The external audio reset's cause remains unknown. Silo does not expose
independent play-event counts or watch timestamps here, so unchanged observable
state is not an exactly-once guarantee. This covers three movie routes, not
Silo source playback/export, episodes, all lifecycle boundaries or device parity.

Separate Silo-source movie checks now have production iPhone-simulator evidence.
With other sources disabled, actual playback below 2% left the tracker untouched,
in-range playback reported exactly 628,501 milliseconds, and playback above 80%
cleared that resume without creating a watch. Two separate completed viewings
produced exactly two dated tracker plays; watched export recognized them as
already present. With reporting disabled, another completed movie stayed absent
from the tracker until explicitly exported as one play with an unknown date.
Cancellation and cold repeat did not create duplicates or fabricate watch dates.

A real 703,083-ms Silo resume exposed a missing export row: native catalog
cards omitted progress even though item detail and the progress endpoint held it.
Providers can now declare incomplete catalog resume fields. Resume export
supplements the complete selected-library inventory with the existing fully
paged, scoped Continue Watching feed, validates its membership, and still rereads
each relevant item before comparison and confirmation. It does not hydrate every
catalog title, infer progress from a rounded runtime, or treat a feed failure
as an empty successful comparison. The repaired native preview, cancellation,
confirmation and cold repeat preserved exactly 703,083 ms with a 6,736,000-ms
file runtime.

This source tranche retains 33 native passes, 20 paired independent snapshots,
and seven continuously muted playback runs. Two native failures remain excluded:
the original missing export row and a rate-limited search recovered through the
existing Try Again action. An exploratory progress-sorted catalog request also
returned HTTP 500 and is not acceptance evidence. The final covering package run
passed 3,464 tests with five opt-in performance probes skipped. Complete tracker
histories/lists, unrelated server users and Silo control titles stayed unchanged;
reporting/import consent is off and the original source selection is restored.
Cold-start identity-index request pressure remains separately open. This movie
scope does not establish episode, physical-device or whole-branch readiness.

Separate read-only transport preflights fetched the same two-mebibyte movie
prefix through dedicated SMB, NFS, WebDAV, FTP and host-key-pinned SFTP access.
All five matched an independently authenticated media-server file range.
This verifies real media access, not native share onboarding or tracker delivery.

On 2 November 2026 UTC, real Emby playback of The Crown S1E1 exposed missing
episode-order evidence. Exact TMDB child/parent verification repaired the route
without changing server ordering. On the production iPhone-simulator app,
actual playback below 2% produced no resume, in-range playback reported exactly
369,911 milliseconds, playback above 80% cleared resume without marking watched,
and two separate 90%-plus viewings produced exactly two dated plays.

The separate Jellyfin test user received the exact episode resume through an
already-consented foreground check. With ongoing sync disabled, native comparison
and cancellation left history unchanged; an explicitly selected import set the
same resume without incrementing play count. A later selected watched import
marked only that episode watched/count 1 and cleared its resume. Relaunch and
repeated ongoing checks did not replay either tracker plays or server counts.
The adjacent episode, unrelated movie histories, Plex user and test lists stayed
unchanged. That ordinary-episode result does not establish combined-file behavior,
episode continuation, independent installations or other provider/platform routes.
Package tests separately cover strict identity conflicts,
no-backfill fingerprints, stale connections, cancellation and unavailable metadata.

Further real iPhone-simulator checks verified Jellyfin special-episode reporting:
the file, source coordinates and exact child/parent external IDs agreed with the
TMDB reference. Actual playback reported the exact 181,392-millisecond resume;
a rewind below 2% preserved that prior remote point, crossing 80% cleared it
without a watch, and two genuine completed viewings created two dated plays.
Relaunch and consent replacement did not replay history.

Separate real Emby specials exercised rejection: one file's child identity mapped
to a different TMDB episode number, and another lacked child IDs. Actual in-range
playback remained available locally, but neither was reported. Fresh-consent
Settings showed the identity warning, and independent reads confirmed the entire
tracker watched/resume history and unrelated server users remained unchanged,
including after relaunch. This verifies rejection, not automatic renumbering.

A real Jellyfin file explicitly spanning S4E1-E2 then verified combined-file
rejection. Its two-episode range, file and runtime were independently confirmed.
Actual in-range playback and a separate completed viewing updated only the
source user's state; the entire tracker watched/resume history stayed unchanged.
Fresh-consent Settings showed the identity warning after each scenario. Relaunch
and restored library selection did not replay anything, and independent source
controls stayed unchanged. This is safe rejection, not combined-episode support.
Episode continuation, independent installations and the remaining
provider/platform routes still require their own live evidence.

Real Jellyfin episode exports were subsequently verified on a rebuilt production
iPhone-simulator app. With playback reporting disabled, actual source playback
created 398,660.889 ms of resume while PublicMetaDB remained unchanged. Native
preview, cancellation and reopening wrote nothing; explicit export copied
398,660 whole milliseconds without changing either server. Relaunch recognized
the existing record and offered no replay.

A separate completed viewing then changed only the Jellyfin source. Native
watched export showed the existing tracker resume as a conflict; cancellation
preserved it, and explicit confirmation added one play with the server's original
last-play date and cleared tracker resume. Both servers, other tracker titles,
the combined-file controls and test lists stayed unchanged. Relaunch showed the
play already present without adding another. The same live preview recognized
previously reported ordinary/special episodes and left the combined file
unavailable.

Real Emby movie export testing found and repaired three gaps: an empty end-page
response reported zero total after a complete 1,514-item inventory; a historical
watch disappeared from export during an unfinished rewatch; and the service
returned an unknown watch date as an empty string rather than null. The shared
inventory now accepts that exact terminal response without accepting truncation.
Both export implementations retain historical completion without changing
current playback state. Watch decoding accepts only the exact empty-string
unknown representation, not missing or malformed dates.

Actual movie playback verified below-2% and above-80% export rejection, an exact
1,044,003-millisecond approved resume, cancellation and no replay after relaunch.
The high-progress preview left the existing tracker resume intact. Completed
viewings followed by unfinished rewatches produced unknown-date backfills, not
invented completion dates or reconstructed server play counts. One real failed
acknowledgment was reconciled from its saved record without another write; a
fresh second movie then verified immediate native acknowledgment and independent
readback of exactly one unknown-date play. Unknown-date movie backfill preserved
existing tracker resume rather than implicitly clearing a rewatch.

Controlled independent edits on the real test server and tracker, made while
native export confirmation was open, verified stale-source and stale-tracker
rejection. Fresh comparison and explicit approval then exported the selected
936,284-millisecond resume while retaining the prior watch. Every cancellation,
rejection and relaunch preserved unrelated titles, files, server users and lists.
These are real API race injections paired with normal native UI, not two-device
or interrupted-network acceptance. Remaining scope/lifecycle boundaries and
provider/platform parity still need their own live evidence.

An independently identified real episode then verified unknown-date export:
actual Emby completion followed by an unfinished rewatch produced one undated
tracker play. Native cancellation, exact-play browsing and relaunch preserved
the source, independent Jellyfin user and unrelated records. Explicit native
import subsequently marked that Jellyfin episode watched with one server play,
without copying Emby's play count or inventing a historical tracker date.
The server's import-time recency is not the original unknown watch date.

These checks also exposed intermittent Jellyfin parent-metadata request timeouts
during comparisons. Bounded live captures aligned to the native Compare action
verified a reduction from 60 parent reads to one on each server for the same
series. Comparisons reuse each fresh parent within that comparison and account,
while dispatch and readback still fetch fresh evidence. Five consecutive
relaunch comparisons then passed, each with independent unchanged-state checks.
This does not establish that every network timeout is resolved; original failed
evidence is retained.

The unbound `PublicMetaDBLiveHistoryTests` driver uses normally configured
production-app UI, not seeded profiles or substituted media. Its individual
scenarios require explicit `PLOZZ_TRACKER_HISTORY_LIVE=1`, the owned
`PLOZZ_TRACKER_HISTORY_SIMULATOR`, and non-secret test user/title settings in
the runner environment. Run only the intended scenario, retain its nonzero
XCTest result, and pair it with independent exact-title server/tracker reads;
successful UI interaction alone is not delivery confirmation. Keep account
configuration, credentials, screenshots and live-state evidence private.
Episode scenarios select the exact source library and season through native UI,
distinguish series cards from episode search results, and bring the episode rail
clear of navigation controls before bounded horizontal gestures. Season selection
also uses bounded slow gestures and requires the whole target tab to be visible.
Import scenarios require an already connected dedicated destination, its exact
account and item identifiers, and test username through `PLOZZ_TRACKER_IMPORT_*`.
Never pass a real credential to XCTest `typeText`: it logs a prefix even for
secure fields. Keep credentials out of runner arguments and environment. Native switch
interaction targets the switch control rather than its containing row.
Confirmation cancellation prefers the native Cancel action, otherwise using
a point outside the actual popover. Never tap the center of its full-window
dismissal region: that point can overlap the destructive confirmation button.
Large export inventories may use an explicitly bounded 30–600-second preview
deadline instead of the default 120 seconds; a deadline failure is not a pass.
The independent reader uses standard `Authorization: MediaBrowser Token="..."` for
Jellyfin and Emby; servers can reject legacy `X-Emby-Token` headers.
Emby does not support Jellyfin's `/Users/Me` endpoint. Its independent preflight
instead requires at least one credential-visible session for the configured
server user, no sessions for other users, and the expected server on every
session, then verifies that exact user's nonadministrator policy. Userless
service sessions such as DLNA do not provide identity proof. Empty, mixed,
malformed or mismatched identities fail closed before item reads.
This full read-only Emby preflight has passed against the dedicated real user,
including rejection of an intentionally mismatched user; it is not native
playback or a full multi-provider acceptance pass.
For a Plex managed user with distinct cloud and server tokens, the optional
`discoveryCredential` uses the same Keychain-reference fields as the server
credential. The cloud user and machine must match, and that user's discovered
resource token must equal the supplied server token before any item reads.

## Opt-in playback reporting

Playback consent is separate from key connection, list consent and history imports.
It is device-local, profile-scoped, and bound to a verified key connection plus a
new consent identity. Both player shells capture that identity before playback.
Turning reporting off immediately fences requests; enabling again cannot replay
old sessions under the new consent.

`WatchProgressReporter` emits bounded player-clock samples with one viewing ID
across engine recovery. Metadata runtime is not playback evidence. The existing
watch outbox retains these sessions separately from coalesced server-state writes:
manual watched toggles, imported history and another tracker's updates cannot
manufacture a viewing. Library-channel requests suppress reporting. External
players are not wired to this actual-clock path.

The adapter supports TMDB movies and individual episodes with explicit TMDB order.
For other or missing server orders, it verifies the exact TMDB episode and parent
external IDs against the server at the same season/episode coordinates.
Conflicting IDs or aliases, inherited show IDs, differing coordinates and
multi-episode files remain unsupported. It does not relabel the server's order,
translate numbering systems, or change the playable server identity.
Verified proof stays with the viewing receipt across reporter recreation.
The shared runtime honors current metadata preferences, credentials and profile
authorization; unavailable proof does not authorize a guessed report.
Resume uses milliseconds,
with the service's 2%/80% rules; watched plays use Plozz's 90% threshold and the first
completion timestamp. Distinct viewing IDs preserve rewatches. Receipts are saved
before dispatch and read back independently. Uncertain writes park that session
instead of replaying it, including after relaunch. Unsupported identities,
conflicts and unconfirmed deliveries are visible in playback settings.

Newer remote progress/completion blocks older offline progress. A possible watch
already reported by a server plugin blocks another watched POST. This is not
server-side compare-and-swap or idempotency: concurrent external reporters can
still race. The consent asks users to disable duplicate reporting elsewhere.
