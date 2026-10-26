# SimklService

Profile-scoped Simkl connection, playback reporting, watchlist destination and
on-demand server-history comparison. Credentials stay in the existing token
store; a comparison does not enable playback reporting, ongoing history sync,
or server mutations.

## History comparison

`SimklService.historySnapshot(expectedConnectionID:)` binds every GET and its
response to the current connected profile generation and credential identity.
Switching away and back, reconnecting, or replacing the grant invalidates an
earlier comparison. Cancellation and HTTP failures remain failures.

`SimklHistoryReader` keeps a connection-lifetime, in-memory read cache. The first
requested comparison checks `/sync/activities`, then reads shows, movies and
anime sequentially. Later comparisons check activity first and fetch only
changed history categories, passing the previous snapshot's exact `all` value
as `date_from`. Only a complete, validated read replaces the cache. This is not
a background poller or a durable synchronization engine.

Reads request `extended=full`, `include_all_episodes=original`,
`episode_watched_at=yes` and `episode_tvdb_id=yes`. Simkl builds each unpaginated
response in full; a documented `max_items` rejection splits that type by status,
and failure of any split rejects the comparison. Missing categories in an empty
object are valid; malformed, duplicate, unrelated or partially read categories
are not. Before/after activity must agree. This is activity evidence, not an
API-provided cross-request transaction.

Removal activity triggers a fresh IDs-only reconciliation. Removing an item or
an episode from Simkl removes read evidence, never fabricates an explicit
unwatch or resume-clear instruction. Changed playback activity or watched state
refreshes the current paused-playback set because a delta cannot reveal removed
sessions. Reaching its 10,000-record limit rejects a potentially truncated read.
No percentage is converted to server seconds, including 0% and 100%.

Completed movies are watched-state observations, not individual play counts.
Only originally recorded episode rows become episode observations; imports need
matching, distinct episode and parent IDs plus matching coordinates. Bulk show
completion and anime counters remain aggregate observations. The unknown-watch
date sentinel (`1970-01-01T00:00:01Z`) stays unknown. No rewatches or episode order
are invented, and PRO/VIP rewatch-session reads are not requested.

The current detailed playback documentation uses `paused_at`; some published
schemas still use `watched_at`. Both shapes can retain percentage observations,
but only an explicit `paused_at` becomes a pause date. These observations cannot
authorize server progress writes.

TV and mobile use the shared `TrackerHistoryImportSession` and approval UI.
The destination is the exact active Plex/Jellyfin server user, not a parallel
tracker-owned history store. Existing conflict, parental authorization,
current-item revalidation, cancellation, outbox and readback safeguards apply.

After comparison, the separate **Ongoing sync** page can retain explicit
server-user/watched-state permission and a baseline of existing history.
**Sync now** checks new evidence through the same activity-gated reader; Simkl
never participates in foreground automatic checks. Existing history, removals,
aggregate counts and percentage-only progress are not backfilled by enrollment.
No PRO/VIP rewatch session is created. See the shared
[consent and disconnect contract](../FeatureSettings/README.md).

## Export comparison groundwork

The internal reader's opt-in `includesListStates` mode retains non-completed
movie list states and parent show/anime list states as protection evidence.
It uses the same activity-gated complete reads, delta replacement and removal
reconciliation, without additional requests or invented play/resume records.
The mode is fixed for each reader's cache lifetime. Existing import and ongoing
sync readers leave it off and retain their previous observations.

This is read-only groundwork, not an enabled Simkl export action. The writer
still needs exact canonical target resolution, authenticated owner checks,
explicit episodes/dates, no rewatch creation, rate-aware dispatch and verified
acknowledgements/readback. List completion alone never proves individual plays.

## Contracts and verification

Current official references:

- [Sync lifecycle](https://api.simkl.org/guides/sync)
- [Activities](https://api.simkl.org/api-reference/simkl/get-activities)
- [All-items response and limits](https://api.simkl.org/api-reference/simkl/get-all-items)
- [Playback records and retention](https://api.simkl.org/api-reference/simkl/get-playback-sessions)
- [Dates](https://api.simkl.org/conventions/dates)

`SimklHistorySnapshotTests` exercises read-only requests, original episode
evidence, aggregation, activity-gated deltas, removals, failed-read recovery,
caps, malformed responses, cancellation and profile/grant invalidation.
Fixture tests are not authenticated playback or tracker/server round-trip
acceptance. Those require dedicated accounts, exact allowed media and
separately authorized remote mutations.
