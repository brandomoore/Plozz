# PublicMetaDBService

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
Direct entry remains available when the relay is unavailable. Transport-rejected
error pages, including oversized HTML from an unpublished route, show the same
actionable manual-API-key fallback rather than a generic response error. Pairing
failures retain their typed, localizable messages in `Phase.pairingFailed`;
they must not pass through `AppError.unknown`, which intentionally displays a
generic fallback. The new Worker
binding and production activation require separate deployment approval.

Non-idempotent writes are not automatically retried. A lost reply, malformed
successful reply, or ambiguous server failure is an uncertain write, not proof
that nothing happened. HTTP 207 batch outcomes retain item-level failures.
Complete history/resume reads validate pagination, totals, and duplicate IDs;
a capped or incomplete read cannot become a successful import snapshot.
Writes validate returned identities and values, not just a success flag or row
count. Episode ratings support season-only queries, and resume reads support
external-ID lookup. Picks retain open-ended recipe filters and weights without
interpreting unknown options or substituting local recommendation behavior.

Resume uses milliseconds. PublicMetaDB ignores progress below 2% and clears
resume at 80%; that does not mean Plozz or a media server considers the title
watched. Plozz's completion threshold remains 90%. Watched dates distinguish
omitted/current, explicit null/unknown, and a known timestamp. A new watched
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
confirmed ordering and a single-episode file. Aggregate episode counts are not
fabricated into individual plays. Server plugins can forward server changes;
the confirmation discloses that consequence. Read-before-write checks cannot
provide a server-side transaction against a concurrent third-party writer.

## Explicit server-history export

The TV and mobile account pages offer a separate **Export server history** flow.
Users choose a server user, library, and watched-title or resume mode. Read-only
preview walks bounded provider pages, probes the advertised end, refreshes relevant
items and parent-series identities, and rejects partial inventories and ambiguous
duplicates. Movie IDs and single-episode TMDB ordering must be confirmed.

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
enabled destinations, public-list visibility and PublicMetaDB's automatic
undropping of shows added to lists. It does not authorize watched-history or
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

## Explicit history management

Individual account records expose play-date edits, deletion of one exact play,
resume clearing and undropping. Users can add a separate dated or explicitly
undated play, including a deliberate rewatch. These are PublicMetaDB changes,
not server-history imports or playback events; other connected clients may
nevertheless react to the tracker change.

The service reads complete identity-filtered state before dispatch and requires
the observed record/date/progress to remain unchanged. Removal uses an exact
record ID, not a title-wide watched deletion. Successful replies need independent
readback. Missing fields, foreign identities, replacement progress and uncertain
creation are never treated as successful resets or permission to retry.
Unchanged dates and already-absent exact records do not issue redundant writes.
No upstream compare-and-swap exists, so another client can still race between a
preflight read and the request; the UI does not promise transactional editing.
Title controls in native card/detail menus, Picks, list entries and history
records expose the same explicit history actions. Opening these controls neither
starts playback nor marks the title watched.

## Optional community ratings

The profile-scoped rating lookup preference starts off. Enabling it sends the
strongly identified titles users browse to PublicMetaDB and adds an attributed
overall score alongside the existing rating providers on TV and mobile. It does
not submit personal ratings or replace server titles, artwork or IDs.

Movie/show namespaces remain distinct. Episodes require a parent-series TMDB ID,
confirmed TMDB ordering and one episode; conflicting ID aliases do not select an
arbitrary title. Only the explicit `Overall` label is aggregated into this badge,
not acting/direction or other user-defined dimensions. Incomplete collections,
duplicate records, wrong identities and invalid averages are rejected.

The service's five-minute, 256-entry memory cache is scoped to the live connection and
cleared on profile/key/preference changes. Pending requests are fenced too.
Home's cache-only path never starts a network lookup. Ordinary keyed/keyless
ratings remain available if this optional source fails; its failures are logged
without credentials or title data. Server-selected rating lists, including
intentional empty lists, do not trigger or reuse this contribution.
Existing profile-scoped page snapshots can retain previously displayed public
scores until refreshed; disabling lookup stops requests rather than rewriting
those snapshots. Contribution browsing retains each rating's own label and score;
it does not mix unrelated labels into an average.

## Explicit community contributions

Shared title controls support labeled movie/show/episode rating submissions,
exact-rating deletion, skip/highlight browsing and publishing, and contribution
votes. Every mutation requires confirmation, connection fencing and independent
readback. Ratings invalidate cached aggregate requests after a mutation attempt.
Ambiguous creation is not retried. Deletion rechecks the observed value,
contributor and revision and addresses only that exact record. The server
authorizes deletion; contributor names and vote state never establish ownership.

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
per-label aggregates. It rejects the potentially capped 5,000-record response
rather than calling it a complete season. Rated episodes are not presented as
an authoritative episode roster. Explicit batch submission/deletion supports
up to 50 unique episodes/record IDs and independently checks the complete season
afterward. Partial HTTP 207 outcomes retain confirmed IDs and unconfirmed
episodes/IDs, block blind replay, and never become a full success. Deletions
recheck every selected record before dispatch and never become season-wide resets.

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
Ongoing history sync, broader historical backfill and authentic end-to-end
acceptance remain unfinished.
Do not describe this foundation as full end-user support.

Contract/lifecycle/transport fixtures and guarded-import tests are automated.
They are not authenticated service evidence. Release acceptance still requires
dedicated real accounts, authorized real-media playback in Plozz, independent
tracker/server readback in both directions, and exact run-owned cleanup.

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

The adapter supports TMDB movies and individual episodes with explicit TMDB order,
never multi-episode files or guessed series identities. Resume uses milliseconds,
with the service's 2%/80% rules; watched plays use Plozz's 90% threshold and the first
completion timestamp. Distinct viewing IDs preserve rewatches. Receipts are saved
before dispatch and read back independently. Uncertain writes park that session
instead of replaying it, including after relaunch. Unsupported identities,
conflicts and unconfirmed deliveries are visible in playback settings.

Newer remote progress/completion blocks older offline progress. A possible watch
already reported by a server plugin blocks another watched POST. This is not
server-side compare-and-swap or idempotency: concurrent external reporters can
still race. The consent asks users to disable duplicate reporting elsewhere.
