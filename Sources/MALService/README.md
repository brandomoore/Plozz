# MyAnimeList

The connected account page on TV and mobile offers **Compare with server
history**, using the shared reviewed import flow. Existing planning-list and
playback integration remain separate.

The adapter reads `/users/@me` and every `/users/@me/animelist` page using the
captured profile connection. It omits the status filter and requests `nsfw=true`
because the default filtering can omit entries from the user's list. This does
not override Plozz parental/library admission or publish the list.

Each page must decode completely, contain unique positive IDs, and remain within
the 1,000-row/8 MiB bound. List-update dates cannot move forward in descending
pagination. A next link must have the expected origin, path and contiguous
offset; only its checked offset is reused in a freshly constructed request.
One hundred pages is the maximum; reaching the bound without explicit exhaustion
is an error. The authenticated owner is checked before and after the walk.
Missing pagination metadata, partial records, repeated entries, changed scope,
HTTP errors and cancellation never publish a partial comparison. No retries,
activity cache or atomic remote snapshot are implied.

Status, episode count, repeats, personal score out of 10 and update timestamp
remain typed title-level evidence. Zero score is unrated, absent counts stay
unknown, and the documented legacy episode-count spelling is accepted only when
it does not contradict the canonical field. Rewatching never becomes completion.
Fuzzy start/finish dates are not exact play timestamps and are not imported.
Only an explicitly completed movie with an exact server identity can offer a
watched flag, behind the shared per-server confirmation and source/server
rechecks. Series aggregates never become individual episode writes.

History uses the facade's existing token-refresh path. Its guarded save now
propagates storage errors and rejects a replaced grant or profile before storing
the result; a failed refresh does not proceed to history reads.

Contract: [official API v2 reference](https://myanimelist.net/apiconfig/references/api/v2).
