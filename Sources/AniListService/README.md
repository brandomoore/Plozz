# AniList

Profile-scoped anime tracking and planning-list integration retain their existing
connection and playback paths. The connected account page on TV and mobile also
offers an explicit **Compare with server history** action.

## Read-only list progress

The history adapter issues GraphQL queries, never mutations. It reads the
authenticated viewer ID, then every anime-list page, including non-planning
states and private entries visible to that viewer. Every page must identify the
same viewer and row owner, exact current page and page size, and unique descending
media IDs. It follows `hasNextPage` through exhaustion. AniList documents
`PageInfo.total` as unreliable, so this field never establishes completeness.
Reads are bounded to 1,000 pages of 50 records, with an 8 MiB response limit.
Null data, partial GraphQL errors, wrong owners, repeated pages, malformed entries,
HTTP failures and cancellation reject the comparison rather than dropping rows.

Observations preserve title-level status, episode progress, repeats, the personal
score normalized to 10, and the entry's update timestamp. An update timestamp is
not a watched date. Missing progress is not zero; score zero means unrated.
The reader requests no notes or custom-list contents and does not guess IDs from
titles. Profile changes, replaced tokens, disconnect and page exit revoke work.
Read requests do not retry or refresh credentials through another auth path.

Only a completed entry explicitly identified as a movie can offer a watched-flag
import, after an exact library identity match and the shared explicit approval.
Series counts never become a list of watched episodes; planning, dropped and
rewatching states do not clear or rewind server history. Fuzzy dates, rewatch
counts and catalog durations do not become historical play timestamps or resume
seconds. The shared import owner rechecks relevant tracker evidence and fresh
server state before writing through the existing outbox, without scrobbling the
import or expanding to unselected servers.

This is an on-demand paginated read, not an atomic remote snapshot or permission
for ongoing imports. Source activity may change between requests; duplicate/order
checks and the approval-time recheck reject detectable stale evidence. Missing
entries never cause destructive server operations.

A separate, explicitly approved ongoing permission can import newly completed,
exactly matched movies using the shared controller. It cannot import series
episode counts or resume points. Refresh/relaunch and disconnect/reconnect use
the [shared consent lifecycle](../FeatureSettings/README.md); legacy tokens
remain readable, and every new sign-in saves a new connection identity.

Contracts: [MediaList](https://docs.anilist.co/reference/object/medialist),
[PageInfo](https://docs.anilist.co/reference/object/pageinfo),
[Query](https://docs.anilist.co/reference/query).

## Reviewed movie-completion export

**Export server history** on TV and mobile is separate from imports, ongoing
sync and playback reporting. It reads the selected server user's movie library,
then requires title selection and explicit confirmation. Only exact AniList or
MAL IDs resolving to an `ANIME`/`MOVIE` qualify; two supplied IDs must agree.
Targets include the authenticated viewer and canonical AniList media ID. Missing
list-state fields, foreign owners, conflicting IDs and non-movie formats fail
closed. Existing entries, including planning, paused, dropped and rewatching
states, remain unchanged.

The [shared exporter](../CoreModels/README.md#reviewed-tracker-export) rechecks
server state and current tracker evidence before sending
`SaveMediaListEntry(mediaId: ..., status: COMPLETED)`. It sends no dates,
episode progress, repeat counts, scores or notes. It does not invent an anime
series' watched episodes or impersonate a playback session. AniList owns its
normal completion-status side effects; this is not per-play history.

Receipts survive relaunch and block uncertain retries. The acknowledgement must
identify the requested media, viewer and completed status; a separate query
then establishes current state. Transport failures and partial GraphQL errors
are uncertain, not proof of rejection. There is no automatic retry or token
refresh path. Profile changes, credential replacement, disconnect and closing
the page fence further work. Remote edits can still race these non-atomic reads.

Mutation contract: [SaveMediaListEntry](https://docs.anilist.co/reference/mutation#savemedialistentry).
